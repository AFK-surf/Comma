import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const migrationDir = path.dirname(fileURLToPath(import.meta.url));

test("migration version numbers are unique", () => {
  const versions = new Map();

  for (const fileName of readdirSync(migrationDir)) {
    if (!fileName.endsWith(".exs")) {
      continue;
    }

    const version = fileName.match(/^(\d+)_/)?.[1];
    assert.ok(version, `migration file must start with a version: ${fileName}`);

    const previous = versions.get(version);
    assert.equal(
      previous,
      undefined,
      `duplicate migration version ${version}: ${previous} and ${fileName}`,
    );
    versions.set(version, fileName);
  }
});
