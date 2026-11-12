import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

const native = resolve(import.meta.dirname, "../scripts/native.ts");

/// A Mach-O header with only an LC_SYMTAB.
function machO(stroff: number): Buffer {
  const file = Buffer.alloc(32 + 24);
  file.writeUInt32LE(0xfeedfacf, 0);
  file.writeUInt32LE(1, 16);
  file.writeUInt32LE(2, 32);
  file.writeUInt32LE(24, 36);
  file.writeUInt32LE(stroff, 32 + 16);
  return file;
}

/// `native.ts ensure <part>:darwin-arm64` with `file` (named `name`) already in an offline cache.
function ensureCached(part: string, name: string, file: Buffer | string) {
  const cache = mkdtempSync(join(tmpdir(), "native-macho-"));
  try {
    const env = { ...process.env, COMMA_STATION_NATIVE_CACHE: cache, COMMA_STATION_NATIVE: "offline" };
    const key = execFileSync(process.execPath, [native, "key", part], { env, encoding: "utf8" }).trim();
    const dir = join(cache, part, `darwin-arm64-${key}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "manifest.json"), "{}\n");
    writeFileSync(join(dir, name), file);
    return spawnSync(process.execPath, [native, "ensure", `${part}:darwin-arm64`], { env, encoding: "utf8" });
  } finally {
    rmSync(cache, { recursive: true, force: true });
  }
}

test("native.ts ensure refuses a Mac part whose string table is not 8-byte aligned", () => {
  const done = ensureCached("mesh", "mesh.node", machO(6041452));
  assert.notEqual(done.status, 0);
  assert.match(done.stderr, /string table at 6041452/);
});

test("native.ts ensure takes a Mac part that is not a Mach-O binary, such as scrcpy's server", () => {
  const done = ensureCached("scrcpy-server", "scrcpy-server", "PK\u0003\u0004 a jar of dex");
  assert.equal(done.status, 0, done.stderr);
});
