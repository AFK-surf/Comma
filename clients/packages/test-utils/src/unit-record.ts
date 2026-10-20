import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { relative, resolve } from "node:path";
import { afterAll, beforeEach, type RunnerTestCase } from "vitest";
import { observeAssertions, recordedClasses } from "./assertion-record";

// The determinism proof of unit test files (determinism/manifest.txt): with
// DETERMINISM_RECORD naming a JSONL file, each test appends its record
// {file, test, status, events, digest} (scripts/determinism/compare.mjs).
// Its events contain the values each matcher observed, in order. A passing
// assertion alone does not show that two runs observed the same value.

const require = createRequire(import.meta.url);
const reactId = /\b_r_[0-9a-z]+_/g;
const repository = resolve(import.meta.dirname, "../../../..");

// A test's name with its suites'.
const fullName = (test: RunnerTestCase) => {
  const names: string[] = [];
  for (let task: { name: string; suite?: unknown } | undefined = test; task; ) {
    names.unshift(task.name);
    task = task.suite as typeof task;
  }
  return names.join(" > ");
};

/** Appends each test's execution record to DETERMINISM_RECORD, when it is set. */
export function recordUnitTests() {
  const target = process.env.DETERMINISM_RECORD;
  if (!target) return;
  // Kept before the IO guard watches the file system (./io-guard): a
  // descriptor's writes, which it does not count.
  const { closeSync, openSync, writeSync } =
    require("node:fs") as typeof import("node:fs");
  const append = (line: string) => {
    const fd = openSync(target, "a");
    try {
      writeSync(fd, line);
    } finally {
      closeSync(fd);
    }
  };
  const records = new Map<
    RunnerTestCase,
    { hash: ReturnType<typeof createHash>; events: number; ids: Map<string, string> }
  >();
  let current: RunnerTestCase | undefined;
  const stop = observeAssertions((test, event) => {
    const owner = test ?? current;
    const record = owner && records.get(owner);
    if (!record) return;
    // React's useId values (`_r_1s_`) count the components the file rendered
    // before: they depend on the order of its tests, which no test reads. Each
    // is named by its first appearance in the test, so equal ids stay equal
    // and different ids stay different.
    event = event.replace(reactId, (id) => {
      if (!record.ids.has(id)) record.ids.set(id, `_r#${record.ids.size}_`);
      return record.ids.get(id)!;
    });
    record.hash.update(`${event.length}:`).update(event);
    record.events += 1;
  });
  beforeEach((context) => {
    current = context.task;
    const record = { hash: createHash("sha256"), events: 0, ids: new Map() };
    records.set(context.task, record);
    context.onTestFinished(() => {
      if (current === context.task) current = undefined;
    });
  });
  // A test's final state includes cleanup and Vitest's expected-failure rule.
  // Write once per file. Keep only a running hash per test, not its values.
  afterAll(() => {
    stop();
    const lines = [];
    const named = new Map<string, number>();
    for (const test of records.keys())
      named.set(fullName(test), (named.get(fullName(test)) ?? 0) + 1);
    for (const [test, record] of records) {
      // Tests of one name (`it.each` without a placeholder) are told apart by
      // their place in the file, which no order of running changes.
      const name = fullName(test);
      const state = test.result?.state;
      // A test the run skipped (skipIf, ctx.skip) is "skipped", not failed:
      // two runs that both skip it agree (scripts/determinism/compare.mjs).
      const status =
        state === "pass"
          ? "passed"
          : state === "skip" || test.mode === "skip"
            ? "skipped"
            : "failed";
      const digest = record.hash.update(`result ${status}`).digest("hex");
      lines.push(
        `${JSON.stringify({
          file: relative(repository, test.file.filepath),
          test: named.get(name)! > 1 ? `${name} [${test.id}]` : name,
          status,
          events: record.events,
          digest,
        })}\n`
      );
    }
    append(lines.join(""));
    // How many recorded values were class instances, by class.
    const stats = process.env.DETERMINISM_CLASS_STATS;
    if (stats && recordedClasses.size > 0) {
      const fd = openSync(stats, "a");
      try {
        writeSync(fd, `${JSON.stringify(Object.fromEntries(recordedClasses))}\n`);
      } finally {
        closeSync(fd);
      }
    }
    records.clear();
  });
}
