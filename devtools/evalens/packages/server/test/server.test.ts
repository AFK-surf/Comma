import { describe, expect, test } from "bun:test";
import { Database, type SQLQueryBindings } from "bun:sqlite";
import { mkdir, mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { EvalCatalogEntry, QueryService, RunSummary } from "@evalens/core";
import { digestCanonicalJson } from "@evalens/core/store/digest";
import { keyspace, type ResultDownloadStore } from "@evalens/store";
import {
  D1MetadataWriter,
  D1QueryService,
  R2IndexSource,
} from "@evalens/store/cloudflare";
import { createLocalStore, SqliteMetadataWriter } from "@evalens/store/local";
import {
  IndexService,
  MetadataRepairLeaseLostError,
  NoopMetadataWriter,
  type MetadataWriter,
  type ReindexScope,
  type RunManifestMetadata,
} from "@evalens/store/metadata";
import {
  createApi,
  createLocalApi,
  createRemoteIngestionApp,
  serveLocal,
  GitHubDispatcher,
} from "@evalens/server";
import { connectToFetch } from "@evalens/server/local/connect";
import { ReindexScheduler } from "@evalens/server/cloudflare/index-guard";

const runId = "0197fb0d-1595-72b6-85d4-5c29d8101b10";
const evalId = "0197fb0d-1595-72b6-85d4-5c29d8101b11";
const runningEvalId = "0197fb0d-1595-72b6-85d4-5c29d8101b12";
const comparisonEvalId = "0197fb0d-1595-72b6-85d4-5c29d8101b13";
const timing = {
  startedAt: new Date("2026-07-11T00:00:00.000Z"),
  finishedAt: new Date("2026-07-11T00:00:00.010Z"),
  durationMs: 10,
};
const laterTiming = {
  startedAt: new Date("2026-07-11T00:01:00.000Z"),
  finishedAt: new Date("2026-07-11T00:01:00.010Z"),
  durationMs: 10,
};

describe("Elysia API", () => {
  test("validates metadata DTOs before writing D1", async () => {
    const writes: RunManifestMetadata[] = [];
    const writer = metadataWriter({
      upsertRunManifest(manifest) {
        writes.push(manifest);
        return Promise.resolve();
      },
    });
    const api = createRemoteIngestionApp(writer);
    const body = {
      formatVersion: 2,
      runId,
      experimentName: "basic",
      datasetName: "basic-dataset",
      datasetDigest: "digest",
      datasetSelectionDigest: "selection-digest",
      selectedItemIds: ["one"],
      targetItemCount: 1,
      status: "running",
      params: {},
      paramsDigest: "params",
      tags: ["example"],
      adapters: [{ name: "salix", version: "1" }],
      createdAt: "2026-07-11T00:00:00.000Z",
    };

    const response = await api.handle(request("/api/results/metadata/runs", body));
    expect(response.status).toBe(200);
    expect(writes).toHaveLength(1);
    expect(writes[0]?.createdAt).toBeInstanceOf(Date);
  });

  test("returns 202 instead of partial query results while reindexing", async () => {
    const api = createApi({
      resultStore: resultStore(),
      queryService: emptyQueryService(),
      indexGuard: {
        ensureAll: async () => false,
        ensureExperiment: async () => false,
        ensureRun: async () => false,
        ensureEvaluations: async () => false,
      },
    });

    const response = await api.handle(new Request("http://localhost/api/runs"));
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      state: "reindexing",
      message: "result index is rebuilding",
    });
  });

  test("keeps resource metadata separate from paginated run items", async () => {
    const run: RunSummary = {
      id: runId,
      experimentName: "basic",
      datasetName: "cases",
      datasetDigest: "dataset",
      datasetSelectionDigest: "selection",
      targetItemCount: 1,
      status: "finished",
      tags: [],
      adapters: [],
      params: {},
      createdAt: timing.startedAt.toISOString(),
      updatedAt: timing.finishedAt.toISOString(),
      finishedAt: timing.finishedAt.toISOString(),
      itemCounts: { completed: 1, error: 0 },
      evalCount: 1,
    };
    const evaluation: EvalCatalogEntry = {
      id: evalId,
      status: "finished",
      params: {},
      aggregatorVersion: "1",
      evaluators: [],
      scoreIdentities: [],
      adapters: [],
      aggregateScores: {},
      createdAt: timing.startedAt.toISOString(),
      finishedAt: timing.finishedAt.toISOString(),
      resultCounts: { target: 0, completed: 0, error: 0, skipped: 0 },
      run: {
        id: runId,
        experimentName: "basic",
        datasetName: "cases",
        datasetDigest: "dataset",
        datasetSelectionDigest: "selection",
        tags: [],
        params: {},
        createdAt: timing.startedAt.toISOString(),
      },
    };
    const api = createApi({
      resultStore: resultStore(),
      queryService: {
        ...emptyQueryService(),
        getRun: async (id) => (id === runId ? run : null),
        getEvaluation: async (id) => (id === evalId ? evaluation : null),
        listRunItems: async (_runId, _evalId, page = 1, pageSize = 50) => ({
          items: [],
          page,
          pageSize,
          total: 1,
        }),
      },
    });

    const runResponse = await api.handle(
      new Request(`http://localhost/api/runs/${runId}`)
    );
    expect(await runResponse.json()).toEqual(run);
    const evalResponse = await api.handle(
      new Request(`http://localhost/api/evaluations/${evalId}`)
    );
    expect(await evalResponse.json()).toEqual(evaluation);
    const itemsResponse = await api.handle(
      new Request(
        `http://localhost/api/runs/${runId}/items?evalId=${evalId}&page=2&pageSize=10`
      )
    );
    expect(await itemsResponse.json()).toEqual({
      items: [],
      page: 2,
      pageSize: 10,
      total: 1,
    });
  });

  test("guards filtered evaluations and comparisons by their relevant scopes", async () => {
    const calls: string[] = [];
    const api = createApi({
      resultStore: resultStore(),
      queryService: emptyQueryService(),
      indexGuard: {
        ensureAll: async () => {
          calls.push("all");
          return true;
        },
        ensureExperiment: async (experimentName) => {
          calls.push(`experiment:${experimentName}`);
          return true;
        },
        ensureRun: async (id) => {
          calls.push(`run:${id}`);
          return true;
        },
        ensureEvaluations: async (evalIds) => {
          calls.push(`evaluations:${evalIds.join(",")}`);
          return true;
        },
      },
    });

    expect(
      (
        await api.handle(
          new Request("http://localhost/api/evaluations?experimentName=clean")
        )
      ).status
    ).toBe(200);
    expect(
      (await api.handle(new Request(`http://localhost/api/evaluations?runId=${runId}`)))
        .status
    ).toBe(200);
    expect(
      (
        await api.handle(
          new Request(`http://localhost/api/runs/${runId}/items?evalId=${evalId}`)
        )
      ).status
    ).toBe(404);
    expect(
      (
        await api.handle(
          request("/api/evaluations/compare", { evalIds: [Bun.randomUUIDv7()] })
        )
      ).status
    ).toBe(200);
    expect(calls).toEqual([
      "experiment:clean",
      `run:${runId}`,
      `run:${runId}`,
      `evaluations:${evalId}`,
      expect.stringMatching(/^evaluations:/),
    ]);
  });

  test("returns an empty comparison when no evaluations are selected", async () => {
    const api = createApi({
      resultStore: resultStore(),
      queryService: emptyQueryService(),
    });

    const response = await api.handle(
      request("/api/evaluations/compare", { evalIds: [] })
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      evaluations: [],
      sharedItemCount: 0,
      itemPage: 1,
      itemPageSize: 100,
      itemMetrics: [],
    });
  });

  test("rejects an unbounded comparison selection", async () => {
    const api = createApi({
      resultStore: resultStore(),
      queryService: emptyQueryService(),
    });

    const response = await api.handle(
      request("/api/evaluations/compare", {
        evalIds: Array.from({ length: 9 }, (_, index) => `eval-${index}`),
      })
    );
    expect(response.status).toBe(422);
  });

  test("streams authenticated dashboard downloads without buffering", async () => {
    const api = createApi({
      resultStore: resultStore({
        readRunLog: async () => r2Object("log line\n", "application/x-ndjson"),
      }),
      queryService: emptyQueryService(),
    });
    const response = await api.handle(
      new Request(
        `http://localhost/api/results/downloads/experiments/basic/runs/${runId}/items/item-1/log`
      )
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("content-disposition")).toBe(
      'inline; filename="run.log.jsonl"'
    );
    expect(response.headers.get("content-type")).toBe("application/x-ndjson");
    expect(await response.text()).toBe("log line\n");
  });

  test("serves artifact metadata and raw result objects", async () => {
    const api = createApi({
      resultStore: resultStore({
        readRunArtifactMetadata: async () => ({
          size: 123,
          etag: "etag",
          contentType: "application/x-tar",
        }),
      }),
      queryService: emptyQueryService(),
    });
    const root = `http://localhost/api/results/downloads/experiments/basic/runs/${runId}/items/one`;
    const metadata = await api.handle(new Request(`${root}/artifact/metadata`));
    expect(await metadata.json()).toEqual({
      size: 123,
      etag: "etag",
      contentType: "application/x-tar",
    });
  });

  test("returns not found when a trajectory object is missing", async () => {
    const root = `http://localhost/api/results/downloads/experiments/basic/runs/${runId}/items/one/trajectories`;
    const api = createApi({
      resultStore: resultStore({
        readRunResult: async () =>
          new Blob(['{"status":"completed","result":null}'], {
            type: "application/json",
          }),
      }),
      queryService: emptyQueryService(),
    });

    const missing = await api.handle(new Request(root));
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ message: "trajectories.json not found" });
  });
});

describe("ReindexScheduler", () => {
  test("single-flights Cloudflare bootstrap separately from scoped repair", async () => {
    const pending = deferred<void>();
    const scheduled: Promise<void>[] = [];
    let bootstraps = 0;
    class DeferredIndexWriter extends NoopMetadataWriter {
      async beginReindex(_scope: ReindexScope) {
        bootstraps += 1;
        await pending.promise;
        return {
          scopeKey: "all",
          scopeType: "all" as const,
          leaseId: Bun.randomUUIDv7(),
        };
      }

      async finishReindex() {
        return true;
      }
    }
    const indexService = new IndexService(
      {
        async *list() {},
        async readJson(key) {
          throw new Error(`unexpected object read: ${key}`);
        },
        async exists() {
          return false;
        },
        async delete() {},
      },
      new DeferredIndexWriter()
    );
    const scheduler = new ReindexScheduler(indexService, (operation) =>
      scheduled.push(operation)
    );

    scheduler.scheduleBootstrap();
    scheduler.scheduleBootstrap();
    expect(scheduled).toHaveLength(1);
    await waitForCondition(() => bootstraps === 1);

    pending.resolve();
    const [scheduledBootstrap] = scheduled;
    if (!scheduledBootstrap) throw new Error("bootstrap was not scheduled");
    await scheduledBootstrap;
    scheduler.scheduleBootstrap();
    await waitForCondition(() => bootstraps === 2);
  });
});

describe("R2 index source", () => {
  test("lists a scoped directory without matching sibling experiment names", async () => {
    const prefixes: string[] = [];
    const keys = [
      "experiments/basic/runs/one/manifest.json",
      "experiments/basic-v2/runs/two/manifest.json",
    ];
    const bucket = {
      async list(options: { prefix: string }) {
        prefixes.push(options.prefix);
        return {
          objects: keys
            .filter((key) => key.startsWith(options.prefix))
            .map((key) => ({ key })),
          truncated: false,
        };
      },
    } as unknown as R2Bucket;

    const listed = await Array.fromAsync(
      new R2IndexSource(bucket).list("experiments/basic")
    );
    expect(prefixes).toEqual(["experiments/basic/"]);
    expect(listed).toEqual(["experiments/basic/runs/one/manifest.json"]);
  });
});

describe("local Elysia server", () => {
  test("creates and finishes a fresh local index before serving queries", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-local-server-"));
    const local = await createLocalApi(outputDir);
    try {
      const response = await local.app.handle(
        new Request("http://localhost/api/experiments")
      );
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual([]);
      const database = new Database(path.join(outputDir, ".evalens", "index.sqlite"), {
        readonly: true,
      });
      expect(
        database.query("SELECT state FROM index_metadata WHERE id = 1").get()
      ).toEqual({ state: "ready" });
      database.close();
    } finally {
      local.close();
      await rm(outputDir, { recursive: true, force: true });
    }
  });

  test("rebuilds a deleted local index from persisted object facts", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-local-server-"));
    const store = await createLocalStore({ outputDir });
    const writer = await store.createRun({
      experimentName: "restored",
      description: "restored from objects",
      datasetName: "cases",
      datasetDigest: "dataset-digest",
      datasetSelectionDigest: "dataset-selection-digest",
      selectedItemIds: ["one"],
      targetItemCount: 1,
      tags: ["test"],
      adapters: [],
      params: {},
      paramsDigest: await digestCanonicalJson({}),
    });
    await writer.finish();
    const restoredRunId = writer.runId;
    await store[Symbol.asyncDispose]();
    const indexPath = path.join(outputDir, ".evalens", "index.sqlite");
    await Promise.all(
      [indexPath, `${indexPath}-wal`, `${indexPath}-shm`].map((file) =>
        rm(file, { force: true })
      )
    );

    const local = await createLocalApi(outputDir);
    try {
      const response = await local.app.handle(
        new Request("http://localhost/api/experiments")
      );
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual([
        expect.objectContaining({
          name: "restored",
          description: "restored from objects",
          runCount: 1,
        }),
      ]);

      const database = new Database(path.join(outputDir, ".evalens", "index.sqlite"));
      database.run("DELETE FROM runs WHERE run_id = ?", [restoredRunId]);
      database.close();
      await Bun.write(
        path.join(outputDir, keyspace.runMarker("restored", restoredRunId)),
        JSON.stringify({
          formatVersion: 1,
          detectedAt: new Date(),
          reason: "test live repair",
          scope: {
            type: "run",
            experimentName: "restored",
            runId: restoredRunId,
          },
        })
      );

      const repaired = await local.app.handle(
        new Request("http://localhost/api/runs?experimentName=restored")
      );
      expect(repaired.status).toBe(200);
      expect(await repaired.json()).toMatchObject({
        total: 1,
        items: [expect.objectContaining({ id: restoredRunId })],
      });
    } finally {
      local.close();
      await rm(outputDir, { recursive: true, force: true });
    }
  });

  test("repairs a selected missing eval row without touching an unrelated running scope", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-local-server-"));
    const store = await createLocalStore({ outputDir });
    const runWriter = await store.createRun({
      experimentName: "selected",
      datasetName: "cases",
      datasetDigest: "dataset-digest",
      datasetSelectionDigest: "dataset-selection-digest",
      selectedItemIds: ["one"],
      targetItemCount: 1,
      tags: [],
      adapters: [],
      params: {},
      paramsDigest: await digestCanonicalJson({}),
    });
    await runWriter.commitItem(
      "one",
      { status: "completed", result: null, trajectories: [], timing },
      "item-digest"
    );
    await runWriter.finish();
    const evalWriter = await store.createEvaluation(
      store.openRun("selected", runWriter.runId),
      {
        evaluators: [{ name: "judge", version: "1" }],
        aggregatorVersion: "1",
        adapters: [],
        params: {},
        paramsDigest: await digestCanonicalJson({}),
      }
    );
    await evalWriter.commitItem("one", [
      {
        evaluator: "judge",
        evaluatorVersion: "1",
        status: "completed",
        score: { score: 1 },
        timing,
      },
    ]);
    await evalWriter.finish();
    const selectedEvalId = evalWriter.evalId;
    await store[Symbol.asyncDispose]();

    const indexPath = path.join(outputDir, ".evalens", "index.sqlite");
    const database = new Database(indexPath);
    database.query("DELETE FROM evals WHERE eval_id = ?").run(selectedEvalId);
    database.close();

    const unrelatedRunId = Bun.randomUUIDv7();
    await Bun.write(
      path.join(outputDir, keyspace.runManifest("unrelated", unrelatedRunId)),
      JSON.stringify({
        formatVersion: 2,
        runId: unrelatedRunId,
        experimentName: "unrelated",
        datasetName: "cases",
        datasetDigest: "other-dataset",
        datasetSelectionDigest: "other-selection",
        selectedItemIds: ["one"],
        targetItemCount: 1,
        status: "running",
        params: {},
        paramsDigest: "params",
        tags: [],
        adapters: [],
        createdAt: timing.startedAt,
      })
    );
    await Bun.write(
      path.join(outputDir, keyspace.runMarker("unrelated", unrelatedRunId)),
      JSON.stringify({
        formatVersion: 1,
        detectedAt: new Date(),
        reason: "unrelated running scope",
        scope: {
          type: "run",
          experimentName: "unrelated",
          runId: unrelatedRunId,
        },
      })
    );
    const selectedMarker = keyspace.evalMarker(
      "selected",
      runWriter.runId,
      selectedEvalId
    );
    await Bun.write(
      path.join(outputDir, selectedMarker),
      JSON.stringify({
        formatVersion: 1,
        detectedAt: new Date(),
        reason: "selected eval metadata row missing",
        scope: {
          type: "eval",
          experimentName: "selected",
          runId: runWriter.runId,
          evalId: selectedEvalId,
        },
      })
    );

    const local = await createLocalApi(outputDir);
    try {
      const response = await local.app.handle(
        request("/api/evaluations/compare", { evalIds: [selectedEvalId] })
      );
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        evaluations: [{ id: selectedEvalId, status: "finished" }],
      });
      expect(await Bun.file(path.join(outputDir, selectedMarker)).exists()).toBe(false);
      expect(
        await Bun.file(
          path.join(outputDir, keyspace.runMarker("unrelated", unrelatedRunId))
        ).exists()
      ).toBe(true);
    } finally {
      local.close();
      await rm(outputDir, { recursive: true, force: true });
    }
  });

  test("queries SQLite and serves downloads from the local result directory", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-local-server-"));
    await mkdir(path.join(outputDir, ".evalens"));
    const writer = SqliteMetadataWriter.open(
      path.join(outputDir, ".evalens", "index.sqlite")
    );
    writer.database.close();
    const local = await createLocalApi(outputDir);
    try {
      const experiments = await local.app.handle(
        new Request("http://localhost/api/experiments")
      );
      expect(experiments.status).toBe(200);
      expect(await experiments.json()).toEqual([]);

      await Bun.write(
        path.join(
          outputDir,
          keyspace.runItem("basic", runId, "item-1"),
          "run.log.jsonl"
        ),
        "local log\n"
      );
      const download = await local.app.handle(
        new Request(
          `http://localhost/api/results/downloads/experiments/basic/runs/${runId}/items/item-1/log`
        )
      );
      expect(download.status).toBe(200);
      expect(download.headers.get("content-type")).toBe("application/x-ndjson");
      expect(await download.text()).toBe("local log\n");
    } finally {
      local.close();
      await rm(outputDir, { recursive: true, force: true });
    }
  });

  test("serves API first and delegates arbitrary frontend routes to Vite", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-local-server-"));
    await mkdir(path.join(outputDir, ".evalens"));
    const writer = SqliteMetadataWriter.open(
      path.join(outputDir, ".evalens", "index.sqlite")
    );
    writer.database.close();
    await using server = await serveLocal({
      outputDir,
      port: 0,
      hmrPort: false,
    });
    try {
      const api = await fetch(new URL("/api/experiments", server.url));
      expect(api.status).toBe(200);
      expect(await api.json()).toEqual([]);

      const route = await fetch(new URL("/arbitrary/deep/path", server.url));
      expect(route.status).toBe(200);
      expect(await route.text()).toContain('<div id="root"></div>');

      const module = await fetch(new URL("/src/main.tsx", server.url));
      expect(module.status).toBe(200);
      expect(module.headers.get("content-type")).toContain("javascript");
      expect(await module.text()).toContain("react_jsx-dev-runtime");
    } finally {
      await rm(outputDir, { recursive: true, force: true });
    }
  }, 15_000);
});

describe("Vite Connect adapter", () => {
  test("rejects middleware errors without returning an empty 200", async () => {
    const handler = connectToFetch((_request, _response, next) => {
      next(new Error("vite failed"));
    });

    await expect(handler(new Request("http://localhost/broken"))).rejects.toThrow(
      "vite failed"
    );
  });
});

describe("GitHub experiment dispatch", () => {
  test("rejects filter item ids containing control characters", async () => {
    const api = createApi({
      resultStore: resultStore(),
      queryService: emptyQueryService(),
      dispatcher: {
        listExperiments: () => [{ name: "basic", module: "examples/basic.exp.ts" }],
        trigger: async (experimentName) => ({
          accepted: true,
          experimentName,
          workflow: "evalens-experiment.yml",
          ref: "main",
        }),
      },
    });

    for (const id of ["case\0", "case\n", "case\ud800"]) {
      const response = await api.handle(
        request("/api/experiments/basic/runs", { filter: [id] })
      );
      expect(response.status).toBe(422);
    }

    const empty = await api.handle(
      request("/api/experiments/basic/runs", { filter: [] })
    );
    expect(empty.status).toBe(422);
  });

  test("transports filters and params in one lossless JSON input", async () => {
    let dispatched: unknown;
    const dispatcher = new GitHubDispatcher({
      token: "token",
      owner: "AFK-surf",
      repo: "Comma",
      ref: "main",
      experiments: [{ name: "basic", module: "examples/basic.exp.ts" }],
      fetch: Object.assign(
        async (_input: string | URL | Request, init?: RequestInit) => {
          dispatched = JSON.parse(String(init?.body));
          return new Response(null, { status: 204 });
        },
        { preconnect(_url: string | URL) {} }
      ),
    });

    await dispatcher.trigger("basic", {
      filter: ["case-a", "case-b"],
      runParams: { model: "a,b" },
      evalParams: { strict: true },
    });

    expect(dispatched).toEqual({
      ref: "main",
      inputs: {
        experiment_name: "basic",
        experiment_module: "examples/basic.exp.ts",
        request: JSON.stringify({
          filter: ["case-a", "case-b"],
          run: { model: "a,b" },
          eval: { strict: true },
        }),
      },
    });
  });

  test("does not turn an omitted workflow filter into an empty selection", async () => {
    let dispatched: unknown;
    const dispatcher = new GitHubDispatcher({
      token: "token",
      owner: "AFK-surf",
      repo: "Comma",
      ref: "main",
      experiments: [{ name: "basic", module: "examples/basic.exp.ts" }],
      fetch: Object.assign(
        async (_input: string | URL | Request, init?: RequestInit) => {
          dispatched = JSON.parse(String(init?.body));
          return new Response(null, { status: 204 });
        },
        { preconnect(_url: string | URL) {} }
      ),
    });

    await dispatcher.trigger("basic", {
      runParams: {},
      evalParams: {},
    });

    expect(dispatched).toEqual({
      ref: "main",
      inputs: {
        experiment_name: "basic",
        experiment_module: "examples/basic.exp.ts",
        request: JSON.stringify({ run: {}, eval: {} }),
      },
    });
  });
});

describe("D1 metadata and query services", () => {
  test("projects a completed run and evaluation into dashboard DTOs", async () => {
    const database = await metadataDatabase();
    const d1 = localD1(database, 100);
    const writer = new D1MetadataWriter(d1);
    const query = new D1QueryService(d1);

    await writer.upsertRunManifest({
      formatVersion: 2,
      runId,
      experimentName: "basic",
      description: "Basic experiment",
      datasetName: "basic-dataset",
      datasetDigest: "dataset-digest",
      datasetSelectionDigest: "dataset-selection-digest",
      selectedItemIds: ["one"],
      targetItemCount: 1,
      status: "finished",
      params: { model: "deterministic" },
      paramsDigest: "run-params",
      tags: ["example"],
      adapters: [{ name: "salix", version: "1" }],
      createdAt: timing.startedAt,
      finishedAt: timing.finishedAt,
    });
    await writer.commitRunItem({
      runId,
      itemId: "one",
      itemDigest: "item-digest",
      status: "completed",
      timing,
    });
    await writer.upsertEvalManifest({
      formatVersion: 1,
      evalId,
      runId,
      status: "finished",
      params: { judge: "exact" },
      paramsDigest: "eval-params",
      aggregatorVersion: "1",
      evaluators: [{ name: "exact-match", version: "1" }],
      adapters: [{ name: "codex", version: "1" }],
      createdAt: timing.startedAt,
      finishedAt: timing.finishedAt,
    });
    await writer.commitEvalItem({
      evalId,
      runId,
      itemId: "one",
      results: [
        {
          evaluatorName: "exact-match",
          status: "completed",
          score: { exactMatch: 1 },
          explanation: "matched",
          timing,
        },
      ],
    });
    await writer.replaceAggregateScores({
      evalId,
      scores: { exactMatch: 1 },
    });
    await writer.upsertEvalManifest({
      formatVersion: 1,
      evalId: comparisonEvalId,
      runId,
      status: "finished",
      params: { judge: "exact" },
      paramsDigest: "eval-params-2",
      aggregatorVersion: "1",
      evaluators: [{ name: "exact-match", version: "1" }],
      adapters: [],
      createdAt: laterTiming.startedAt,
      finishedAt: laterTiming.finishedAt,
    });
    await writer.commitEvalItem({
      evalId: comparisonEvalId,
      runId,
      itemId: "one",
      results: [
        {
          evaluatorName: "exact-match",
          status: "completed",
          score: { exactMatch: 0 },
          timing: laterTiming,
        },
      ],
    });

    expect(await query.getState()).toBe("ready");
    expect(await query.listExperiments()).toEqual([
      {
        name: "basic",
        description: "Basic experiment",
        runCount: 1,
        latestRunAt: timing.startedAt.toISOString(),
      },
    ]);
    const run = await query.getRun(runId);
    expect(run?.targetItemCount).toBe(1);
    expect(run?.updatedAt).toBe(laterTiming.finishedAt.toISOString());
    expect(run?.tags).toEqual(["example"]);
    expect(run?.adapters).toEqual([{ name: "salix", version: "1" }]);
    expect(run?.itemCounts).toEqual({ completed: 1, error: 0 });
    const primaryEvaluation = await query.getEvaluation(evalId);
    expect(primaryEvaluation?.aggregateScores).toEqual({ exactMatch: 1 });
    expect(primaryEvaluation?.adapters).toEqual([{ name: "codex", version: "1" }]);
    expect(primaryEvaluation?.scoreIdentities).toEqual([
      {
        evaluatorName: "exact-match",
        evaluatorVersion: "1",
        scoreKey: "exactMatch",
      },
    ]);
    const runItems = await query.listRunItems(runId, evalId, 1, 50);
    expect(runItems.items[0]?.evaluatorResults[0]).toMatchObject({
      evaluatorName: "exact-match",
      status: "completed",
      scores: { exactMatch: 1 },
      message: "matched",
    });
    await expect(query.listRunItems(runId, "missing-eval")).rejects.toThrow(
      "does not belong to run"
    );

    const runs = await query.listRuns({
      page: 1,
      pageSize: 1_000,
      tag: "example",
      params: { model: "deterministic" },
      createdAfter: "2026-07-10T00:00:00.000Z",
    });
    expect(runs).toMatchObject({
      page: 1,
      pageSize: 100,
      total: 1,
      items: [
        {
          id: runId,
          latestFinishedEvaluation: { id: comparisonEvalId },
        },
      ],
    });
    const evaluations = await query.listEvaluations({
      runId,
      status: "finished",
      tag: "example",
      runParams: { model: "deterministic" },
      evalParams: { judge: "exact" },
    });
    expect(evaluations.total).toBe(2);
    expect(evaluations.items.map(({ id }) => id)).toContain(evalId);
    expect(await query.compareEvaluations([evalId], 1, 500)).toMatchObject({
      sharedItemCount: 1,
      itemPage: 1,
      itemPageSize: 200,
      evaluations: [{ id: evalId, items: [{ id: "one" }] }],
    });
    const comparison = await query.compareEvaluations(
      [evalId, comparisonEvalId],
      1,
      500,
      evalId
    );
    expect(comparison.itemMetrics).toEqual([
      {
        evaluatorName: "exact-match",
        evaluatorVersion: "1",
        scoreKey: "exactMatch",
      },
    ]);
    await expect(query.compareEvaluations(["missing"])).rejects.toThrow(
      "evaluations not found"
    );
    await writer.upsertEvalManifest({
      formatVersion: 1,
      evalId: runningEvalId,
      runId,
      status: "running",
      params: {},
      paramsDigest: "running-params",
      aggregatorVersion: "1",
      evaluators: [{ name: "exact-match", version: "1" }],
      adapters: [],
      createdAt: timing.startedAt,
    });
    await expect(query.compareEvaluations([runningEvalId])).rejects.toThrow(
      "evaluations are not finished"
    );

    const manyScores = Object.fromEntries(
      Array.from({ length: 40 }, (_, index) => [`metric-${index}`, index])
    );
    await writer.commitEvalItem({
      evalId,
      runId,
      itemId: "one",
      results: [
        {
          evaluatorName: "exact-match",
          status: "completed",
          score: manyScores,
          timing,
        },
      ],
    });
    await writer.replaceAggregateScores({ evalId, scores: manyScores });
    expect(
      database
        .query("SELECT count(*) AS count FROM eval_scores WHERE eval_id = ?")
        .get(evalId)
    ).toEqual({ count: 40 });
    expect(
      database
        .query("SELECT count(*) AS count FROM aggregate_scores WHERE eval_id = ?")
        .get(evalId)
    ).toEqual({ count: 40 });

    const runningManifest = {
      formatVersion: 2 as const,
      runId: "019a1f26-9a7b-7000-8000-000000000100",
      experimentName: "repair-race",
      datasetName: "basic-dataset",
      datasetDigest: "dataset-digest",
      datasetSelectionDigest: "dataset-selection-digest",
      selectedItemIds: ["one"],
      targetItemCount: 1,
      status: "running" as const,
      params: {},
      paramsDigest: "repair-race-params",
      tags: [],
      adapters: [],
      createdAt: timing.startedAt,
    };
    const finishedManifest = {
      ...runningManifest,
      status: "finished" as const,
      finishedAt: timing.finishedAt,
    };
    await writer.upsertRunManifest(runningManifest);
    const staleRepair = await writer.beginReindex({ type: "all" });
    await writer.upsertRunManifest(finishedManifest);
    await expect(
      writer.upsertRunManifest(runningManifest, { repair: staleRepair })
    ).rejects.toBeInstanceOf(MetadataRepairLeaseLostError);
    expect(await writer.finishReindex(staleRepair)).toBe(false);

    const replay = await writer.beginReindex({ type: "all" });
    await writer.upsertRunManifest(finishedManifest, { repair: replay });
    expect(await writer.finishReindex(replay)).toBe(true);
    expect(
      database
        .query("SELECT status, finished_at FROM runs WHERE run_id = ?")
        .get(runningManifest.runId)
    ).toEqual({
      status: "finished",
      finished_at: timing.finishedAt.getTime(),
    });

    const supersededRepair = await writer.beginReindex({ type: "all" });
    const currentRepair = await writer.beginReindex({ type: "all" });
    await writer.upsertRunManifest(finishedManifest, { repair: currentRepair });
    expect(await writer.finishReindex(currentRepair)).toBe(true);
    await expect(
      writer.upsertRunManifest(runningManifest, { repair: supersededRepair })
    ).rejects.toBeInstanceOf(MetadataRepairLeaseLostError);
    expect(
      database
        .query("SELECT status, finished_at FROM runs WHERE run_id = ?")
        .get(runningManifest.runId)
    ).toEqual({
      status: "finished",
      finished_at: timing.finishedAt.getTime(),
    });

    const parentRepair = await writer.beginReindex({ type: "all" });
    const childRepair = await writer.beginReindex({
      type: "run",
      experimentName: runningManifest.experimentName,
      runId: runningManifest.runId,
    });
    await expect(
      writer.upsertRunManifest(runningManifest, { repair: parentRepair })
    ).rejects.toBeInstanceOf(MetadataRepairLeaseLostError);
    await writer.upsertRunManifest(finishedManifest, { repair: childRepair });
    expect(await writer.finishReindex(childRepair)).toBe(true);
    expect(await writer.finishReindex(parentRepair)).toBe(false);
  });

  test("compares 200 shared items without exceeding D1 binding limits", async () => {
    const database = await metadataDatabase();
    const d1 = localD1(database, 100);
    const writer = new D1MetadataWriter(d1);
    const query = new D1QueryService(d1);
    const leftRunId = Bun.randomUUIDv7();
    const rightRunId = Bun.randomUUIDv7();
    const leftEvalId = Bun.randomUUIDv7();
    const rightEvalId = Bun.randomUUIDv7();

    for (const [currentRunId, currentEvalId] of [
      [leftRunId, leftEvalId],
      [rightRunId, rightEvalId],
    ] as const) {
      await writer.upsertRunManifest({
        formatVersion: 2,
        runId: currentRunId,
        experimentName: "large-comparison",
        datasetName: "large-dataset",
        datasetDigest: "dataset-digest",
        datasetSelectionDigest: "selection-digest",
        selectedItemIds: Array.from(
          { length: 200 },
          (_, index) => `item-${index.toString().padStart(3, "0")}`
        ),
        targetItemCount: 200,
        status: "finished",
        params: {},
        paramsDigest: "run-params",
        tags: [],
        adapters: [],
        createdAt: timing.startedAt,
        finishedAt: timing.finishedAt,
      });
      await writer.upsertEvalManifest({
        formatVersion: 1,
        evalId: currentEvalId,
        runId: currentRunId,
        status: "finished",
        params: {},
        paramsDigest: "eval-params",
        aggregatorVersion: "1",
        evaluators: [{ name: "exact-match", version: "1" }],
        adapters: [],
        createdAt: timing.startedAt,
        finishedAt: timing.finishedAt,
      });
    }

    database.transaction(() => {
      const insertRunItem = database.prepare(
        `INSERT INTO run_items (
          run_id, item_id, item_digest, status, error,
          started_at, finished_at, duration_ms
        ) VALUES (?, ?, ?, 'completed', NULL, ?, ?, ?)`
      );
      const insertResult = database.prepare(
        `INSERT INTO evaluator_results (
          eval_id, run_id, item_id, evaluator_name, status, message,
          started_at, finished_at, duration_ms
        ) VALUES (?, ?, ?, 'exact-match', 'completed', NULL, ?, ?, ?)`
      );
      const insertScore = database.prepare(
        `INSERT INTO eval_scores (
          eval_id, item_id, evaluator_name, score_key, score_value
        ) VALUES (?, ?, 'exact-match', 'exactMatch', ?)`
      );
      const insertIdentity = database.prepare(
        `INSERT INTO eval_score_identities (
          eval_id, evaluator_name, evaluator_version, score_key
        ) VALUES (?, 'exact-match', '1', 'exactMatch')`
      );
      for (const currentEvalId of [leftEvalId, rightEvalId]) {
        insertIdentity.run(currentEvalId);
      }
      for (let index = 0; index < 200; index += 1) {
        const itemId = `item-${index.toString().padStart(3, "0")}`;
        for (const [currentRunId, currentEvalId] of [
          [leftRunId, leftEvalId],
          [rightRunId, rightEvalId],
        ] as const) {
          insertRunItem.run(
            currentRunId,
            itemId,
            `digest-${itemId}`,
            timing.startedAt.getTime(),
            timing.finishedAt.getTime(),
            timing.durationMs
          );
          insertResult.run(
            currentEvalId,
            currentRunId,
            itemId,
            timing.startedAt.getTime(),
            timing.finishedAt.getTime(),
            timing.durationMs
          );
          insertScore.run(currentEvalId, itemId, index);
        }
      }
    })();

    const comparison = await query.compareEvaluations(
      [leftEvalId, rightEvalId],
      1,
      200
    );
    expect(
      comparison.evaluations.map(({ id, items }) => ({
        id,
        itemCount: items.length,
      }))
    ).toEqual([
      { id: leftEvalId, itemCount: 200 },
      { id: rightEvalId, itemCount: 200 },
    ]);
    expect(comparison.evaluations[0]?.items.at(-1)?.id).toBe("item-199");
    expect(comparison).toMatchObject({
      sharedItemCount: 200,
      itemPage: 1,
      itemPageSize: 200,
      evaluations: [{ id: leftEvalId }, { id: rightEvalId }],
      itemMetrics: [
        {
          evaluatorName: "exact-match",
          evaluatorVersion: "1",
          scoreKey: "exactMatch",
        },
      ],
    });
  });
});

function request(path: string, body: unknown): Request {
  return new Request(`http://localhost${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function resultStore(
  overrides: Partial<ResultDownloadStore> = {}
): ResultDownloadStore {
  return {
    readRunArtifact: overrides.readRunArtifact ?? (async () => null),
    readRunArtifactMetadata: overrides.readRunArtifactMetadata ?? (async () => null),
    readRunLog: overrides.readRunLog ?? (async () => null),
    readEvalLog: overrides.readEvalLog ?? (async () => null),
    readRunResult: overrides.readRunResult ?? (async () => null),
    readTrajectories: overrides.readTrajectories ?? (async () => null),
    readEvalResults: overrides.readEvalResults ?? (async () => null),
  };
}

function metadataWriter(overrides: Partial<MetadataWriter> = {}): MetadataWriter {
  return {
    upsertRunManifest: overrides.upsertRunManifest ?? resolvedResult,
    commitRunItem: overrides.commitRunItem ?? resolvedResult,
    upsertEvalManifest: overrides.upsertEvalManifest ?? resolvedResult,
    commitEvalItem: overrides.commitEvalItem ?? resolvedResult,
    replaceAggregateScores: overrides.replaceAggregateScores ?? resolvedResult,
  };
}

function resolvedResult(): Promise<void> {
  return Promise.resolve();
}

function r2Object(value: string, contentType: string): R2ObjectBody {
  const bytes = new TextEncoder().encode(value);
  return {
    key: "key",
    version: "1",
    size: bytes.byteLength,
    etag: "etag",
    httpEtag: '"etag"',
    checksums: { toJSON: () => ({}) },
    uploaded: new Date(),
    storageClass: "Standard",
    body: new Blob([bytes]).stream(),
    bodyUsed: false,
    writeHttpMetadata(headers) {
      headers.set("content-type", contentType);
    },
    arrayBuffer: async () => bytes.buffer.slice(0),
    bytes: async () => bytes,
    text: async () => value,
    json: async () => {
      throw new Error("not implemented in download test");
    },
    blob: async () => new Blob([bytes], { type: contentType }),
  };
}

function emptyQueryService(): QueryService {
  return {
    getState: async () => "ready",
    listExperiments: async () => [],
    listRuns: async () => ({ items: [], page: 1, pageSize: 25, total: 0 }),
    getRun: async () => null,
    listEvaluations: async () => ({ items: [], page: 1, pageSize: 25, total: 0 }),
    getEvaluation: async () => null,
    listRunItems: async () => ({ items: [], page: 1, pageSize: 50, total: 0 }),
    compareEvaluations: async () => ({
      evaluations: [],
      sharedItemCount: 0,
      itemPage: 1,
      itemPageSize: 100,
      itemMetrics: [],
    }),
  };
}

function localD1(
  database: Database,
  maxBindings = Number.POSITIVE_INFINITY
): D1Database {
  const prepare = (sql: string) => {
    const assertBindingLimit = (bindings: SQLQueryBindings[]) => {
      if (bindings.length > maxBindings) {
        throw new Error(`too many SQL variables: ${bindings.length}`);
      }
    };
    const create = (bindings: SQLQueryBindings[] = []) => ({
      bind: (...values: SQLQueryBindings[]) => create(values),
      async all<T>() {
        assertBindingLimit(bindings);
        const results = database.query(sql).all(...bindings) as T[];
        return { success: true, results, meta: {} };
      },
      async first<T>() {
        assertBindingLimit(bindings);
        return (database.query(sql).get(...bindings) as T | null) ?? null;
      },
      async raw<T extends unknown[]>() {
        assertBindingLimit(bindings);
        return database.query(sql).values(...bindings) as T[];
      },
      async run() {
        assertBindingLimit(bindings);
        const result = database.query(sql).run(...bindings);
        return { success: true, results: [], meta: { changes: result.changes } };
      },
      execute() {
        assertBindingLimit(bindings);
        const result = database.query(sql).run(...bindings);
        return { success: true, results: [], meta: { changes: result.changes } };
      },
    });
    return create();
  };
  return {
    prepare,
    async batch(statements: Array<{ execute(): unknown }>) {
      return database.transaction(() =>
        statements.map((statement) => statement.execute())
      )();
    },
  } as unknown as D1Database;
}

async function metadataDatabase(): Promise<Database> {
  const database = new Database(":memory:");
  database.run("PRAGMA foreign_keys = ON");
  const migrationsDirectory = new URL(
    "../../store/src/metadata/migrations/",
    import.meta.url
  );
  const migrationNames = (await readdir(migrationsDirectory))
    .filter((name) => name.endsWith(".sql"))
    .sort();
  for (const name of migrationNames) {
    const migration = await Bun.file(new URL(name, migrationsDirectory)).text();
    for (const statement of migration.split("--> statement-breakpoint")) {
      if (statement.trim()) database.run(statement);
    }
  }
  return database;
}

function deferred<T>() {
  return Promise.withResolvers<T>();
}

async function waitForCondition(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Bun.sleep(1);
  }
  throw new Error("condition was not met");
}
