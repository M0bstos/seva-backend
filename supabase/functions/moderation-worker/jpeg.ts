import {
  APP_FIRST,
  APP_ICC_OR_MPF,
  APP_JFIF,
  APP_LAST,
  COMMENT_MARKER,
  ICC_SIGNATURE,
  MARKER,
  MAX_BYTES,
  SIZE_OF_FRAME,
} from "./jpeg.constants.ts";

// §8.1's steps 1 and 2, which are the two the worker does without calling anything:
// "Check file bytes · JPEG signature · ≤ 5 MB" and "Strip metadata · EXIF · XMP ·
// IPTC removed".
//
// Done by walking the file's own markers rather than with a library, because it is a
// walk: a JPEG is a sequence of `FF <marker> <2-byte length> <payload>` segments until
// the scan begins, and dropping a segment is dropping a slice. §3.3's four checks are
// for a service, and nothing here is one.
//
// §8.1 is explicit about why this matters more than the rest of the pipeline: "phone
// photos carry exact GPS coordinates in EXIF. Leaving them in would quietly defeat the
// coarse location rule (§5.4), and matters most for minors."

// The file bytes §8.1 step 1 checks. The bucket also enforces both (§8.1), and this is
// the half that holds when a caller sends JPEG bytes that are not a JPEG.
export function isAcceptableJpeg(bytes: Uint8Array): boolean {
  return bytes.length > 0 && bytes.length <= MAX_BYTES &&
    bytes[0] === 0xff && bytes[1] === MARKER.startOfImage && bytes[2] === 0xff;
}

// The same file with its metadata segments removed. Returns null when the markers do
// not walk — a truncated file, or one whose declared lengths run past its end — which
// §5.3's `rejected` is for.
//
// An allow-list over the metadata markers, for the reason the constants file gives:
// a deny-list of the three formats §8.1 names left four more channels intact.
export function stripMetadata(bytes: Uint8Array): Uint8Array | null {
  if (!isAcceptableJpeg(bytes)) return null;

  const kept: Uint8Array[] = [bytes.subarray(0, 2)];
  let at = 2;

  while (at < bytes.length) {
    // A marker may be preceded by any number of `0xff` fill bytes, which the standard
    // allows and some encoders emit. Treating one as corruption would reject a legal
    // file and, under §8.1's three outcomes, delete it as `rejected`.
    while (bytes[at] === 0xff && bytes[at + 1] === 0xff) at++;
    if (bytes[at] !== 0xff) return null;

    const marker = bytes[at + 1];
    if (marker === undefined) return null;

    // `EOI` carries no segment, so its length must not be read. Nothing else that
    // appears at this point in the walk is standalone.
    if (marker === MARKER.endOfImage) {
      kept.push(bytes.subarray(at, at + 2));
      break;
    }

    const length = (bytes[at + 2] << 8) | bytes[at + 3];
    if (Number.isNaN(length) || length < 2 || at + 2 + length > bytes.length) return null;

    // **The file does not end at the first scan.** A progressive JPEG has several,
    // and a phone JPEG often appends a whole second image after the first `EOI` — an
    // Apple HDR or portrait pair, a Samsung motion photo — each with its own APP1
    // `Exif` block and its own GPS tags. Copying the tail verbatim would have left
    // those in, which is the thing §8.1 strips metadata for and §5.4 depends on.
    // So the scan's entropy-coded data is walked to the marker that ends it, and the
    // walk continues from there; everything past the first `EOI` is dropped.
    //
    // Walked from past the scan header, not from the length bytes: a component
    // selector that happened to be `0xff` would otherwise end the scan early and make
    // a legal file `rejected`, which deletes the original.
    if (marker === MARKER.startOfScan) {
      const ended = endOfScan(bytes, at + 2 + length);
      if (ended === null) return null;
      kept.push(bytes.subarray(at, ended.at));
      if (ended.marker === MARKER.endOfImage) {
        kept.push(bytes.subarray(ended.at, ended.at + 2));
        break;
      }
      at = ended.at;
      continue;
    }

    if (!isMetadata(bytes, at, marker)) {
      kept.push(bytes.subarray(at, at + 2 + length));
    }
    at += 2 + length;
  }

  const stripped = new Uint8Array(kept.reduce((total, part) => total + part.length, 0));
  let written = 0;
  for (const part of kept) {
    stripped.set(part, written);
    written += part.length;
  }
  return stripped;
}

// Whether the segment at `at` is one §8.1 strips. Every `APPn` and the comment
// segment, except APP0's JFIF density and an APP2 that is an ICC colour profile —
// APP2 also carries the MPF index that points at an embedded second image, and that
// one goes.
function isMetadata(bytes: Uint8Array, at: number, marker: number): boolean {
  if (marker === COMMENT_MARKER) return true;
  if (marker < APP_FIRST || marker > APP_LAST) return false;
  if (marker === APP_JFIF) return false;
  if (marker === APP_ICC_OR_MPF) return !isIccProfile(bytes, at + 4);
  return true;
}

function isIccProfile(bytes: Uint8Array, from: number): boolean {
  return ICC_SIGNATURE.every((byte, i) => bytes[from + i] === byte);
}

// Where the entropy-coded data starting at `from` ends, and on which marker. A literal
// `0xff` inside compressed data is byte-stuffed as `ff 00`, and a restart marker
// (`ffd0`–`ffd7`) belongs to the scan, so neither ends it. Anything else does — the
// `EOI` that closes the image, or the next segment of a progressive one.
function endOfScan(
  bytes: Uint8Array,
  from: number,
): { at: number; marker: number } | null {
  for (let at = from; at < bytes.length - 1; at++) {
    if (bytes[at] !== 0xff) continue;
    const next = bytes[at + 1];
    if (next === 0x00 || next === 0xff) continue;
    if (next >= 0xd0 && next <= 0xd7) continue;
    return { at, marker: next };
  }
  return null;
}

// §5.2.1 has `media` carry `width` and `height`, and §8.1 bounds the long edge at
// 2048 px. The numbers live in the frame header, so reading them needs the same walk
// and no decoder. Returns null when no frame header is found.
export function readDimensions(
  bytes: Uint8Array,
): { width: number; height: number } | null {
  let at = 2;
  while (at < bytes.length) {
    if (bytes[at] !== 0xff) return null;
    const marker = bytes[at + 1];
    if (marker === undefined || marker === MARKER.startOfScan) return null;

    const length = (bytes[at + 2] << 8) | bytes[at + 3];
    if (Number.isNaN(length) || length < 2 || at + 2 + length > bytes.length) return null;

    if ((SIZE_OF_FRAME as readonly number[]).includes(marker)) {
      // precision(1) height(2) width(2) components(1), after the two length bytes.
      return {
        height: (bytes[at + 5] << 8) | bytes[at + 6],
        width: (bytes[at + 7] << 8) | bytes[at + 8],
      };
    }
    at += 2 + length;
  }
  return null;
}
