// Joins still WebP frames into one animated WebP that loops, for a cropped
// moving avatar (avatarImage.ts). Browsers encode a still WebP natively
// (canvas.toBlob) but have no animated encoder, and libwebp in WebAssembly
// would add a large dependency for this alone; only the container of the
// WebP RIFF format is written here
// (https://developers.google.com/speed/webp/docs/riff_container).
// Each frame is whole, drawn over nothing.

/** A frame as encoded: a still WebP, shown for `duration` ms. */
export interface WebPFrame {
  webp: Uint8Array;
  duration: number;
}

/** `frames`, each a `side` px square still WebP, as one looping animated WebP. */
export function animatedWebPOf(
  frames: WebPFrame[],
  side: number
): Uint8Array<ArrayBuffer> {
  const bitstreams = frames.map((frame) => bitstreamOf(frame.webp));
  const alpha = bitstreams.some((chunks) =>
    chunks.some((chunk) => chunk.fourcc === "ALPH" || chunk.fourcc === "VP8L")
  );
  const body: Uint8Array[] = [];
  body.push(
    chunk("VP8X", [
      (alpha ? 0x10 : 0) | 0x02,
      0,
      0,
      0,
      ...u24(side - 1),
      ...u24(side - 1),
    ])
  );
  // Clear background, loop for ever.
  body.push(chunk("ANIM", [0, 0, 0, 0, 0, 0]));
  frames.forEach((frame, index) => {
    const header = [
      ...u24(0),
      ...u24(0),
      ...u24(side - 1),
      ...u24(side - 1),
      ...u24(Math.min(0xffffff, Math.max(0, Math.round(frame.duration)))),
      0x02, // replace the canvas, do not blend; keep it after
    ];
    const data = bitstreams[index]!.map((part) => chunk(part.fourcc, part.payload));
    body.push(chunk("ANMF", concat([Uint8Array.from(header), ...data])));
  });
  const content = concat(body);
  const out = new Uint8Array(12 + content.length);
  out.set(ascii("RIFF"));
  new DataView(out.buffer).setUint32(4, 4 + content.length, true);
  out.set(ascii("WEBP"), 8);
  out.set(content, 12);
  return out;
}

interface Chunk {
  fourcc: string;
  payload: Uint8Array;
}

/** The chunks of a still WebP that carry its picture: ALPH and VP8, or VP8L. */
const bitstreamOf = (webp: Uint8Array): Chunk[] => {
  if (text(webp, 0) !== "RIFF" || text(webp, 8) !== "WEBP") {
    throw new Error("Not a WebP image");
  }
  const view = new DataView(webp.buffer, webp.byteOffset, webp.byteLength);
  const chunks: Chunk[] = [];
  for (let offset = 12; offset + 8 <= webp.length; ) {
    const fourcc = text(webp, offset);
    const size = view.getUint32(offset + 4, true);
    if (fourcc === "ALPH" || fourcc === "VP8 " || fourcc === "VP8L") {
      chunks.push({ fourcc, payload: webp.subarray(offset + 8, offset + 8 + size) });
    }
    offset += 8 + size + (size & 1);
  }
  if (!chunks.some((part) => part.fourcc !== "ALPH"))
    throw new Error("WebP has no picture");
  return chunks;
};

const chunk = (fourcc: string, payload: ArrayLike<number>) => {
  const out = new Uint8Array(8 + payload.length + (payload.length & 1));
  out.set(ascii(fourcc));
  new DataView(out.buffer).setUint32(4, payload.length, true);
  out.set(payload, 8);
  return out;
};

const u24 = (value: number) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
];

const ascii = (value: string) => Uint8Array.from(value, (char) => char.charCodeAt(0));

const text = (bytes: Uint8Array, offset: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + 4));

const concat = (parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
};
