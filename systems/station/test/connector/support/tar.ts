// Tar archives for tests, made and listed by the system `tar`: the archives under test are the connector's, so the
// fixtures come from an independent implementation.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tempDir } from "./temp.ts";

/** A gzipped tar of `entries` (relative path -> content). */
export function makeTarGz(entries: Record<string, string | Buffer>): Buffer {
  const dir = tempDir();
  for (const [name, data] of Object.entries(entries)) {
    mkdirSync(dirname(join(dir, name)), { recursive: true });
    writeFileSync(join(dir, name), data);
  }
  const out = join(tempDir(), "archive.tar.gz");
  execFileSync("tar", ["-czf", out, "-C", dir, ...Object.keys(entries)]);
  return readFileSync(out);
}

/** The entry names of a gzipped tar. */
export function tarGzNames(archive: Buffer): string[] {
  const path = join(tempDir(), "archive.tar.gz");
  writeFileSync(path, archive);
  return execFileSync("tar", ["-tzf", path], { maxBuffer: 1 << 30 })
    .toString()
    .split("\n")
    .filter(Boolean)
    .map((name) => name.replace(/^\.\//, "").replace(/\/$/, ""));
}
