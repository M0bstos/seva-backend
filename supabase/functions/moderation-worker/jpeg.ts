import { DROPPED_MARKERS, MARKER, MAX_BYTES, SIZE_OF_FRAME } from "./jpeg.constants.ts";

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
// §8.1 names EXIF, XMP and IPTC. EXIF and XMP both arrive in APP1 and IPTC in APP13;
// a comment segment goes too, being the other place a camera or an editor writes free
// text. Everything else is kept, APP0's JFIF density and APP2's colour profile
// included: dropping those changes how the photo renders, and §8.1 asks for metadata
// removal rather than re-encoding.
export function stripMetadata(bytes: Uint8Array): Uint8Array | null {
  if (!isAcceptableJpeg(bytes)) return null;

  const kept: Uint8Array[] = [bytes.subarray(0, 2)];
  let at = 2;

  while (at < bytes.length) {
    if (bytes[at] !== 0xff) return null;

    const marker = bytes[at + 1];
    if (marker === undefined) return null;

    // The scan is the last segment with a length; everything after it is entropy-coded
    // data up to the end of the file, and none of it is metadata.
    if (marker === MARKER.startOfScan) {
      kept.push(bytes.subarray(at));
      break;
    }

    const length = (bytes[at + 2] << 8) | bytes[at + 3];
    if (Number.isNaN(length) || length < 2 || at + 2 + length > bytes.length) return null;

    if (!(DROPPED_MARKERS as readonly number[]).includes(marker)) {
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
