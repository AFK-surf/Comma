// What the platforms and the rest of the station both use and that is the same on every machine, in a module that
// imports nothing of the station's (so platform/windows.ts can use it without importing platform/index.ts back).
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/// The runner binary: STILLFAIL_RUNNER, else beside the station's code in a release, else where cargo built it. On
/// Windows, once `keepRunnerIn` has named a directory, a copy of it there (see `keepRunnerIn`).
export function runnerBinary(): string {
  const name = process.platform === "win32" ? "stillfail-runner.exe" : "stillfail-runner";
  const candidates = [
    process.env.STILLFAIL_RUNNER,
    fileURLToPath(new URL(`./${name}`, import.meta.url)),
    fileURLToPath(new URL(`../../native/runner/target/release/${name}`, import.meta.url)),
  ];
  const found = candidates.find((p) => p && existsSync(p));
  if (!found) throw new Error(`stillfail-runner is not there (looked at ${candidates.filter(Boolean).join(", ")})`);
  return kept ? kept.copyOf(found) : found;
}

/// Where runners run from on Windows, when not from where the station's release is. The desktop app's updater
/// (Velopack) ends every process whose executable is in the app's directory before it replaces it: runners started
/// from there would go with it, and their agents, outside it, go on without one (a station after the update could not
/// take them up and would start another beside them). Started from a copy here instead, a runner and its agent are
/// left be and taken up again, as on macOS and Linux.
let kept: RunnerCopies | null = null;

/// Runners run from copies in `dir` (Windows; elsewhere nothing changes). Copies no runner runs from are removed.
export function keepRunnerIn(dir: string) {
  if (process.platform !== "win32") return;
  kept = new RunnerCopies(dir);
  kept.prune();
}

class RunnerCopies {
  private copies = new Map<string, string>();
  private dir: string;
  constructor(dir: string) {
    this.dir = dir;
  }

  /// `source`'s copy, named by what it holds: one release's runner is one file, whichever station copied it. One that
  /// cannot be made leaves the runner where it is (as before).
  copyOf(source: string): string {
    const known = this.copies.get(source);
    if (known && existsSync(known)) return known;
    try {
      const hash = createHash("sha256").update(readFileSync(source)).digest("hex").slice(0, 16);
      const copy = join(this.dir, `stillfail-runner-${hash}.exe`);
      if (!existsSync(copy)) {
        mkdirSync(this.dir, { recursive: true });
        // Whole or not there: written beside it, then renamed (another station copying the same one meanwhile is
        // the same file).
        const part = `${copy}.${process.pid}.part`;
        copyFileSync(source, part);
        try {
          renameSync(part, copy);
        } catch (error) {
          if (!existsSync(copy)) throw error;
          unlinkSync(part);
        }
      }
      this.copies.set(source, copy);
      return copy;
    } catch {
      return source;
    }
  }

  /// Removes the copies of other releases no runner runs from: Windows does not let a running executable's file go.
  prune() {
    let names: string[];
    try {
      names = readdirSync(this.dir);
    } catch {
      return;
    }
    for (const name of names) {
      if (!/^stillfail-runner-[0-9a-f]+\.exe(\.\d+\.part)?$/.test(name)) continue;
      try {
        unlinkSync(join(this.dir, name));
      } catch {}
    }
  }
}

/// Whether one process is there.
export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}
