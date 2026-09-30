import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { LocalIndexGuard, createLocalQueryRuntime } from "@evalens/store/local";

const runId = "0197fb0d-1595-72b6-85d4-5c29d8101b10";
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("local query runtime", () => {
  test("opens the local index eagerly and disposes it", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-query-runtime-"));
    temporaryDirectories.push(outputDir);

    {
      await using _runtime = await createLocalQueryRuntime(outputDir);
      expect(
        await Bun.file(path.join(outputDir, ".evalens/index.sqlite")).exists()
      ).toBe(true);
    }

    await expect(
      rm(path.join(outputDir, ".evalens"), { recursive: true })
    ).resolves.toBeUndefined();
  });

  test("single-flights index bootstrap", async () => {
    const rebuild = deferred<void>();
    let rebuilds = 0;
    const guard = new LocalIndexGuard(
      {
        getIndexState: () => "rebuilding",
        getRunExperimentName: () => undefined,
        getEvaluationScopes: () => [],
      },
      {
        async bootstrap() {
          rebuilds += 1;
          await rebuild.promise;
        },
        async repairMarkedScopes() {},
        async repairRunMarkers() {},
        async findEvaluationScopes() {
          return [];
        },
      }
    );

    const first = guard.ensureAll();
    const second = guard.ensureAll();
    await waitForCondition(() => rebuilds === 1);
    const third = guard.ensureAll();
    rebuild.resolve();

    expect(await Promise.all([first, second, third])).toEqual([true, true, true]);
    expect(rebuilds).toBe(1);
  });

  test("repairs only the scope requested by a run query", async () => {
    const repaired: unknown[] = [];
    const guard = new LocalIndexGuard(
      {
        getIndexState: () => "ready",
        getRunExperimentName: (id) => (id === runId ? "basic" : undefined),
        getEvaluationScopes: () => [],
      },
      {
        async bootstrap() {},
        async repairMarkedScopes(scope) {
          repaired.push(scope);
        },
        async repairRunMarkers() {},
        async findEvaluationScopes() {
          return [];
        },
      }
    );

    expect(await guard.ensureRun(runId)).toBe(true);
    expect(repaired).toEqual([{ type: "run", experimentName: "basic", runId }]);
  });

  test("repairs only scopes containing selected evaluations", async () => {
    const evalId = Bun.randomUUIDv7();
    const repaired: unknown[] = [];
    const guard = new LocalIndexGuard(
      {
        getIndexState: () => "ready",
        getRunExperimentName: () => undefined,
        getEvaluationScopes: () => [{ evalId, runId, experimentName: "basic" }],
      },
      {
        async bootstrap() {},
        async repairMarkedScopes(scope) {
          repaired.push(scope);
        },
        async repairRunMarkers() {},
        async findEvaluationScopes() {
          return [];
        },
      }
    );

    expect(await guard.ensureEvaluations([evalId])).toBe(true);
    expect(repaired).toEqual([
      { type: "eval", experimentName: "basic", runId, evalId },
    ]);
  });
});

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((fulfill) => {
    resolve = fulfill;
  });
  return { promise, resolve };
}

async function waitForCondition(condition: () => boolean) {
  while (!condition()) await Bun.sleep(0);
}
