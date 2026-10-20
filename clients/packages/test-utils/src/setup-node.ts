import { readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { afterEach, expect, vi } from "vitest";
import { stopTimersOfEndedTests } from "./ended-test-timers";
import { forbidRealIo, watchRealIo } from "./io-guard";
import { keepTemporaryFilesInMemory } from "./memory-tmp";
import { seedRandomPerTest } from "./seeded-random";
import { recordUnitTests } from "./unit-record";

// The unit test files that still do real IO (determinism/unit-real-io.txt):
// their IO is reported, not refused, and they record no execution. Every
// other file runs on the deterministic harness.
const repository = resolve(import.meta.dirname, "../../../..");
const doesRealIo = readFileSync(`${repository}/determinism/unit-real-io.txt`, "utf8")
  .split("\n")
  .includes(relative(repository, expect.getState().testPath ?? ""));

if (doesRealIo) watchRealIo();
else {
  // Its record writes with the file system as it was (./unit-record).
  recordUnitTests();
  watchRealIo();
  keepTemporaryFilesInMemory();
  seedRandomPerTest();
  // Real IO fails the test (./io-guard).
  forbidRealIo();
}

stopTimersOfEndedTests();

afterEach(() => {
  vi.useRealTimers();
});
