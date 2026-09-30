import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { getTableColumns, getTableName } from "drizzle-orm";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type {
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  RunItemCommitMetadata,
} from "@evalens/store/metadata/contracts";
import {
  NoopMetadataWriter,
  RunManifestMetadata,
} from "@evalens/store/metadata/contracts";
import * as metadataSchema from "@evalens/store/metadata/schema";
import { METADATA_SCHEMA_VERSION } from "@evalens/store/metadata/version";
import { SqliteMetadataWriter } from "@evalens/store/local";

const startedAt = new Date("2026-01-02T03:04:05.000Z");
const finishedAt = new Date("2026-01-02T03:04:05.025Z");
const timing = { startedAt, finishedAt, durationMs: 25 };

let database: Database;
let writer: SqliteMetadataWriter;
let runId: string;
let evalId: string;

beforeEach(() => {
  database = new Database(":memory:");
  writer = new SqliteMetadataWriter(database);
  runId = Bun.randomUUIDv7();
  evalId = Bun.randomUUIDv7();
});

afterEach(() => {
  database.close();
});

function createRunManifest(): RunManifestMetadata {
  return {
    formatVersion: 2,
    runId,
    experimentName: "metadata-test",
    description: "metadata integration test",
    datasetName: "cases",
    datasetDigest: "dataset-digest",
    datasetSelectionDigest: "dataset-selection-digest",
    selectedItemIds: ["item-completed", "item-error"],
    targetItemCount: 2,
    status: "finished",
    params: {
      array: ["one"],
      boolean: true,
      null: null,
      number: 0.25,
      text: "model-a",
    },
    paramsDigest: "run-params-digest",
    tags: ["Test", "test"],
    adapters: [{ name: "salix", version: "1" }],
    createdAt: startedAt,
    finishedAt,
  };
}

test("run metadata requires a positive target item count", () => {
  expect(
    RunManifestMetadata.safeParse({
      ...createRunManifest(),
      targetItemCount: 0,
    }).success
  ).toBe(false);
});

test("run metadata requires selected item ids to match the target count", () => {
  expect(
    RunManifestMetadata.safeParse({
      ...createRunManifest(),
      selectedItemIds: ["item-completed"],
    }).success
  ).toBe(false);
});

function createCompletedRunItem(): RunItemCommitMetadata {
  return {
    runId,
    itemId: "item-completed",
    itemDigest: "item-completed-digest",
    status: "completed",
    timing,
  };
}

function createErrorRunItem(error: string): RunItemCommitMetadata {
  return {
    runId,
    itemId: "item-error",
    itemDigest: "item-error-digest",
    status: "error",
    error,
    timing,
  };
}

function createEvalManifest(): EvalManifestMetadata {
  return {
    formatVersion: 1,
    evalId,
    runId,
    status: "finished",
    params: { judge: "model-b", temperature: 0 },
    paramsDigest: "eval-params-digest",
    aggregatorVersion: "aggregate-v1",
    evaluators: [
      { name: "quality", version: "v1" },
      { name: "broken", version: "v2" },
      { name: "skipped", version: "v3" },
    ],
    adapters: [{ name: "codex", version: "1" }],
    createdAt: startedAt,
    finishedAt,
  };
}

function createEvalItem(
  explanation = "good",
  error = "failed",
  reason = "upstream failed"
): EvalItemCommitMetadata {
  return {
    evalId,
    runId,
    itemId: "item-completed",
    results: [
      {
        evaluatorName: "quality",
        status: "completed",
        score: { accuracy: 1, confidence: 0.75 },
        explanation,
        timing,
      },
      {
        evaluatorName: "broken",
        status: "error",
        error,
        timing,
      },
      {
        evaluatorName: "skipped",
        status: "skipped",
        reason,
      },
    ],
  };
}

async function writeParents(): Promise<void> {
  await writer.upsertRunManifest(createRunManifest());
  await writer.commitRunItem(createCompletedRunItem());
  await writer.upsertEvalManifest(createEvalManifest());
}

function count(table: string): number {
  const row = database.query(`SELECT COUNT(*) AS count FROM ${table}`).get() as {
    count: number;
  };
  return row.count;
}

describe("SQLite metadata writer", () => {
  test("configures file databases for concurrent readers", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-sqlite-"));
    const fileDatabase = new Database(path.join(directory, "index.sqlite"), {
      create: true,
    });
    try {
      new SqliteMetadataWriter(fileDatabase);
      expect(fileDatabase.query("PRAGMA journal_mode").get()).toEqual({
        journal_mode: "wal",
      });
      expect(fileDatabase.query("PRAGMA busy_timeout").get()).toEqual({
        timeout: 5000,
      });
      expect(fileDatabase.query("PRAGMA foreign_keys").get()).toEqual({
        foreign_keys: 1,
      });
    } finally {
      fileDatabase.close();
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("marks an older migrated index for rebuilding", () => {
    const olderDatabase = new Database(":memory:");
    new SqliteMetadataWriter(olderDatabase);
    olderDatabase.run(
      "UPDATE index_metadata SET schema_version = 0, state = 'ready' WHERE id = 1"
    );

    new SqliteMetadataWriter(olderDatabase);

    expect(
      olderDatabase.query("SELECT schema_version, state FROM index_metadata").get()
    ).toEqual({ schema_version: METADATA_SCHEMA_VERSION, state: "rebuilding" });
    olderDatabase.close();
  });

  test("rejects an index created by a newer schema", () => {
    const futureDatabase = new Database(":memory:");
    new SqliteMetadataWriter(futureDatabase);
    const futureVersion = METADATA_SCHEMA_VERSION + 1;
    futureDatabase
      .query("UPDATE index_metadata SET schema_version = ? WHERE id = 1")
      .run(futureVersion);

    expect(() => new SqliteMetadataWriter(futureDatabase)).toThrow(
      `unsupported metadata schema version: ${futureVersion}`
    );
    futureDatabase.close();
  });

  test("initializes a missing index as rebuilding with migration columns in sync", () => {
    expect(
      database.query("SELECT schema_version, state FROM index_metadata").get()
    ).toEqual({ schema_version: METADATA_SCHEMA_VERSION, state: "rebuilding" });

    for (const table of [
      metadataSchema.runs,
      metadataSchema.runTags,
      metadataSchema.runAdapters,
      metadataSchema.runParams,
      metadataSchema.runItems,
      metadataSchema.evals,
      metadataSchema.evalParams,
      metadataSchema.evalAdapters,
      metadataSchema.evalEvaluators,
      metadataSchema.evaluatorResults,
      metadataSchema.evalScores,
      metadataSchema.evalScoreIdentities,
      metadataSchema.aggregateScores,
      metadataSchema.indexMetadata,
      metadataSchema.reindexFences,
    ]) {
      const expectedColumns = Object.values(getTableColumns(table))
        .map((column) => column.name)
        .sort();
      const actualColumns = (
        database.query(`PRAGMA table_info(${getTableName(table)})`).all() as Array<{
          name: string;
        }>
      )
        .map((column) => column.name)
        .sort();
      expect(actualColumns).toEqual(expectedColumns);
    }
  });

  test("writes the full hierarchy idempotently with scalar projections and scores", async () => {
    const longExplanation = "🙂".repeat(600);
    const longError = "错".repeat(1000);
    const longReason = "略".repeat(1000);
    const runManifest = createRunManifest();
    const completedRunItem = createCompletedRunItem();
    const errorRunItem = createErrorRunItem(longError);
    const evalManifest = createEvalManifest();
    const evalItem = createEvalItem(longExplanation, longError, longReason);

    for (let attempt = 0; attempt < 2; attempt += 1) {
      await writer.upsertRunManifest(runManifest);
      await writer.commitRunItem(completedRunItem);
      await writer.commitRunItem(errorRunItem);
      await writer.upsertEvalManifest(evalManifest);
      await writer.commitEvalItem(evalItem);
      await writer.replaceAggregateScores({
        evalId,
        scores: { count: 1, mean: 0.875 },
      });
    }

    expect(count("runs")).toBe(1);
    expect(count("run_tags")).toBe(2);
    expect(count("run_adapters")).toBe(1);
    expect(count("run_params")).toBe(5);
    expect(count("run_items")).toBe(2);
    expect(count("evals")).toBe(1);
    expect(count("eval_params")).toBe(2);
    expect(count("eval_adapters")).toBe(1);
    expect(count("eval_evaluators")).toBe(3);
    expect(count("evaluator_results")).toBe(3);
    expect(count("eval_scores")).toBe(2);
    expect(count("eval_score_identities")).toBe(2);
    expect(count("aggregate_scores")).toBe(2);
    expect(
      database.query("SELECT target_item_count FROM runs WHERE run_id = ?").get(runId)
    ).toEqual({ target_item_count: 2 });

    const params = database
      .query(
        `SELECT key, value_type, value_json, text_value, number_value, boolean_value
         FROM run_params ORDER BY key`
      )
      .all() as Array<Record<string, unknown>>;
    expect(params).toContainEqual({
      key: "text",
      value_type: "string",
      value_json: '"model-a"',
      text_value: "model-a",
      number_value: null,
      boolean_value: null,
    });
    expect(params).toContainEqual({
      key: "number",
      value_type: "number",
      value_json: "0.25",
      text_value: null,
      number_value: 0.25,
      boolean_value: null,
    });
    expect(params).toContainEqual({
      key: "boolean",
      value_type: "boolean",
      value_json: "true",
      text_value: null,
      number_value: null,
      boolean_value: 1,
    });
    const scores = database
      .query(
        `SELECT evaluator_name, score_key, score_value
         FROM eval_scores ORDER BY evaluator_name, score_key`
      )
      .all();
    expect(scores).toEqual([
      { evaluator_name: "quality", score_key: "accuracy", score_value: 1 },
      { evaluator_name: "quality", score_key: "confidence", score_value: 0.75 },
    ]);
    expect(
      database
        .query(
          `SELECT evaluator_name, evaluator_version, score_key
           FROM eval_score_identities ORDER BY evaluator_name, score_key`
        )
        .all()
    ).toEqual([
      {
        evaluator_name: "quality",
        evaluator_version: "v1",
        score_key: "accuracy",
      },
      {
        evaluator_name: "quality",
        evaluator_version: "v1",
        score_key: "confidence",
      },
    ]);

    const scorelessStatuses = database
      .query(
        `SELECT status FROM evaluator_results
         WHERE evaluator_name NOT IN (SELECT DISTINCT evaluator_name FROM eval_scores)
         ORDER BY status`
      )
      .all();
    expect(scorelessStatuses).toEqual([{ status: "error" }, { status: "skipped" }]);

    const summaries = database
      .query(
        `SELECT evaluator_name, status, message
         FROM evaluator_results ORDER BY evaluator_name`
      )
      .all() as Array<{
      evaluator_name: string;
      status: "completed" | "error" | "skipped";
      message: string | null;
    }>;
    for (const summary of summaries) {
      if (summary.message !== null) {
        expect(new TextEncoder().encode(summary.message).length).toBeLessThanOrEqual(
          2048
        );
        expect(summary.message).not.toContain("�");
      }
    }
    expect(summaries).toEqual([
      {
        evaluator_name: "broken",
        status: "error",
        message: "错".repeat(682),
      },
      {
        evaluator_name: "quality",
        status: "completed",
        message: "🙂".repeat(512),
      },
      {
        evaluator_name: "skipped",
        status: "skipped",
        message: "略".repeat(682),
      },
    ]);
    const runError = database
      .query("SELECT error FROM run_items WHERE item_id = 'item-error'")
      .get() as { error: string };
    expect(new TextEncoder().encode(runError.error).length).toBeLessThanOrEqual(2048);
    expect(runError.error).not.toContain("�");

    await writer.replaceAggregateScores({ evalId, scores: { replacement: 3 } });
    expect(
      database.query("SELECT score_key, score_value FROM aggregate_scores").all()
    ).toEqual([{ score_key: "replacement", score_value: 3 }]);
    await writer.replaceAggregateScores({ evalId, scores: {} });
    expect(count("aggregate_scores")).toBe(0);
  });

  test("requires the exact evaluator set before replacing rows and cascades", async () => {
    await writeParents();
    await writer.commitEvalItem(createEvalItem());

    const incompleteItem: EvalItemCommitMetadata = {
      ...createEvalItem(),
      results: createEvalItem().results.slice(0, 2),
    };
    const extraItem: EvalItemCommitMetadata = {
      ...createEvalItem(),
      results: [
        ...createEvalItem().results,
        {
          evaluatorName: "not-configured",
          status: "completed",
          score: { quality: 1 },
          timing,
        },
      ],
    };
    for (const invalidItem of [incompleteItem, extraItem]) {
      await expect(writer.commitEvalItem(invalidItem)).rejects.toThrow(
        "must exactly match"
      );
      expect(count("evaluator_results")).toBe(3);
      expect(count("eval_scores")).toBe(2);
    }

    await expect(
      writer.commitRunItem({
        runId: Bun.randomUUIDv7(),
        itemId: "orphan",
        itemDigest: "orphan-digest",
        status: "completed",
        timing,
      })
    ).rejects.toThrow("FOREIGN KEY constraint failed");

    await writer.replaceAggregateScores({ evalId, scores: { mean: 1 } });
    expect(
      (database.query("PRAGMA foreign_keys").get() as { foreign_keys: number })
        .foreign_keys
    ).toBe(1);

    database.query("DELETE FROM runs WHERE run_id = ?").run(runId);
    for (const table of [
      "run_tags",
      "run_params",
      "run_items",
      "evals",
      "eval_params",
      "eval_evaluators",
      "evaluator_results",
      "eval_scores",
      "aggregate_scores",
    ]) {
      expect(count(table)).toBe(0);
    }
  });

  test("removes a projected score identity only after its final emitting item changes", async () => {
    await writeParents();
    const first = createEvalItem();
    await writer.commitEvalItem(first);
    await writer.commitRunItem({
      ...createCompletedRunItem(),
      itemId: "item-second",
      itemDigest: "item-second-digest",
    });
    await writer.commitEvalItem({ ...first, itemId: "item-second" });

    const replacement = {
      ...first,
      results: first.results.map((result) =>
        result.status === "completed"
          ? { ...result, score: { replacement: 1 } }
          : result
      ),
    };
    await writer.commitEvalItem(replacement);
    expect(
      database
        .query("SELECT score_key FROM eval_score_identities ORDER BY score_key")
        .all()
    ).toEqual([
      { score_key: "accuracy" },
      { score_key: "confidence" },
      { score_key: "replacement" },
    ]);

    await writer.commitEvalItem({ ...replacement, itemId: "item-second" });
    expect(
      database
        .query("SELECT score_key FROM eval_score_identities ORDER BY score_key")
        .all()
    ).toEqual([{ score_key: "replacement" }]);
  });

  test("rejects an eval item for an unknown parent without deleting data", async () => {
    await writeParents();
    await expect(
      writer.commitEvalItem({
        evalId,
        runId: Bun.randomUUIDv7(),
        itemId: "item-completed",
        results: createEvalItem().results,
      })
    ).rejects.toThrow("FOREIGN KEY constraint failed");
    expect(count("evaluator_results")).toBe(0);
    expect(count("eval_scores")).toBe(0);
  });

  test("runtime schemas reject invalid keys and non-finite scores", async () => {
    await writeParents();

    await expect(
      writer.replaceAggregateScores({
        evalId,
        scores: { invalid: Number.POSITIVE_INFINITY },
      })
    ).rejects.toThrow();
    await expect(
      writer.replaceAggregateScores({ evalId, scores: { "": 1 } })
    ).rejects.toThrow();
    await expect(
      writer.upsertRunManifest({
        ...createRunManifest(),
        params: { ["x".repeat(257)]: true },
      })
    ).rejects.toThrow();
    await expect(
      writer.commitEvalItem({
        evalId,
        runId,
        itemId: "item-completed",
        results: [
          {
            evaluatorName: "quality",
            status: "completed",
            score: {},
            timing,
          },
        ],
      })
    ).rejects.toThrow();
    expect(count("evaluator_results")).toBe(0);

    const noop = new NoopMetadataWriter();
    await expect(noop.upsertRunManifest(createRunManifest())).resolves.toBeUndefined();
  });
});
