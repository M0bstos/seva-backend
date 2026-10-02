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

// §8.1 names EXIF, XMP and IPTC. The comment segment is this build's own addition,
// recorded in §17.1 — free text is where a coordinate survives a strip that looked
// only at APP1 and APP13.
Deno.test("§8.1 step 2: EXIF and IPTC go, with comments, and nothing else does", () => {
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

// The case the first version of this file let through, and the one §8.1 is really
// about. A phone JPEG often appends a whole second image after the first EOI — an
// Apple HDR or portrait pair, a Samsung motion photo — carrying its own APP1 Exif
// block with its own GPS tags. Copying the tail verbatim kept every byte of it.
Deno.test("a second image appended after the first EOI is dropped, GPS and all", () => {
  // The trailer is a complete JPEG of its own: SOI, an EXIF APP1, a frame, a scan.
  const trailer = [0xff, 0xd8, ...EXIF, ...FRAME, ...SCAN];
  const stripped = stripMetadata(jpeg(JFIF, FRAME, [...SCAN, ...trailer]));
  if (stripped === null) throw new Error("expected a stripped file");

  assertEquals(stripped, jpeg(JFIF, FRAME, SCAN), "the file ends at its first EOI");
  // The three bytes standing in for the trailer's coordinates.
  const found = [...stripped].some((_, i) =>
    stripped[i] === 0x12 && stripped[i + 1] === 0x34 && stripped[i + 2] === 0x56
  );
  assertEquals(found, false, "§5.4 depends on this, and §8.1 on it most for minors");
});

// A progressive JPEG has several scans, so the walk cannot stop at the first one or it
// would truncate a legal image into a broken published copy.
Deno.test("a progressive file keeps every scan up to its EOI", () => {
  const second = segment(0xda, [0x01, 0x01, 0x00]);
  const progressive = jpeg(
    JFIF,
    EXIF,
    FRAME,
    [...segment(0xda, [0x01, 0x01, 0x00]), 0x11, 0x22],
    [...second, 0x33, 0x44, 0xff, 0xd9],
  );
  const stripped = stripMetadata(progressive);
  assertEquals(
    stripped,
    jpeg(JFIF, FRAME, [...segment(0xda, [0x01, 0x01, 0x00]), 0x11, 0x22], [
      ...second,
      0x33,
      0x44,
      0xff,
      0xd9,
    ]),
  );
});

// Neither a stuffed 0xff nor a restart marker ends a scan, so neither may truncate it.
Deno.test("byte stuffing and restart markers are part of the scan, not its end", () => {
  const scan = [
    ...segment(0xda, [0x01, 0x01, 0x00]),
    0xff,
    0x00, // a literal 0xff in the compressed data
    0xff,
    0xd0, // a restart marker
    0x7a,
    0xff,
    0xd7, // the last restart marker in the range
    0x7b,
    0xff,
    0xd9,
  ];
  const stripped = stripMetadata(jpeg(JFIF, EXIF, FRAME, scan));
  assertEquals(stripped, jpeg(JFIF, FRAME, scan));
});

// Fill bytes before a marker are legal, and rejecting them would delete a real photo:
// §8.1's `rejected` outcome removes the original.
Deno.test("fill bytes before a marker are not corruption", () => {
  const padded = new Uint8Array([
    0xff,
    0xd8,
    0xff,
    0xff,
    0xff,
    ...FRAME,
    ...SCAN,
  ]);
  assertEquals(stripMetadata(padded), jpeg(FRAME, SCAN));
});

// The four channels a deny-list of APP1, APP13 and COM left intact, measured in
// review. Two of them are worse than leftover metadata: APP2's MPF index embeds a
// second JPEG with its own EXIF GPS, and APP11's C2PA credentials assert a creator
// name and a capture location.
Deno.test("every other APPn goes too, which a deny-list of three left behind", () => {
  const mpf = segment(0xe2, [0x4d, 0x50, 0x46, 0x00, 0x12, 0x34, 0x56]);
  const c2pa = segment(0xeb, [0x6a, 0x75, 0x6d, 0x62, 0x12, 0x34, 0x56]);
  const meta = segment(0xe3, [0x4d, 0x65, 0x74, 0x61, 0x00, 0x12, 0x34, 0x56]);
  const ducky = segment(0xec, [0x44, 0x75, 0x63, 0x6b, 0x79, 0x12, 0x34, 0x56]);
  const xmp = segment(0xe1, [0x68, 0x74, 0x74, 0x70, 0x3a, 0x12, 0x34, 0x56]);

  const stripped = stripMetadata(
    jpeg(JFIF, xmp, mpf, meta, c2pa, ducky, FRAME, SCAN),
  );
  assertEquals(stripped, jpeg(JFIF, FRAME, SCAN));
});

// APP2 carries both the MPF index and the ICC colour profile, so the marker alone
// cannot decide: dropping the profile would change how the photo renders, and §8.1
// asks for metadata removal rather than re-encoding.
Deno.test("an APP2 colour profile stays and an APP2 MPF index goes", () => {
  const icc = segment(0xe2, [
    0x49,
    0x43,
    0x43,
    0x5f,
    0x50,
    0x52,
    0x4f,
    0x46,
    0x49,
    0x4c,
    0x45,
    0x00,
    0x01,
    0x01,
  ]);
  assertEquals(stripMetadata(jpeg(JFIF, icc, FRAME, SCAN)), jpeg(JFIF, icc, FRAME, SCAN));

  const mpf = segment(0xe2, [0x4d, 0x50, 0x46, 0x00, 0x00, 0x00]);
  assertEquals(stripMetadata(jpeg(JFIF, mpf, FRAME, SCAN)), jpeg(JFIF, FRAME, SCAN));
});

// A progressive file may carry a segment after its first scan, and a metadata reader
// still parses one placed there. The walk continues past each scan, so it is seen.
Deno.test("an EXIF segment placed after the first scan is still stripped", () => {
  const firstScan = [...segment(0xda, [0x01, 0x01, 0x00]), 0x11, 0x22];
  const lastScan = [...segment(0xda, [0x01, 0x01, 0x00]), 0x33, 0x44, 0xff, 0xd9];
  const stripped = stripMetadata(jpeg(JFIF, FRAME, firstScan, EXIF, lastScan));
  if (stripped === null) throw new Error("expected a stripped file");
  assertEquals(stripped, jpeg(JFIF, FRAME, firstScan, lastScan));
});

// The scan's entropy data is walked from past its header, so a component selector
// that happens to be 0xff cannot end the scan early — which would truncate a legal
// file and, under §8.1's three outcomes, delete the original as `rejected`.
Deno.test("a 0xff inside the scan header does not end the scan", () => {
  const scan = [...segment(0xda, [0x01, 0xff, 0x00]), 0x12, 0x34, 0xff, 0xd9];
  assertEquals(stripMetadata(jpeg(JFIF, EXIF, FRAME, scan)), jpeg(JFIF, FRAME, scan));
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
