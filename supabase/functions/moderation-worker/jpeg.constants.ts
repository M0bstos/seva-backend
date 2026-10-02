// §8.1: "The app uploads a **JPEG, at most 2048 px on the long edge and 5 MB**."
export const MAX_BYTES = 5_242_880;

export const MARKER = {
  startOfImage: 0xd8,
  startOfScan: 0xda,
} as const;

// §8.1 names EXIF, XMP and IPTC. EXIF and XMP both travel in APP1 (0xe1) and IPTC in
// APP13 (0xed); the comment segment (0xfe) is the other place free text is written.
// APP0's JFIF density and APP2's colour profile stay, because dropping them changes
// how the photo renders and §8.1 asks for metadata removal, not re-encoding.
export const DROPPED_MARKERS = [0xe1, 0xed, 0xfe] as const;

// The frame headers that carry the image's dimensions: baseline, extended sequential,
// progressive and lossless, each in its Huffman and arithmetic form. 0xc4, 0xc8 and
// 0xcc share the range and are not frames.
export const SIZE_OF_FRAME = [
  0xc0,
  0xc1,
  0xc2,
  0xc3,
  0xc5,
  0xc6,
  0xc7,
  0xc9,
  0xca,
  0xcb,
  0xcd,
  0xce,
  0xcf,
] as const;
