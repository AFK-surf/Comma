#!/usr/bin/env node
// A negative control for the unit proof. Both inputs give the same test
// outcomes, but their observations must differ. Cleanup failures must remain.
// Another order of the tests records the same execution: random values, a
// library's first-use draw and React's ids do not follow the order.
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const require = createRequire(resolve(root, "clients/package.json"));
const vitest = resolve(
  dirname(require.resolve("vitest/package.json")),
  "vitest.mjs",
);
const out = resolve(
  process.argv[2] ?? "node_modules/.cache/unit-record-control",
);
mkdirSync(out, { recursive: true });

function run(name, value, fail = false, args = []) {
  const path = resolve(out, `${name}.jsonl`);
  rmSync(path, { force: true });
  const result = spawnSync(
    process.execPath,
    [
      vitest,
      "run",
      "--config",
      "scripts/determinism/unit-control/vitest.config.mjs",
      ...args,
    ],
    {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        DETERMINISM_RECORD: path,
        DETERMINISM_CONTROL_VALUE: String(value),
        DETERMINISM_CONTROL_FAIL: fail ? "1" : "",
      },
    },
  );
  writeFileSync(resolve(out, `${name}.log`), result.stdout + result.stderr);
  assert.equal(result.status, fail ? 1 : 0, result.stdout + result.stderr);
  const records = readFileSync(path, "utf8").trim().split("\n").map(JSON.parse);
  return {
    path,
    records: new Map(records.map((record) => [record.test, record])),
  };
}

const first = run("first", 1);
const again = run("again", 1);
const changed = run("changed", 999);
const failed = run("failed", 1, true);
const shuffled = run("shuffled", 1, false, [
  "--sequence.shuffle",
  "--sequence.seed=1",
]);
assert.equal(
  first.records.size,
  19,
  "every control test must record its result",
);
for (const [name, record] of first.records) {
  assert.deepEqual(
    again.records.get(name),
    record,
    `${name}: same input changed`,
  );
  assert.deepEqual(
    shuffled.records.get(name),
    record,
    `${name}: another order changed it`,
  );
  if (name.endsWith("skips after an observation")) {
    assert.notEqual(
      record.status,
      "passed",
      "a skipped test was recorded as passed",
    );
    continue;
  }
  assert.equal(
    record.status,
    "passed",
    `${name}: a passed test was recorded as failed`,
  );
  if (name.endsWith("makes no observation")) {
    assert.equal(
      record.events,
      0,
      "an empty test must not claim an observation",
    );
    continue;
  }
  assert.ok(record.events > 0, `${name}: no observation`);
  assert.notEqual(
    record.digest,
    changed.records.get(name)?.digest,
    `${name}: changed values were accepted as the same execution`,
  );
}
for (const name of [
  "a cleanup observation",
  "a finished observation",
  "a soft assertion",
]) {
  const record = [...failed.records.values()].find((r) =>
    r.test.endsWith(name),
  );
  assert.equal(
    record?.status,
    "failed",
    `${name}: failure was recorded as passed`,
  );
}

const manifest = resolve(out, "manifest.txt");
writeFileSync(
  manifest,
  "scripts/determinism/unit-control/observations.test.ts\n",
);
for (const [other, status] of [
  [again, 0],
  [changed, 1],
  [failed, 1],
]) {
  const result = spawnSync(
    process.execPath,
    [
      resolve(root, "scripts/determinism/compare.mjs"),
      manifest,
      first.path,
      other.path,
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, status, result.stdout + result.stderr);
}
for (const fixture of ["empty", "skipped"]) {
  writeFileSync(
    manifest,
    `scripts/determinism/unit-control/${fixture}.test.ts\n`,
  );
  const rejected = spawnSync(
    process.execPath,
    [
      resolve(root, "scripts/determinism/compare.mjs"),
      manifest,
      first.path,
      again.path,
    ],
    { encoding: "utf8" },
  );
  assert.equal(
    rejected.status,
    1,
    `${fixture}: passed the determinism comparison`,
  );
}
console.log(
  "Unit recorder control passed: same inputs and another order agree, changed observations differ, cleanup failures and empty tests fail comparison.",
);
