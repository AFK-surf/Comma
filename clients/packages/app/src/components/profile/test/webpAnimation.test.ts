import { describe, expect, it } from "vitest";
import { animatedWebPOf } from "../webpAnimation";

const ascii = (value: string) => Array.from(value, (char) => char.charCodeAt(0));
const u32 = (value: number) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  value >>> 24,
];
const chunk = (fourcc: string, payload: number[]) => [
  ...ascii(fourcc),
  ...u32(payload.length),
  ...payload,
  ...(payload.length & 1 ? [0] : []),
];
/** A still WebP as a canvas writes it: VP8 alone, or VP8X, ALPH and VP8 when it has alpha. */
const still = (...chunks: number[][]) => {
  const body = chunks.flat();
  return Uint8Array.from([
    ...ascii("RIFF"),
    ...u32(4 + body.length),
    ...ascii("WEBP"),
    ...body,
  ]);
};

interface Read {
  fourcc: string;
  payload: Uint8Array;
}
const chunksOf = (bytes: Uint8Array, from: number, to = bytes.length): Read[] => {
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  const out: Read[] = [];
  for (let offset = from; offset < to; ) {
    const size = view.getUint32(offset + 4, true);
    out.push({
      fourcc: String.fromCharCode(...bytes.subarray(offset, offset + 4)),
      payload: bytes.subarray(offset + 8, offset + 8 + size),
    });
    offset += 8 + size + (size & 1);
  }
  return out;
};
const u24 = (bytes: Uint8Array, offset: number) =>
  bytes[offset]! | (bytes[offset + 1]! << 8) | (bytes[offset + 2]! << 16);

describe("animated WebP", () => {
  it("joins still frames into one looping animation that browsers can read", () => {
    const opaque = still(chunk("VP8 ", [1, 2, 3]));
    const clear = still(
      chunk("VP8X", Array(10).fill(0)),
      chunk("ALPH", [9]),
      chunk("VP8 ", [4, 5])
    );
    const webp = animatedWebPOf(
      [
        { webp: opaque, duration: 80 },
        { webp: clear, duration: 120.4 },
      ],
      96
    );

    expect(String.fromCharCode(...webp.subarray(0, 4))).toBe("RIFF");
    expect(new DataView(webp.buffer).getUint32(4, true)).toBe(webp.length - 8);
    expect(String.fromCharCode(...webp.subarray(8, 12))).toBe("WEBP");
    const chunks = chunksOf(webp, 12);
    expect(chunks.map((part) => part.fourcc)).toEqual(["VP8X", "ANIM", "ANMF", "ANMF"]);

    const [vp8x, anim, first, second] = chunks as [Read, Read, Read, Read];
    // Animated, with alpha because one frame has it; a 96 px canvas.
    expect(vp8x.payload[0]).toBe(0x12);
    expect(u24(vp8x.payload, 4) + 1).toBe(96);
    expect(u24(vp8x.payload, 7) + 1).toBe(96);
    // Loops for ever.
    expect([...anim.payload.subarray(4)]).toEqual([0, 0]);

    expect(u24(first.payload, 6) + 1).toBe(96);
    expect(u24(first.payload, 12)).toBe(80);
    expect(first.payload[15]).toBe(0x02);
    expect(
      chunksOf(first.payload, 16).map((part) => [part.fourcc, [...part.payload]])
    ).toEqual([["VP8 ", [1, 2, 3]]]);
    expect(u24(second.payload, 12)).toBe(120);
    expect(
      chunksOf(second.payload, 16).map((part) => [part.fourcc, [...part.payload]])
    ).toEqual([
      ["ALPH", [9]],
      ["VP8 ", [4, 5]],
    ]);
  });

  it("marks no alpha when every frame is opaque", () => {
    const webp = animatedWebPOf(
      [
        { webp: still(chunk("VP8 ", [1, 2])), duration: 100 },
        { webp: still(chunk("VP8 ", [3, 4])), duration: 100 },
      ],
      2
    );
    expect(chunksOf(webp, 12)[0]!.payload[0]).toBe(0x02);
  });
});
