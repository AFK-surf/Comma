// config.json as settings.rs keeps it: an edit checked, written privately, told; one that does not check out changes
// nothing; fields not known kept; an edit made elsewhere read again.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";

test("an edit is checked, written privately and told; unknown fields are kept", () => {
  const dir = mkdtempSync(join(tmpdir(), "config-"));
  writeFileSync(join(dir, "config.json"), JSON.stringify({ someday: { x: 1 } }));
  const config = new ConfigFile(dir);
  config.check = (raw) => {
    for (const p of raw.profiles ?? []) if (!/^[a-z0-9-]+$/.test(p.id)) throw new Error(`profile id ${JSON.stringify(p.id)}: use lowercase letters, digits and dashes`);
  };
  const told: any[] = [];
  config.listen((raw) => told.push(raw));
  config.update((raw) => (raw.profiles = [{ id: "cc", home: "homes/cc" }]));
  assert.equal(told.length, 1);
  // Private on Windows by the data directory's ACL (the user's profile's), which keeps no Unix modes.
  if (process.platform !== "win32") assert.equal(statSync(join(dir, "config.json")).mode & 0o777, 0o600);
  const stored = JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
  assert.deepEqual(stored, { someday: { x: 1 }, profiles: [{ id: "cc", home: "homes/cc" }] });
  assert.throws(() => config.update((raw) => (raw.profiles[0].id = "Bad")), /lowercase/);
  assert.equal(config.raw().profiles[0].id, "cc");
  assert.equal(JSON.parse(readFileSync(join(dir, "config.json"), "utf8")).profiles[0].id, "cc");
  // Written by something else: read again, and told.
  writeFileSync(join(dir, "config.json"), JSON.stringify({ language: "en", profiles: [] }) + "\n   ");
  assert.equal(config.raw().language, "en");
  assert.equal(told.length, 2);
});
