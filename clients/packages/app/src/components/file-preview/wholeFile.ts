// An Office Open XML file (a deck, a Word document, a workbook) is a ZIP archive. It is read whole before any of it
// shows: its parts are found by the archive's directory at its end, and the renderers take the archive at once.
import type { RangedFile } from "./PdfFilePreview";

/** One read asks for at most this much (`files.readRange` takes at most 10 MB). */
const readChunk = 8 * 1024 * 1024;

export type WholeRead =
  | { bytes: Uint8Array<ArrayBuffer> }
  | { error: "too_large" | "failed" };

/** The whole file, a span at a time, or why it is not read: larger than `maxBytes`, or the read failed. */
export async function readWholeFile(
  file: RangedFile,
  signal: AbortSignal,
  maxBytes: number
): Promise<WholeRead> {
  const first = await file.read(0, Math.min(readChunk, maxBytes), signal);
  if (first.size > maxBytes) return { error: "too_large" };
  const bytes = new Uint8Array(first.size);
  bytes.set(first.bytes.subarray(0, first.size));
  let offset = first.bytes.length;
  while (offset < first.size) {
    const part = await file.read(
      offset,
      Math.min(readChunk, first.size - offset),
      signal
    );
    if (part.bytes.length === 0) return { error: "failed" };
    bytes.set(part.bytes.subarray(0, first.size - offset), offset);
    offset += part.bytes.length;
  }
  return { bytes };
}

/** A file given as a blob or read in spans, whole, up to `maxBytes`. */
export async function wholeFileOf(
  source: { blob?: Blob | undefined; ranged?: RangedFile | undefined },
  signal: AbortSignal,
  maxBytes: number
): Promise<WholeRead> {
  if (source.ranged) return readWholeFile(source.ranged, signal, maxBytes);
  if (!source.blob) return { error: "failed" };
  if (source.blob.size > maxBytes) return { error: "too_large" };
  return { bytes: new Uint8Array(await source.blob.arrayBuffer()) };
}

const maxEntries = 10_000;
/** What an archive may unpack to, by its own directory. */
const maxUnpackedBytes = 512 * 1024 * 1024;

/**
 * Whether an archive's directory keeps it within what a preview unpacks: at most 10,000 entries and 512 MiB in all.
 * The Word and Excel renderers unpack every part they read with no limit of their own, so an archive that would
 * unpack to gigabytes (a "ZIP bomb") is turned away before they see it. A ZIP64 archive, whose sizes are kept
 * elsewhere, is turned away too: no Office file needs one below the previews' limits.
 */
export function zipWithinLimits(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = bytes.length - 22;
  const stop = Math.max(0, bytes.length - 65_557);
  while (end >= stop && view.getUint32(end, true) !== 0x06054b50) end -= 1;
  if (end < stop) return false;
  const count = view.getUint16(end + 10, true);
  const directorySize = view.getUint32(end + 12, true);
  const directoryStart = view.getUint32(end + 16, true);
  if (
    count === 0xffff ||
    count > maxEntries ||
    directoryStart === 0xffffffff ||
    directoryStart + directorySize > end
  )
    return false;
  let unpacked = 0;
  let at = directoryStart;
  for (let entry = 0; entry < count; entry += 1) {
    if (at + 46 > end || view.getUint32(at, true) !== 0x02014b50) return false;
    const size = view.getUint32(at + 24, true);
    if (size === 0xffffffff) return false;
    unpacked += size;
    if (unpacked > maxUnpackedBytes) return false;
    at +=
      46 +
      view.getUint16(at + 28, true) +
      view.getUint16(at + 30, true) +
      view.getUint16(at + 32, true);
  }
  return true;
}

/** Whether a link in a rendered file may open: in the browser, or to write an email. */
export const opensInBrowser = (href: string) => /^(?:https?|mailto):/iu.test(href);
