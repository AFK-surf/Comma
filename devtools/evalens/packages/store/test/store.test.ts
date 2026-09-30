import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { EvalensLogger } from "@evalens/core";
import type {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  MetadataWriter,
  RunItemCommitMetadata,
  RunManifestMetadata,
} from "@evalens/store/metadata";
import { NoopMetadataWriter } from "@evalens/store/metadata";
import type { RunResult } from "@evalens/core/run";
import {
  canonicalJson,
  digestCanonicalJson,
  digestDataset,
  digestDatasetItem,
} from "@evalens/core/store/digest";
import { keyspace, ReindexMarker, Store, type ObjectNamespace } from "@evalens/store";
import { LocalObjectNamespace } from "@evalens/store/local";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

async function createOutputDir(): Promise<string> {
  const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-store-"));
  temporaryDirectories.push(outputDir);
  return outputDir;
}

const silentLogger = {
  info() {},
  error() {},
  warn() {},
  debug() {},
  trace() {},
  fatal() {},
  child() {
    return silentLogger;
  },
} as unknown as EvalensLogger;

const createLogger = () => ({
  logger: silentLogger,
  flush: () => Promise.resolve(),
  [Symbol.asyncDispose]: () => Promise.resolve(),
});

const timing = {
  startedAt: new Date("2026-01-01T00:00:00.000Z"),
  finishedAt: new Date("2026-01-01T00:00:00.010Z"),
  durationMs: 10,
};

function runInput(selectedItemIds: string[] = ["one"]) {
  return {
    experimentName: "store-test",
    description: "Store capability test",
    datasetName: "cases",
    datasetDigest: "dataset-digest",
    datasetSelectionDigest: "dataset-selection-digest",
    selectedItemIds,
    targetItemCount: selectedItemIds.length,
    tags: ["test"],
    adapters: [],
    params: {},
    paramsDigest: digestCanonicalJson({}),
  };
}

function evaluationInput() {
  return {
    evaluators: [{ name: "value", version: "1" }],
    aggregatorVersion: "1",
    adapters: [],
    params: {},
    paramsDigest: digestCanonicalJson({}),
  };
}

function createTestStore(
  namespace: ObjectNamespace,
  metadataWriter: MetadataWriter,
  ids: string[] = []
): Store {
  const pendingIds = [...ids];
  return new Store({
    namespace,
    metadataWriter,
    createLogger,
    createId: () => pendingIds.shift() ?? Bun.randomUUIDv7(),
    warn() {},
  });
}

class FailingMetadataWriter implements MetadataWriter {
  private fail(): Promise<never> {
    return Promise.reject(new Error("metadata unavailable"));
  }

  upsertRunManifest(_metadata: RunManifestMetadata): Promise<void> {
    return this.fail();
  }

  commitRunItem(_metadata: RunItemCommitMetadata): Promise<void> {
    return this.fail();
  }

  upsertEvalManifest(_metadata: EvalManifestMetadata): Promise<void> {
    return this.fail();
  }

  commitEvalItem(_metadata: EvalItemCommitMetadata): Promise<void> {
    return this.fail();
  }

  replaceAggregateScores(_metadata: AggregateScoresMetadata): Promise<void> {
    return this.fail();
  }
}

describe("Store", () => {
  test("uses validated item ids directly as native local file names", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const itemKey = keyspace.runItem("store-test", runId, "case-01.alpha_beta");

    expect(itemKey).toBe(
      `experiments/store-test/runs/${runId}/items/case-01.alpha_beta`
    );
    for (const invalid of ["A", "../outside", ".hidden", "é", "e\u0301", "ß"]) {
      expect(() => keyspace.runItem("store-test", runId, invalid)).toThrow(
        "item id must be portable lowercase ASCII"
      );
    }
    expect(() => namespace.file("../outside.json")).toThrow("escapes storage root");

    const file = namespace.file(path.posix.join(itemKey, "item.json"));
    await Bun.write(file, '{"itemId":"case-01.alpha_beta","itemDigest":"digest"}');
    expect(await file.json()).toEqual({
      itemId: "case-01.alpha_beta",
      itemDigest: "digest",
    });
    expect(
      Array.fromAsync(namespace.list(keyspace.runItems("store-test", runId)))
    ).resolves.toEqual([path.posix.join(itemKey, "item.json")]);
    await file.delete();
    expect(await file.exists()).toBe(false);
  });

  test("canonical digests sort object keys and dataset identities only", () => {
    const left = { b: 2, a: { y: [1, 2], x: true } };
    const right = { a: { x: true, y: [1, 2] }, b: 2 };
    expect(canonicalJson(left)).toBe('{"a":{"x":true,"y":[1,2]},"b":2}');
    expect(digestCanonicalJson(left)).toBe(digestCanonicalJson(right));
    expect(digestCanonicalJson([1, 2])).not.toBe(digestCanonicalJson([2, 1]));

    const item = { id: "one", input: { value: 1 }, expected: null, extra: "a" };
    const changed = { ...item, extra: "b" };
    const archived = {
      ...item,
      archive: new Bun.Archive({ "fixture.txt": "fixture" }),
    };
    expect(digestDatasetItem(item)).not.toBe(digestDatasetItem(changed));
    expect(digestDatasetItem(item)).toBe(digestDatasetItem(archived));
    expect(
      digestDataset([
        { itemId: "b", itemDigest: "digest-b" },
        { itemId: "a", itemDigest: "digest-a" },
      ])
    ).toBe(
      digestDataset([
        { itemId: "a", itemDigest: "digest-a" },
        { itemId: "b", itemDigest: "digest-b" },
      ])
    );
  });

  test("persists only an immutable reference to the dataset item", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [runId]);
    const item = {
      id: "archived",
      input: { value: 1 },
      expected: null,
      archive: new Bun.Archive({ "workspace/readme.txt": "hello" }),
    };
    {
      await using writer = await store.createRun(runInput([item.id]));
      await writer.commitItem(
        item.id,
        {
          status: "completed",
          result: null,
          trajectories: [],
          timing,
        },
        digestDatasetItem(item)
      );
      await writer.finish();
    }

    const itemRoot = path.join(
      outputDir,
      keyspace.runItem("store-test", runId, item.id)
    );
    expect(await Bun.file(path.join(itemRoot, "item.json")).json()).toEqual({
      itemId: item.id,
      itemDigest: digestDatasetItem(item),
    });
    expect(await Bun.file(path.join(itemRoot, "dataset_item.json")).exists()).toBe(
      false
    );
    expect(
      await Bun.file(path.join(itemRoot, "dataset_item_archive.tar")).exists()
    ).toBe(false);

    const stored = await Array.fromAsync(
      store.openRun("store-test", runId).iterateItems()
    );
    expect(stored).toEqual([
      expect.objectContaining({
        itemId: item.id,
        itemDigest: digestDatasetItem(item),
      }),
    ]);
  });

  test("rejects run items outside the manifest selection", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    await using store = createTestStore(namespace, new NoopMetadataWriter());
    await using writer = await store.createRun(runInput(["one"]));

    await expect(
      writer.commitItem(
        "two",
        { status: "completed", result: null, trajectories: [], timing },
        "item-digest"
      )
    ).rejects.toThrow("run item is outside the manifest selection: two");
  });

  test("persists and requires trajectory arrays for completed and error items", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [runId]);
    const completed = { id: "completed", input: null, expected: null };
    const failed = { id: "failed", input: null, expected: null };
    {
      await using writer = await store.createRun(runInput([completed.id, failed.id]));
      await writer.commitItem(
        completed.id,
        {
          status: "completed",
          result: null,
          trajectories: [],
          timing,
        },
        digestDatasetItem(completed)
      );
      await writer.commitItem(
        failed.id,
        {
          status: "error",
          error: "failed",
          timing,
        },
        digestDatasetItem(failed)
      );
      await writer.finish();
    }

    for (const item of [completed, failed]) {
      const key = path.posix.join(
        keyspace.runItem("store-test", runId, item.id),
        "trajectories.json"
      );
      expect(await namespace.file(key).json()).toEqual([]);
    }
    const stored = await Array.fromAsync(
      store.openRun("store-test", runId).iterateItems<null>()
    );
    const completedResult = stored.find(
      ({ itemId }) => itemId === completed.id
    )?.runResult;
    const failedResult = stored.find(({ itemId }) => itemId === failed.id)?.runResult;
    expect(completedResult).toMatchObject({
      status: "completed",
      trajectories: [],
    });
    expect(failedResult).toMatchObject({ status: "error", error: "failed" });
    expect("trajectories" in (failedResult ?? {})).toBe(false);

    const trajectoriesKey = path.posix.join(
      keyspace.runItem("store-test", runId, completed.id),
      "trajectories.json"
    );
    await namespace.file(trajectoriesKey).delete();
    await expect(
      Array.fromAsync(store.openRun("store-test", runId).iterateItems<null>())
    ).rejects.toThrow();
  });

  test("readers never mutate writer lifecycle state", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    await using store = createTestStore(namespace, new NoopMetadataWriter());
    let finishedRunId: string;
    {
      await using writer = await store.createRun(runInput());
      finishedRunId = writer.runId;
      await writer.finish();
    }
    const reader = store.openRun("store-test", finishedRunId);
    expect((await reader.readManifest()).status).toBe("finished");
    expect((await reader.readManifest()).status).toBe("finished");

    let abandonedRunId: string;
    {
      await using writer = await store.createRun(runInput());
      abandonedRunId = writer.runId;
    }
    expect(
      (await store.openRun("store-test", abandonedRunId).readManifest()).status
    ).toBe("error");
  });

  test("establishes an evaluation locator once before the first eval fact", async () => {
    const outputDir = await createOutputDir();
    const local = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    let locatorAccesses = 0;
    const namespace: ObjectNamespace = {
      file(key) {
        if (key === keyspace.evaluationScope(evalId)) locatorAccesses += 1;
        return local.file(key);
      },
      list(prefix) {
        return local.list(prefix);
      },
    };
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [
      runId,
      evalId,
    ]);
    const runWriter = await store.createRun(runInput());
    await runWriter.finish();
    await runWriter[Symbol.asyncDispose]();

    const evalWriter = await store.createEvaluation(
      store.openRun("store-test", runId),
      evaluationInput()
    );
    await evalWriter.commitItem("one", [
      {
        evaluator: "value",
        evaluatorVersion: "1",
        status: "completed",
        score: { value: 1 },
        timing,
      },
    ]);
    await evalWriter.saveAggregate({ value: 1 });
    await evalWriter.finish();
    await evalWriter[Symbol.asyncDispose]();

    expect(locatorAccesses).toBe(1);
    expect(await local.file(keyspace.evaluationScope(evalId)).json()).toMatchObject({
      experimentName: "store-test",
      runId,
      evalId,
    });
  });

  test("does not commit an eval fact when initial locator establishment fails", async () => {
    const outputDir = await createOutputDir();
    const local = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    const namespace: ObjectNamespace = {
      file(key) {
        return key === keyspace.evaluationScope(evalId)
          ? Bun.file(outputDir)
          : local.file(key);
      },
      list(prefix) {
        return local.list(prefix);
      },
    };
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [
      runId,
      evalId,
    ]);
    const runWriter = await store.createRun(runInput());
    await runWriter.finish();
    await runWriter[Symbol.asyncDispose]();

    await expect(
      store.createEvaluation(store.openRun("store-test", runId), evaluationInput())
    ).rejects.toThrow();
    expect(
      await local.file(keyspace.evalManifest("store-test", runId, evalId)).exists()
    ).toBe(false);
  });

  test("rejects item and aggregate writes after a writer finishes", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [
      runId,
      evalId,
    ]);
    const runWriter = await store.createRun(runInput());
    await runWriter.finish();
    await expect(
      runWriter.commitItem(
        "late",
        { status: "error", error: "late", timing },
        "late-digest"
      )
    ).rejects.toThrow("cannot commit run item with status finished");
    await runWriter[Symbol.asyncDispose]();

    const evalWriter = await store.createEvaluation(
      store.openRun("store-test", runId),
      evaluationInput()
    );
    await evalWriter.finish();
    await expect(evalWriter.saveAggregate({})).rejects.toThrow(
      "cannot save evaluation aggregate with status finished"
    );
    await expect(evalWriter.commitItem("late", [])).rejects.toThrow(
      "cannot commit evaluation item with status finished"
    );
    await evalWriter[Symbol.asyncDispose]();
  });

  test("parses persisted item, result, trajectory, and evaluation dates", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [
      runId,
      evalId,
    ]);
    const item = {
      id: "one",
      input: { value: 1 },
      expected: { value: 1 },
      category: "extra-field",
    };
    {
      await using writer = await store.createRun(runInput([item.id]));
      await writer.commitItem(
        item.id,
        {
          status: "completed",
          result: { value: 1 },
          trajectories: [
            {
              id: "trace-1",
              steps: [
                {
                  type: "assistant",
                  content: "done",
                  timestamp: timing.finishedAt,
                },
              ],
            },
          ],
          timing,
        },
        digestDatasetItem(item)
      );
      await writer.finish();
    }

    const run = store.openRun("store-test", runId);
    const [stored] = await Array.fromAsync(run.iterateItems<{ value: number }>());
    expect(stored).toMatchObject({
      itemId: item.id,
      itemDigest: digestDatasetItem(item),
    });
    expect(stored?.runResult.timing.startedAt).toBeInstanceOf(Date);
    if (stored?.runResult.status !== "completed") {
      throw new Error("expected completed run result");
    }
    expect(stored.runResult.trajectories?.[0]?.steps[0]?.timestamp).toBeInstanceOf(
      Date
    );

    {
      await using writer = await store.createEvaluation(run, {
        evaluators: [{ name: "value", version: "1" }],
        aggregatorVersion: "1",
        adapters: [],
        params: {},
        paramsDigest: digestCanonicalJson({}),
      });
      await writer.commitItem("one", [
        {
          evaluator: "value",
          evaluatorVersion: "1",
          status: "completed",
          score: { value: 1 },
          timing,
        },
      ]);
      await writer.finish();
    }
    const [evaluation] = await run.openEval(evalId).readItemResults("one");
    expect(evaluation?.status).toBe("completed");
    if (evaluation?.status === "completed") {
      expect(evaluation.timing.finishedAt).toBeInstanceOf(Date);
    }
  });

  test("keeps writers running in memory until final manifests persist", async () => {
    const outputDir = await createOutputDir();
    const local = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    let runManifestWrites = 0;
    let evalManifestWrites = 0;
    const namespace: ObjectNamespace = {
      file(key) {
        if (key === keyspace.runManifest("store-test", runId)) {
          runManifestWrites += 1;
          if (runManifestWrites === 2) return Bun.file(outputDir);
        }
        if (key === keyspace.evalManifest("store-test", runId, evalId)) {
          evalManifestWrites += 1;
          if (evalManifestWrites === 2) return Bun.file(outputDir);
        }
        return local.file(key);
      },
      list(prefix) {
        return local.list(prefix);
      },
    };
    await using store = createTestStore(namespace, new NoopMetadataWriter(), [
      runId,
      evalId,
    ]);

    const runWriter = await store.createRun(runInput());
    await expect(runWriter.finish()).rejects.toThrow();
    await runWriter[Symbol.asyncDispose]();
    expect((await store.openRun("store-test", runId).readManifest()).status).toBe(
      "error"
    );

    await Bun.write(
      local.file(keyspace.runManifest("store-test", runId)),
      JSON.stringify({
        ...(await store.openRun("store-test", runId).readManifest()),
        status: "finished",
      })
    );
    const run = store.openRun("store-test", runId);
    const evalWriter = await store.createEvaluation(run, {
      evaluators: [{ name: "value", version: "1" }],
      aggregatorVersion: "1",
      adapters: [],
      params: {},
      paramsDigest: digestCanonicalJson({}),
    });
    await expect(evalWriter.finish()).rejects.toThrow();
    await evalWriter[Symbol.asyncDispose]();
    expect((await run.openEval(evalId).readManifest()).status).toBe("error");
  });

  test("commits facts and writes scoped markers when metadata fails", async () => {
    const outputDir = await createOutputDir();
    const namespace = new LocalObjectNamespace(outputDir);
    const runId = Bun.randomUUIDv7();
    const evalId = Bun.randomUUIDv7();
    await using store = createTestStore(namespace, new FailingMetadataWriter(), [
      runId,
      evalId,
    ]);
    const item = { id: "one", input: { value: 1 }, expected: { value: 1 } };
    const result: RunResult<{ value: number }> = {
      status: "completed",
      result: { value: 1 },
      trajectories: [],
      timing,
    };

    {
      await using writer = await store.createRun(runInput());
      await writer.commitItem(item.id, result, digestDatasetItem(item));
      await writer.finish();
    }
    const runMarkerKeys = await Array.fromAsync(
      namespace.list(keyspace.runMarkerDirectory("store-test", runId))
    );
    const runMarker = ReindexMarker.parse(
      await namespace.file(runMarkerKeys[0]!).json()
    );
    expect(runMarker.scope).toEqual({
      type: "run",
      experimentName: "store-test",
      runId,
    });
    expect(
      await namespace
        .file(
          path.posix.join(keyspace.runItem("store-test", runId, "one"), "item.json")
        )
        .exists()
    ).toBe(true);

    const runReader = store.openRun("store-test", runId);
    {
      await using writer = await store.createEvaluation(runReader, {
        evaluators: [{ name: "value", version: "1" }],
        aggregatorVersion: "1",
        adapters: [],
        params: {},
        paramsDigest: digestCanonicalJson({}),
      });
      await writer.commitItem("one", [
        {
          evaluator: "value",
          evaluatorVersion: "1",
          status: "completed",
          score: { value: 1 },
          timing,
        },
      ]);
      await writer.saveAggregate({ value: 1 });
      await writer.finish();
    }
    const evalMarkerKeys = await Array.fromAsync(
      namespace.list(keyspace.evalMarkerDirectory("store-test", runId, evalId))
    );
    const evalMarker = ReindexMarker.parse(
      await namespace.file(evalMarkerKeys[0]!).json()
    );
    expect(evalMarker.scope).toEqual({
      type: "eval",
      experimentName: "store-test",
      runId,
      evalId,
    });
    expect(await namespace.file(keyspace.evaluationScope(evalId)).json()).toEqual({
      formatVersion: 1,
      experimentName: "store-test",
      runId,
      evalId,
    });
    expect(
      await namespace
        .file(
          path.posix.join(
            keyspace.evalItem("store-test", runId, evalId, "one"),
            "eval_results.json"
          )
        )
        .exists()
    ).toBe(true);
  });

  test("throws when metadata and marker writes both fail", async () => {
    const outputDir = await createOutputDir();
    const local = new LocalObjectNamespace(outputDir);
    const namespace: ObjectNamespace = {
      file(key) {
        return path.posix.basename(key).startsWith("marker-")
          ? Bun.file(outputDir)
          : local.file(key);
      },
      list(prefix) {
        return local.list(prefix);
      },
    };
    const runId = Bun.randomUUIDv7();
    const store = createTestStore(namespace, new FailingMetadataWriter(), [runId]);

    await expect(store.createRun(runInput())).rejects.toBeInstanceOf(AggregateError);
    expect(await local.file(keyspace.runManifest("store-test", runId)).exists()).toBe(
      true
    );
  });
});
