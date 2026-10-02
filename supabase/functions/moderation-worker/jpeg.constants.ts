// §8.1: "The app uploads a **JPEG, at most 2048 px on the long edge and 5 MB**."
export const MAX_BYTES = 5_242_880;

export const MARKER = {
  startOfImage: 0xd8,
  startOfScan: 0xda,
  endOfImage: 0xd9,
} as const;

// §8.1's step 2 as an **allow-list**, not a deny-list of the three formats it names.
// A deny-list of APP1, APP13 and COM was measured against real marker layouts and
// left four more channels intact, two of them worse than leftover metadata: APP2's
// MPF index, which embeds a whole second JPEG with its own EXIF GPS; APP11's JUMBF
// and C2PA content credentials, which assert a creator name and a capture location;
// and APP3 `Meta` and APP12 `Ducky`, which carry EXIF-structured data and free text.
// §8.1's figure names three formats, but its *reason* is "phone photos carry exact
// GPS coordinates in EXIF. Leaving them in would quietly defeat the coarse location
// rule (§5.4), and matters most for minors" — and a list that has to be extended
// every time a vendor invents a segment does not meet it.
//
// So every `APPn` (0xe0–0xef) and the comment segment go, except the two that are not
// metadata at all: APP0's JFIF density, and APP2 **when it is an ICC colour profile**
// rather than an MPF index — told apart by the payload's own signature, because the
// two share the marker and dropping the profile would change how the photo renders.
// Everything that is not an `APPn` or a comment is kept untouched: quantisation and
// Huffman tables, the frame header, the scans. §8.1 asks for metadata removal, not
// re-encoding.
// What the allow-list costs, stated rather than discovered later. APP14 `Adobe` goes
// with the rest, and it carries no free text and no coordinate — twelve fixed bytes,
// one of which is the colour transform a CMYK or YCCK JPEG decodes by. So a CMYK
// upload's published copy can come out with shifted colours. Accepted: §8.1 is written
// about phone photos, which are YCbCr, and the alternative is a marker kept for a case
// that should not arrive. If one does, this is the line that explains why it looks wrong.
export const APP_FIRST = 0xe0;
export const APP_LAST = 0xef;
export const APP_JFIF = 0xe0;
export const APP_ICC_OR_MPF = 0xe2;
export const COMMENT_MARKER = 0xfe;

// `ICC_PROFILE\0`, the signature an APP2 carrying a colour profile opens with.
export const ICC_SIGNATURE = [
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
] as const;

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
