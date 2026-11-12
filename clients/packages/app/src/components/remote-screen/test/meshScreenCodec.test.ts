import { describe, expect, it } from "vitest";
import { codecOf } from "../screenDecoder";

const bytes = (...values: number[]) => Uint8Array.from(values);

describe("codecOf", () => {
  it("names an avcC by its profile, compatibility and level", () => {
    expect(codecOf("h264", bytes(1, 0x42, 0xe0, 0x2a, 0xff))).toBe("avc1.42e02a");
  });

  // As VideoToolbox's hardware encoder writes a Main profile's hvcC: the flags 0x60000000 reversed are 6.
  it("names an hvcC of the Main profile as a decoder knows it", () => {
    const hvcC = bytes(1, 0x01, 0x60, 0, 0, 0, 0xb0, 0, 0, 0, 0, 0, 120, 0xf0);
    expect(codecOf("h265", hvcC)).toBe("hvc1.1.6.L120.B0");
  });

  it("says a high tier, and keeps a later constraint byte's place", () => {
    const hvcC = bytes(1, 0x22, 0x20, 0, 0, 0, 0x90, 0x08, 0, 0, 0, 0, 153);
    expect(codecOf("h265", hvcC)).toBe("hvc1.2.4.H153.90.8");
  });

  // Reversed by bits and not by bytes: it is a stream a decoder refuses otherwise.
  it("reads a description that is a part of a larger buffer", () => {
    const whole = bytes(9, 9, 1, 0x01, 0x60, 0, 0, 0, 0xb0, 0, 0, 0, 0, 0, 93);
    expect(codecOf("h265", whole.subarray(2))).toBe("hvc1.1.6.L93.B0");
  });
});
