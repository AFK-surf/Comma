import type { FilesSaveDownloadResult } from "@comma/native-bridge";

/** A save into Downloads that takes a file's chunks as they come (`CoreDesktopHost.saveDownloadStream`). */
type SaveStream = (input: {
  chunks: AsyncIterable<Uint8Array>;
  fileName: string;
}) => Promise<FilesSaveDownloadResult>;

/**
 * The chunks of a save as the core gives them: each is taken once the one before it is written, so the core sends no
 * more than the disk takes. `end` ends the file; `fail` makes the save give it up (nothing of it stays).
 */
class Chunks implements AsyncIterable<Uint8Array> {
  readonly #queue: { item: Uint8Array | null | Error; taken: () => void }[] = [];
  #wake: (() => void) | undefined;

  /** Settles once the writer took `item` (wrote the chunk before it). */
  push(item: Uint8Array | null | Error): Promise<void> {
    return new Promise((taken) => {
      this.#queue.push({ item, taken });
      this.#wake?.();
    });
  }

  async *[Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    for (;;) {
      while (this.#queue.length === 0)
        await new Promise<void>((wake) => (this.#wake = wake));
      this.#wake = undefined;
      const { item, taken } = this.#queue.shift()!;
      if (item === null) return taken();
      if (item instanceof Error) {
        taken();
        throw item;
      }
      yield item;
      taken();
    }
  }
}

/**
 * Files the core saves into Downloads a part at a time (a file of a Task a station hosts, which only the core reads):
 * each written through the streamed save as its parts come, one at a time. Given up, or failed, nothing of it stays.
 */
export class PartSaves {
  readonly #open = new Map<
    number,
    { chunks: Chunks; result: Promise<FilesSaveDownloadResult> }
  >();
  #next = 1;

  open(fileName: string, save: SaveStream): { id: number } {
    const id = this.#next++;
    const chunks = new Chunks();
    const result = save({ chunks, fileName });
    // A save that failed is said when it is written to or closed.
    result.catch(() => undefined);
    this.#open.set(id, { chunks, result });
    return { id };
  }

  /** Writes `bytes` once the part before it is written; fails as the save did. */
  async write(id: number, bytes: Uint8Array): Promise<null> {
    const open = this.#open.get(id);
    if (!open) throw new Error("No such save.");
    await Promise.race([
      open.chunks.push(bytes),
      open.result.then(() => {
        throw new Error("The save ended.");
      }),
    ]);
    return null;
  }

  /** Kept, the file is in place: its handle and the name it took; null when it could not be saved, or is given up. */
  async close(
    id: number,
    keep: boolean
  ): Promise<{ downloadRef: string; fileName: string } | null> {
    const open = this.#open.get(id);
    if (!open) throw new Error("No such save.");
    this.#open.delete(id);
    void open.chunks.push(keep ? null : new Error("The save was given up."));
    const saved = await open.result.catch(() => null);
    return keep && saved?.status === "saved"
      ? { downloadRef: saved.downloadRef, fileName: saved.fileName }
      : null;
  }
}
