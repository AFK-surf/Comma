import { afterEach, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { createFileLogger } from "@evalens/core/logger";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("file logger", () => {
  test("closes its destination when disposed", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-logger-"));
    temporaryDirectories.push(directory);
    const descriptorDirectory = existsSync("/proc/self/fd")
      ? "/proc/self/fd"
      : "/dev/fd";
    const before = (await readdir(descriptorDirectory)).length;

    for (let index = 0; index < 40; index += 1) {
      const logger = createFileLogger({
        logFile: path.join(directory, `${index}.jsonl`),
        bindings: { index },
      });
      logger.logger.info("entry");
      await logger[Symbol.asyncDispose]();
    }

    const after = (await readdir(descriptorDirectory)).length;
    expect(after).toBeLessThanOrEqual(before + 5);
  });
});
