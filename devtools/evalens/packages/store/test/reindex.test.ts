import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  IndexService,
  MetadataRepairLeaseLostError,
  type ReindexObjectSource,
} from "@evalens/store/metadata";
import {
  createLocalStore,
  LocalObjectNamespace,
  SqliteMetadataWriter,
} from "@evalens/store/local";
import { keyspace } from "@evalens/store";

const runId = "0197fb0d-1595-72b6-85d4-5c29d8101b10";
const evalId = "0197fb0d-1595-72b6-85d4-5c29d8101b11";
const itemId = "case-01.alpha_beta";
const startedAt = "2026-07-11T00:00:00.000Z";
const finishedAt = "2026-07-11T00:00:00.010Z";
const timing = { startedAt, finishedAt, durationMs: 10 };

let database: Database | undefined;
const temporaryDirectories: string[] = [];

afterEach(async () => {
  database?.close();
  database = undefined;
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("IndexService", () => {
  test("discovers markers only through the dedicated control prefix", async () => {
    const source = new MemorySource();
    source.set(keyspace.runMarker("basic", runId), {
      formatVersion: 1,
      detectedAt: finishedAt,
      reason: "metadata write failed",
      scope: { type: "run", experimentName: "basic", runId },
    });
    source.set(keyspace.runManifest("basic", runId), runManifest());
    database = new Database(":memory:");
    const service = new IndexService(source, new SqliteMetadataWriter(database));

    const markers = await service.findRelevantMarkers({ type: "all" });

    expect(markers.map(({ key }) => key)).toEqual([keyspace.runMarker("basic", runId)]);
    expect(source.listedPrefixes).toEqual([keyspace.reindexMarkers()]);
    expect(keyspace.runMarker("basic", runId).startsWith("experiments/")).toBe(false);
  });

  test("rebuilds a run and its evaluations before deleting covered markers", async () => {
    const source = new MemorySource();
    addFinishedRun(source);
    source.set(keyspace.runMarker("basic", runId), {
      formatVersion: 1,
      detectedAt: finishedAt,
      reason: "metadata write failed",
      scope: { type: "run", experimentName: "basic", runId },
    });
    source.set(keyspace.evalMarker("basic", runId, evalId), {
      formatVersion: 1,
      detectedAt: finishedAt,
      reason: "metadata write failed",
      scope: { type: "eval", experimentName: "basic", runId, evalId },
    });

    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    const service = new IndexService(source, writer);
    await service.reindex({ type: "run", experimentName: "basic", runId });

    expect(
      database
        .query("SELECT experiment_name, target_item_count FROM runs WHERE run_id = ?")
        .get(runId)
    ).toEqual({ experiment_name: "basic", target_item_count: 1 });
    expect(
      database
        .query("SELECT item_digest, status FROM run_items WHERE run_id = ?")
        .get(runId)
    ).toEqual({ item_digest: "item-digest", status: "completed" });
    expect(
      database
        .query("SELECT score_value FROM eval_scores WHERE eval_id = ?")
        .get(evalId)
    ).toEqual({ score_value: 1 });
    expect(
      database
        .query(
          `SELECT evaluator_name, evaluator_version, score_key
           FROM eval_score_identities WHERE eval_id = ?`
        )
        .get(evalId)
    ).toEqual({
      evaluator_name: "exact-match",
      evaluator_version: "1",
      score_key: "exactMatch",
    });
    expect(
      database
        .query("SELECT score_value FROM aggregate_scores WHERE eval_id = ?")
        .get(evalId)
    ).toEqual({ score_value: 1 });
    expect(database.query("SELECT adapter_name FROM run_adapters").get()).toEqual({
      adapter_name: "salix",
    });
    expect(database.query("SELECT adapter_name FROM eval_adapters").get()).toEqual({
      adapter_name: "codex",
    });
    expect(await source.exists(keyspace.runMarker("basic", runId))).toBe(false);
    expect(await source.exists(keyspace.evalMarker("basic", runId, evalId))).toBe(
      false
    );
  });

  test("rejects run manifests without a target item count", async () => {
    const source = new MemorySource();
    const { targetItemCount: _targetItemCount, ...legacyManifest } = runManifest();
    source.set(keyspace.runManifest("basic", runId), legacyManifest);
    database = new Database(":memory:");
    const service = new IndexService(source, new SqliteMetadataWriter(database));

    await expect(
      service.reindex({ type: "run", experimentName: "basic", runId })
    ).rejects.toThrow("targetItemCount");
  });

  test("does not clear existing metadata when a scope is still running", async () => {
    const source = new MemorySource();
    addFinishedRun(source);
    source.set(keyspace.runManifest("basic", runId), {
      ...runManifest(),
      status: "running",
      finishedAt: undefined,
    });

    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    await writer.upsertRunManifest(runManifest());
    const service = new IndexService(source, writer);

    expect(
      service.reindex({ type: "run", experimentName: "basic", runId })
    ).rejects.toThrow(`cannot reindex running run: ${runId}`);
    expect(database.query("SELECT COUNT(*) AS count FROM runs").get()).toEqual({
      count: 1,
    });
  });

  test("rebuilds from a fresh plan after the destructive replacement fence", async () => {
    const source = new MemorySource();
    addFinishedRun(source);
    const lateEvalId = "0197fb0d-1595-72b6-85d4-5c29d8101b12";
    const lateManifest = {
      formatVersion: 1 as const,
      evalId: lateEvalId,
      runId,
      evaluators: [{ name: "exact-match", version: "1" }],
      aggregatorVersion: "1",
      paramsDigest: "late-eval-params",
      createdAt: new Date(startedAt),
      finishedAt: new Date(finishedAt),
      status: "finished" as const,
      params: {},
      adapters: [],
    };

    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    await writer.upsertRunManifest(runManifest());
    const beginReindex = writer.beginReindex.bind(writer);
    writer.beginReindex = async (scope) => {
      source.set(keyspace.evalManifest("basic", runId, lateEvalId), lateManifest);
      await writer.upsertEvalManifest(lateManifest);
      return beginReindex(scope);
    };
    const service = new IndexService(source, writer);

    await service.reindex({ type: "run", experimentName: "basic", runId });

    expect(
      database.query("SELECT eval_id FROM evals WHERE eval_id = ?").get(lateEvalId)
    ).toEqual({ eval_id: lateEvalId });
  });

  test("replays when a normal writer finishes after the second plan is captured", async () => {
    const source = new MemorySource();
    const runningManifest = {
      ...runManifest(),
      status: "running" as const,
      finishedAt: undefined,
    };
    const finishedManifest = runManifest();
    source.set(keyspace.runManifest("basic", runId), runningManifest);

    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    const upsertRunManifest = writer.upsertRunManifest.bind(writer);
    let interleaved = false;
    writer.upsertRunManifest = async (metadata, options) => {
      if (options?.repair && metadata.status === "running" && !interleaved) {
        interleaved = true;
        source.set(keyspace.runManifest("basic", runId), finishedManifest);
        await upsertRunManifest(finishedManifest);
      }
      await upsertRunManifest(metadata, options);
    };
    const service = new IndexService(source, writer);

    await service.bootstrap();

    expect(interleaved).toBe(true);
    expect(
      database.query("SELECT status, finished_at FROM runs WHERE run_id = ?").get(runId)
    ).toEqual({
      status: "finished",
      finished_at: new Date(finishedAt).getTime(),
    });
    expect(
      database.query("SELECT COUNT(*) AS count FROM reindex_fences").get()
    ).toEqual({
      count: 0,
    });
    expect(
      database.query("SELECT state FROM index_metadata WHERE id = 1").get()
    ).toEqual({
      state: "ready",
    });
  });

  test("rejects a superseded repair lease before it mutates a ready index", async () => {
    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    const staleManifest = { ...runManifest(), description: "stale" };
    const currentManifest = { ...runManifest(), description: "current" };

    const staleRepair = await writer.beginReindex({ type: "all" });
    const currentRepair = await writer.beginReindex({ type: "all" });
    await writer.upsertRunManifest(currentManifest, { repair: currentRepair });
    expect(await writer.finishReindex(currentRepair)).toBe(true);

    await expect(
      writer.upsertRunManifest(staleManifest, { repair: staleRepair })
    ).rejects.toBeInstanceOf(MetadataRepairLeaseLostError);
    expect(
      database.query("SELECT description FROM runs WHERE run_id = ?").get(runId)
    ).toEqual({ description: "current" });
    expect(
      database.query("SELECT state FROM index_metadata WHERE id = 1").get()
    ).toEqual({
      state: "ready",
    });
  });

  test("invalidates an overlapping parent repair before starting a child repair", async () => {
    database = new Database(":memory:");
    const writer = new SqliteMetadataWriter(database);
    const parent = await writer.beginReindex({ type: "all" });
    const child = await writer.beginReindex({
      type: "run",
      experimentName: "basic",
      runId,
    });

    await expect(
      writer.upsertRunManifest(runManifest(), { repair: parent })
    ).rejects.toBeInstanceOf(MetadataRepairLeaseLostError);
    await writer.upsertRunManifest(runManifest(), { repair: child });
    expect(await writer.finishReindex(child)).toBe(true);
    expect(await writer.finishReindex(parent)).toBe(false);
  });

  test("deletes only marker keys captured by the completed repair", async () => {
    const source = new MemorySource();
    addFinishedRun(source);
    const capturedMarker = keyspace.runMarker("basic", runId, "captured");
    const laterMarker = keyspace.runMarker("basic", runId, "later");
    const marker = {
      formatVersion: 1 as const,
      detectedAt: finishedAt,
      reason: "metadata write failed",
      scope: { type: "run" as const, experimentName: "basic", runId },
    };
    source.set(capturedMarker, marker);
    source.beforeDelete = (key) => {
      if (key !== capturedMarker) return;
      source.beforeDelete = undefined;
      source.set(laterMarker, { ...marker, reason: "later metadata write failed" });
    };

    database = new Database(":memory:");
    const service = new IndexService(source, new SqliteMetadataWriter(database));
    await service.reindex({ type: "run", experimentName: "basic", runId });

    expect(await source.exists(capturedMarker)).toBe(false);
    expect(await source.exists(laterMarker)).toBe(true);
  });

  test("repairs a dirty run without reading an unrelated running run", async () => {
    const source = new MemorySource();
    addFinishedRun(source);
    const runningRunId = "0197fb0d-1595-72b6-85d4-5c29d8101b12";
    source.set(keyspace.runManifest("basic", runningRunId), {
      ...runManifest(),
      runId: runningRunId,
      status: "running",
      finishedAt: undefined,
    });
    source.set(keyspace.runMarker("basic", runId), {
      formatVersion: 1,
      detectedAt: finishedAt,
      reason: "metadata write failed",
      scope: { type: "run", experimentName: "basic", runId },
    });

    database = new Database(":memory:");
    const service = new IndexService(source, new SqliteMetadataWriter(database));
    await service.repairMarkedScopes({ type: "all" });

    expect(database.query("SELECT run_id FROM runs").all()).toEqual([
      { run_id: runId },
    ]);
    expect(await source.exists(keyspace.runMarker("basic", runId))).toBe(false);
  });

  test("bootstraps an index that contains an active run", async () => {
    const source = new MemorySource();
    source.set(keyspace.runManifest("basic", runId), {
      ...runManifest(),
      status: "running",
      finishedAt: undefined,
    });

    database = new Database(":memory:");
    const service = new IndexService(source, new SqliteMetadataWriter(database));
    await service.bootstrap();

    expect(
      database.query("SELECT status FROM runs WHERE run_id = ?").get(runId)
    ).toEqual({
      status: "running",
    });
  });

  test("rebuilds a recreated local index from persisted object facts", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-reindex-"));
    temporaryDirectories.push(outputDir);
    const namespace = new LocalObjectNamespace(outputDir);
    for (const [key, value] of finishedRunObjects()) {
      await Bun.write(namespace.file(key), JSON.stringify(value));
    }

    const store = await createLocalStore({ outputDir });
    await store[Symbol.asyncDispose]();
    database = new Database(path.join(outputDir, ".evalens", "index.sqlite"));
    expect(
      database.query("SELECT state FROM index_metadata WHERE id = 1").get()
    ).toEqual({ state: "ready" });
    expect(
      database.query("SELECT experiment_name FROM runs WHERE run_id = ?").get(runId)
    ).toEqual({ experiment_name: "basic" });
    expect(
      database
        .query("SELECT score_value FROM eval_scores WHERE eval_id = ?")
        .get(evalId)
    ).toEqual({ score_value: 1 });
  });

  test("rebuilds a ready local index when an object marker is present", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-reindex-"));
    temporaryDirectories.push(outputDir);
    const namespace = new LocalObjectNamespace(outputDir);
    for (const [key, value] of finishedRunObjects()) {
      await Bun.write(namespace.file(key), JSON.stringify(value));
    }
    let store = await createLocalStore({ outputDir });
    await store[Symbol.asyncDispose]();

    database = new Database(path.join(outputDir, ".evalens", "index.sqlite"));
    database.query("DELETE FROM runs").run();
    database.close();
    database = undefined;
    const markerKey = keyspace.runMarker("basic", runId);
    await Bun.write(
      namespace.file(markerKey),
      JSON.stringify({
        formatVersion: 1,
        detectedAt: finishedAt,
        reason: "repair test",
        scope: { type: "run", experimentName: "basic", runId },
      })
    );

    store = await createLocalStore({ outputDir });
    await store[Symbol.asyncDispose]();
    database = new Database(path.join(outputDir, ".evalens", "index.sqlite"));
    expect(database.query("SELECT COUNT(*) AS count FROM runs").get()).toEqual({
      count: 1,
    });
    expect(await namespace.exists(markerKey)).toBe(false);
  });
});

class MemorySource implements ReindexObjectSource {
  private readonly objects = new Map<string, string>();
  readonly listedPrefixes: string[] = [];
  beforeDelete?: (key: string) => void;

  set(key: string, value: unknown): void {
    this.objects.set(key, JSON.stringify(value));
  }

  async *list(prefix: string): AsyncIterable<string> {
    this.listedPrefixes.push(prefix);
    for (const key of [...this.objects.keys()].sort()) {
      if (key.startsWith(prefix)) yield key;
    }
  }

  async readJson(key: string): Promise<unknown> {
    const value = this.objects.get(key);
    if (value === undefined) throw new Error(`missing object: ${key}`);
    return JSON.parse(value);
  }

  async exists(key: string): Promise<boolean> {
    return this.objects.has(key);
  }

  async delete(key: string): Promise<void> {
    this.beforeDelete?.(key);
    this.objects.delete(key);
  }
}

function addFinishedRun(source: MemorySource): void {
  for (const [key, value] of finishedRunObjects()) source.set(key, value);
}

function finishedRunObjects(): Array<readonly [string, unknown]> {
  const runItem = keyspace.runItem("basic", runId, itemId);
  const evalItem = keyspace.evalItem("basic", runId, evalId, itemId);
  return [
    [keyspace.runManifest("basic", runId), runManifest()],
    [`${runItem}/run_result.json`, { status: "completed", result: "HELLO", timing }],
    [`${runItem}/item.json`, { itemId, itemDigest: "item-digest" }],
    [
      keyspace.evalManifest("basic", runId, evalId),
      {
        formatVersion: 1,
        evalId,
        runId,
        evaluators: [{ name: "exact-match", version: "1" }],
        aggregatorVersion: "1",
        paramsDigest: "eval-params",
        createdAt: startedAt,
        finishedAt,
        status: "finished",
        params: {},
        adapters: [{ name: "codex", version: "1" }],
      },
    ],
    [
      `${evalItem}/eval_results.json`,
      [
        {
          evaluator: "exact-match",
          evaluatorVersion: "1",
          status: "completed",
          score: { exactMatch: 1 },
          timing,
        },
      ],
    ],
    [
      `${keyspace.eval("basic", runId, evalId)}/aggregated_eval_results.json`,
      { exactMatch: 1 },
    ],
  ];
}

function runManifest() {
  return {
    formatVersion: 2 as const,
    runId,
    experimentName: "basic",
    description: "Basic experiment",
    datasetName: "basic-examples",
    datasetDigest: "dataset-digest",
    datasetSelectionDigest: "dataset-selection-digest",
    selectedItemIds: [itemId],
    targetItemCount: 1,
    status: "finished" as const,
    params: {},
    paramsDigest: "run-params",
    tags: ["example"],
    adapters: [{ name: "salix", version: "1" }],
    createdAt: new Date(startedAt),
    finishedAt: new Date(finishedAt),
  };
}
