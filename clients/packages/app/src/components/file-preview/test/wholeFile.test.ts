import { expect, it } from "vitest";
import { zipWithinLimits } from "../wholeFile";

/** An archive's directory and end record alone, with entries that say they unpack to `sizes`. */
function archive(sizes: number[]) {
  const name = new TextEncoder().encode("a");
  const entry = 46 + name.length;
  const bytes = new Uint8Array(sizes.length * entry + 22);
  const view = new DataView(bytes.buffer);
  sizes.forEach((size, index) => {
    const at = index * entry;
    view.setUint32(at, 0x02014b50, true);
    view.setUint32(at + 24, size, true);
    view.setUint16(at + 28, name.length, true);
    bytes.set(name, at + 46);
  });
  const end = sizes.length * entry;
  view.setUint32(end, 0x06054b50, true);
  view.setUint16(end + 10, sizes.length, true);
  view.setUint32(end + 12, end, true);
  view.setUint32(end + 16, 0, true);
  return bytes;
}

it("lets through an archive that unpacks to at most 512 MiB", () => {
  expect(zipWithinLimits(archive([1024, 256 * 1024 * 1024]))).toBe(true);
});

it("turns away an archive that says it unpacks to more, or keeps its sizes as ZIP64", () => {
  expect(zipWithinLimits(archive([400 * 1024 * 1024, 200 * 1024 * 1024]))).toBe(false);
  expect(zipWithinLimits(archive([0xffffffff]))).toBe(false);
  expect(zipWithinLimits(new TextEncoder().encode("not an archive"))).toBe(false);
});
