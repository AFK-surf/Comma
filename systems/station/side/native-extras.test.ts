// The native addon's archive lock (native/mesh/src/local.rs) held across real processes: whether another process is
// kept waiting is the OS's doing, seen over real time, so it runs beside the checks (`pnpm test:side`), not in them.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadMesh } from "../src/mesh/native.ts";

test("an archive lock is held across processes", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lock-"));
  const path = join(dir, "archive.lock");
  const mesh = loadMesh();
  const mine = await mesh.fileLock(path);
  // Another process asks for it: it gets it only once this one lets go.
  const native = process.env.STILLFAIL_MESH_NATIVE ?? new URL("../native/mesh/target/release/libstillfail_mesh.dylib", import.meta.url).pathname;
  const child = spawn(process.execPath, ["-e", `const m={exports:{}};process.dlopen(m,${JSON.stringify(native)});m.exports.fileLock(${JSON.stringify(path)}).then(()=>{console.log("got");process.exit(0)})`], { stdio: ["ignore", "pipe", "inherit"] });
  let got = false;
  child.stdout.on("data", () => (got = true));
  await new Promise((r) => setTimeout(r, 400));
  assert.equal(got, false, "not while this process holds it");
  mine.release();
  await new Promise((r) => child.once("exit", r));
  assert.equal(got, true);
});
