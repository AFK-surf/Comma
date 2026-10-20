// Files a window picked for Drive, kept in Main under opaque references (`synchronicity.stageImport`): the client core
// imports one by its reference (`importStaged`) and releases those it is done with. The path never leaves Main.
//
// Bounds: 1,000 references; one staged past them forgets the oldest.
import { randomUUID } from "node:crypto";
import { stat } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import type { SynchronicityStageImportResult } from "@comma/native-bridge";

const MAX_STAGED = 1_000;

export class StagedImports {
  readonly #paths = new Map<string, string>();

  async stage(sourcePath: string): Promise<SynchronicityStageImportResult> {
    if (!isAbsolute(sourcePath)) return { status: "unavailable" };
    const info = await stat(sourcePath).catch(() => null);
    if (!info?.isFile()) return { status: "unavailable" };
    const ref = randomUUID();
    this.#paths.set(ref, sourcePath);
    for (const oldest of this.#paths.keys()) {
      if (this.#paths.size <= MAX_STAGED) break;
      this.#paths.delete(oldest);
    }
    return { status: "staged", ref, name: basename(sourcePath), size: info.size };
  }

  /** The staged file's path; fails when it was released or forgotten. */
  path(ref: string): string {
    const path = this.#paths.get(ref);
    if (!path) throw new Error("The staged file is no longer kept.");
    return path;
  }

  release(refs: readonly string[]): void {
    for (const ref of refs) this.#paths.delete(ref);
  }
}
