// An image's pixel size from its first bytes (the Rust station's image_size.rs): PNG, GIF, JPEG and WebP, the formats pages
// show inline. Nothing is decoded; unknown files give null.
import { closeSync, openSync, readSync } from "node:fs";

export function imageSize(path: string): [number, number] | null {
  try {
    const file = openSync(path, "r");
    try {
      const head = Buffer.alloc(64 * 1024);
      const n = readSync(file, head, 0, head.length, 0);
      return sizeOf(head.subarray(0, n));
    } finally {
      closeSync(file);
    }
  } catch {
    return null;
  }
}

export function sizeOf(b: Uint8Array): [number, number] | null {
  const ok = (w: number, h: number): [number, number] | null => (w > 0 && h > 0 ? [w, h] : null);
  const be32 = (i: number) => ((b[i]! << 24) | (b[i + 1]! << 16) | (b[i + 2]! << 8) | b[i + 3]!) >>> 0;
  const le32 = (i: number) => (b[i]! | (b[i + 1]! << 8) | (b[i + 2]! << 16) | (b[i + 3]! << 24)) >>> 0;
  const be16 = (i: number) => (b[i]! << 8) | b[i + 1]!;
  const le16 = (i: number) => b[i]! | (b[i + 1]! << 8);
  const le24 = (i: number) => b[i]! | (b[i + 1]! << 8) | (b[i + 2]! << 16);
  const ascii = (from: number, to: number) => String.fromCharCode(...b.subarray(from, to));
  if (b.length >= 24 && be32(0) === 0x89504e47 && ascii(12, 16) === "IHDR") return ok(be32(16), be32(20));
  if (b.length >= 10 && ascii(0, 3) === "GIF") return ok(le16(6), le16(8));
  if (b.length >= 30 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") {
    switch (ascii(12, 16)) {
      case "VP8 ":
        return ok(le16(26) & 0x3fff, le16(28) & 0x3fff);
      case "VP8L": {
        const v = le32(21);
        return ok((v & 0x3fff) + 1, ((v >>> 14) & 0x3fff) + 1);
      }
      case "VP8X":
        return ok(1 + le24(24), 1 + le24(27));
      default:
        return null;
    }
  }
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
    // Walk the markers to the first start-of-frame, which carries the size.
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = b[i + 1]!;
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      const length = be16(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) return ok(be16(i + 7), be16(i + 5));
      i += 2 + length;
    }
  }
  return null;
}
