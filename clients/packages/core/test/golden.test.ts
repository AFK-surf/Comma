// Every golden run (`CORE_GOLDEN_WRITE=1` keeps one per core a passing test made, under `test/golden/`) played again
// on this core: the same inputs at the same times give the same outputs. A change that is meant to keep the core's
// behavior (a refactor) passes this unchanged; one that changes behavior writes the runs it changes again.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { CoreLimits } from "../src/limits.ts";
import type { Entry, Input, Output } from "../src/record.ts";
import { goldenBytesBack } from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

type Golden = {
  test: string;
  sessionSource: "host" | "core";
  coalesceMs?: number;
  limits?: Partial<CoreLimits>;
  until: number;
  inputs: Entry<Input>[];
  outputs: Entry<Output>[];
};

const root = join(import.meta.dirname, "golden");
const files = (dir: string): string[] =>
  readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory()
      ? files(path)
      : name.endsWith(".json")
        ? [path]
        : [];
  });

describe("golden runs", () => {
  // None kept (`CORE_GOLDEN_WRITE` was not run): nothing to play again.
  const runs = existsSync(root) ? files(root) : [];
  it.skipIf(runs.length > 0)("none kept", () => undefined);
  for (const path of runs) {
    it(path.slice(root.length + 1), async () => {
      const golden = JSON.parse(readFileSync(path, "utf8"), goldenBytesBack) as Golden;
      const again = await replay(golden, {
        sessionSource: golden.sessionSource,
        ...(golden.coalesceMs !== undefined ? { coalesceMs: golden.coalesceMs } : {}),
        ...(golden.limits ? { limits: golden.limits } : {}),
        until: golden.until,
      });
      expect(comparable(again.outputs)).toEqual(comparable(golden.outputs));
    });
  }
});
