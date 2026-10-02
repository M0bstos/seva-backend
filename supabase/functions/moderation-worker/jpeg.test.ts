import { assertEquals } from "jsr:@std/assert@1.0.19";
import { isAcceptableJpeg, readDimensions, stripMetadata } from "./jpeg.ts";

// A JPEG assembled byte by byte, so each test says exactly which segments it is about.
// Shapes only — nothing here decodes an image, and neither does the worker.
function segment(marker: number, payload: number[]): number[] {
  const length = payload.length + 2;
  return [0xff, marker, length >> 8, length & 0xff, ...payload];
}

function jpeg(...segments: number[][]): Uint8Array {
  return new Uint8Array([0xff, 0xd8, ...segments.flat()]);
}

// APP0 JFIF, an EXIF APP1 carrying a GPS-looking payload, a frame header, and a scan.
const JFIF = segment(0xe0, [0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x00]);
const EXIF = segment(0xe1, [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x12, 0x34, 0x56]);
const IPTC = segment(0xed, [0x50, 0x68, 0x6f, 0x74, 0x6f, 0x73, 0x68, 0x6f, 0x70]);
const COMMENT = segment(0xfe, [0x31, 0x38, 0x2e, 0x35, 0x32, 0x2c, 0x37, 0x33]);
// precision 8, height 1200, width 1600, 3 components.
const FRAME = segment(0xc0, [0x08, 0x04, 0xb0, 0x06, 0x40, 0x03, 0, 0, 0, 0, 0, 0]);
const SCAN = [...segment(0xda, [0x01, 0x01, 0x00]), 0x12, 0x34, 0xff, 0xd9];

Deno.test("§8.1 step 1: the signature and the 5 MB bound", () => {
  assertEquals(isAcceptableJpeg(jpeg(JFIF, FRAME, SCAN)), true);
  // A PNG that arrived with a JPEG content type, which the bucket's allow-list cannot
  // tell apart from the real thing.
  assertEquals(isAcceptableJpeg(new Uint8Array([0x89, 0x50, 0x4e, 0x47])), false);
  assertEquals(isAcceptableJpeg(new Uint8Array(0)), false);
  assertEquals(isAcceptableJpeg(new Uint8Array(5_242_881).fill(0xff)), false);
});

Deno.test("§8.1 step 2: EXIF, IPTC and comments go, and nothing else does", () => {
  const stripped = stripMetadata(jpeg(JFIF, EXIF, IPTC, COMMENT, FRAME, SCAN));
  assertEquals(stripped, jpeg(JFIF, FRAME, SCAN));
});

Deno.test("the EXIF payload is gone from the bytes, not merely skipped over", () => {
  const stripped = stripMetadata(jpeg(JFIF, EXIF, FRAME, SCAN));
  if (stripped === null) throw new Error("expected a stripped file");
  // §8.1: "phone photos carry exact GPS coordinates in EXIF", and §5.4 is what that
  // would defeat. The three bytes stood in for them.
  const found = [...stripped].some((_, i) =>
    stripped[i] === 0x12 && stripped[i + 1] === 0x34 && stripped[i + 2] === 0x56
  );
  assertEquals(found, false);
});

Deno.test("the scan and everything after it is carried through untouched", () => {
  const stripped = stripMetadata(jpeg(JFIF, EXIF, FRAME, SCAN));
  if (stripped === null) throw new Error("expected a stripped file");
  assertEquals([...stripped.slice(-4)], [0x12, 0x34, 0xff, 0xd9]);
});

Deno.test("a file whose markers do not walk is refused, which §5.3 calls rejected", () => {
  // A declared length running past the end of the file.
  assertEquals(stripMetadata(new Uint8Array([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff])), null);
  // A segment that does not start with 0xff where one must.
  assertEquals(stripMetadata(new Uint8Array([0xff, 0xd8, 0x00, 0xe1, 0x00, 0x04])), null);
  assertEquals(stripMetadata(new Uint8Array([0x89, 0x50, 0x4e, 0x47])), null);
});

Deno.test("§5.2.1's width and height are read from the frame header", () => {
  assertEquals(readDimensions(jpeg(JFIF, EXIF, FRAME, SCAN)), {
    width: 1600,
    height: 1200,
  });
  // 0xc4 shares the range with the frame markers and is a Huffman table, not a frame.
  const huffman = segment(0xc4, [0x00, 0x01, 0x02]);
  assertEquals(readDimensions(jpeg(JFIF, huffman, SCAN)), null);
});

Deno.test("dimensions survive the strip, so the row records the published copy", () => {
  const stripped = stripMetadata(jpeg(JFIF, EXIF, IPTC, FRAME, SCAN));
  if (stripped === null) throw new Error("expected a stripped file");
  assertEquals(readDimensions(stripped), { width: 1600, height: 1200 });
});
