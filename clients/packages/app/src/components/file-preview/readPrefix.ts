// A text preview (a CSV table, a JSON tree) shows the start of a file when the whole file is larger than it draws:
// unlike `wholeFileOf`, a file over the limit is cut, not turned away.
import type { RangedFile } from "./PdfFilePreview";

/** Reads up to `maxBytes` from the start of a blob or ranged file, reporting whether more bytes remain. */
export async function readPrefix(
  source: { blob?: Blob | undefined; ranged?: RangedFile | undefined },
  signal: AbortSignal,
  maxBytes: number
): Promise<{ bytes: Uint8Array; truncated: boolean }> {
  if (source.ranged) {
    const first = await source.ranged.read(0, maxBytes, signal);
    const target = Math.min(first.size, maxBytes);
    const bytes = new Uint8Array(target);
    const initial = Math.min(first.bytes.length, target);
    bytes.set(first.bytes.subarray(0, initial));
    let offset = initial;
    while (offset < target) {
      const part = await source.ranged.read(offset, target - offset, signal);
      if (part.bytes.length === 0) break;
      const take = Math.min(part.bytes.length, target - offset);
      bytes.set(part.bytes.subarray(0, take), offset);
      offset += take;
    }
    return {
      bytes: offset < target ? bytes.subarray(0, offset) : bytes,
      truncated: first.size > offset,
    };
  }
  if (!source.blob) throw new Error("no file source");
  const truncated = source.blob.size > maxBytes;
  const slice = truncated ? source.blob.slice(0, maxBytes) : source.blob;
  return { bytes: new Uint8Array(await slice.arrayBuffer()), truncated };
}
