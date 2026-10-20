import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";

// Local build bookkeeping only. These records do not authenticate artifacts.
// Compilers still check source dependencies. Installation tracks their outputs.
export function snapshotPaths(paths: string[]): unknown[] {
  return paths.map((path) => {
    const stat = lstatSync(path, { bigint: true });
    if (stat.isSymbolicLink()) {
      return [path, readlinkSync(path), snapshotPaths([realpathSync(path)])];
    }
    if (stat.isDirectory()) {
      return [
        path,
        stat.mode.toString(),
        snapshotPaths(
          readdirSync(path)
            .toSorted()
            .map((name) => join(path, name))
        ),
      ];
    }
    return [
      path,
      stat.size.toString(),
      stat.mtimeNs.toString(),
      stat.ctimeNs.toString(),
      stat.mode.toString(),
    ];
  });
}

export class NativeInstallCache {
  constructor(
    private readonly record: string,
    private readonly enabled: boolean,
    private readonly inputs: unknown,
    private readonly outputs: string[]
  ) {}

  private value() {
    return JSON.stringify({
      version: 1,
      inputs: this.inputs,
      outputs: snapshotPaths(this.outputs),
    });
  }

  reuse(): boolean {
    if (this.enabled && this.outputs.every((path) => existsSync(path))) {
      try {
        if (readFileSync(this.record, "utf8") === this.value()) return true;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    // A failed replacement must not leave a reusable receipt.
    rmSync(this.record, { force: true });
    return false;
  }

  save() {
    if (!this.enabled) return;
    mkdirSync(dirname(this.record), { recursive: true });
    writeFileSync(`${this.record}.tmp`, this.value());
    renameSync(`${this.record}.tmp`, this.record);
  }
}

export function copyNativeFile(source: string, target: string, incremental: boolean) {
  if (
    incremental &&
    existsSync(target) &&
    statSync(source).mode === statSync(target).mode &&
    readFileSync(source).equals(readFileSync(target))
  )
    return;
  mkdirSync(dirname(target), { recursive: true });
  // Replace the inode instead of overwriting a signed Mach-O in place.
  copyFileSync(source, `${target}.tmp`);
  renameSync(`${target}.tmp`, target);
}
