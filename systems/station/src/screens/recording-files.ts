// Temporary movies belong to one debug source. A download holds its movie until its response stream closes.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type RecordedMovie = {
  path: string;
  release?: () => void | Promise<void>;
};

export class RecordingFiles {
  #last: { folder: string; readers: number; retired: boolean } | null = null;

  async next(): Promise<string> {
    await this.close();
    const folder = await mkdtemp(join(tmpdir(), "comma-recording-"));
    this.#last = { folder, readers: 0, retired: false };
    return folder;
  }

  hold(path: string): RecordedMovie {
    const file = this.#last!;
    file.readers++;
    let released = false;
    return {
      path,
      release: () => {
        if (released) return;
        released = true;
        file.readers--;
        if (file.retired && file.readers === 0)
          return rm(file.folder, { recursive: true, force: true }).catch(
            () => {},
          );
      },
    };
  }

  async close(): Promise<void> {
    const file = this.#last;
    this.#last = null;
    if (!file) return;
    file.retired = true;
    if (file.readers === 0)
      await rm(file.folder, { recursive: true, force: true }).catch(() => {});
  }
}
