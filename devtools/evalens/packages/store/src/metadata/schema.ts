import {
  foreignKey,
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

const lifecycleStatuses = ["running", "finished", "error"] as const;
const resultStatuses = ["completed", "error"] as const;
const evaluatorResultStatuses = ["completed", "error", "skipped"] as const;
const paramValueTypes = ["null", "string", "number", "boolean", "array"] as const;

export const runs = sqliteTable(
  "runs",
  {
    runId: text("run_id").primaryKey(),
    formatVersion: integer("format_version").notNull(),
    experimentName: text("experiment_name").notNull(),
    description: text("description"),
    datasetName: text("dataset_name").notNull(),
    datasetDigest: text("dataset_digest").notNull(),
    datasetSelectionDigest: text("dataset_selection_digest").notNull(),
    targetItemCount: integer("target_item_count").notNull(),
    status: text("status", { enum: lifecycleStatuses }).notNull(),
    paramsJson: text("params_json").notNull(),
    paramsDigest: text("params_digest").notNull(),
    createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
    finishedAt: integer("finished_at", { mode: "timestamp_ms" }),
  },
  (table) => [
    index("runs_experiment_created_idx").on(
      table.experimentName,
      table.createdAt,
      table.runId
    ),
    index("runs_experiment_status_created_idx").on(
      table.experimentName,
      table.status,
      table.createdAt,
      table.runId
    ),
    index("runs_dataset_idx").on(
      table.datasetName,
      table.datasetSelectionDigest,
      table.runId
    ),
  ]
);

export const runTags = sqliteTable(
  "run_tags",
  {
    runId: text("run_id")
      .notNull()
      .references(() => runs.runId, { onDelete: "cascade" }),
    tag: text("tag").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.runId, table.tag] }),
    index("run_tags_tag_idx").on(table.tag, table.runId),
  ]
);

export const runAdapters = sqliteTable(
  "run_adapters",
  {
    runId: text("run_id")
      .notNull()
      .references(() => runs.runId, { onDelete: "cascade" }),
    adapterName: text("adapter_name").notNull(),
    adapterVersion: text("adapter_version").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.runId, table.adapterName] }),
    index("run_adapters_identity_idx").on(
      table.adapterName,
      table.adapterVersion,
      table.runId
    ),
  ]
);

export const runParams = sqliteTable(
  "run_params",
  {
    runId: text("run_id")
      .notNull()
      .references(() => runs.runId, { onDelete: "cascade" }),
    key: text("key").notNull(),
    valueType: text("value_type", { enum: paramValueTypes }).notNull(),
    valueJson: text("value_json").notNull(),
    textValue: text("text_value"),
    numberValue: real("number_value"),
    booleanValue: integer("boolean_value", { mode: "boolean" }),
  },
  (table) => [
    primaryKey({ columns: [table.runId, table.key] }),
    index("run_params_text_idx").on(table.key, table.textValue, table.runId),
    index("run_params_number_idx").on(table.key, table.numberValue, table.runId),
    index("run_params_boolean_idx").on(table.key, table.booleanValue, table.runId),
  ]
);

export const runItems = sqliteTable(
  "run_items",
  {
    runId: text("run_id")
      .notNull()
      .references(() => runs.runId, { onDelete: "cascade" }),
    itemId: text("item_id").notNull(),
    itemDigest: text("item_digest").notNull(),
    status: text("status", { enum: resultStatuses }).notNull(),
    error: text("error"),
    startedAt: integer("started_at", { mode: "timestamp_ms" }).notNull(),
    finishedAt: integer("finished_at", { mode: "timestamp_ms" }).notNull(),
    durationMs: integer("duration_ms").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.runId, table.itemId] }),
    index("run_items_status_idx").on(table.runId, table.status, table.itemId),
    index("run_items_identity_idx").on(table.itemId, table.itemDigest, table.runId),
    index("run_items_duration_idx").on(table.runId, table.durationMs, table.itemId),
  ]
);

export const evals = sqliteTable(
  "evals",
  {
    evalId: text("eval_id").primaryKey(),
    runId: text("run_id")
      .notNull()
      .references(() => runs.runId, { onDelete: "cascade" }),
    formatVersion: integer("format_version").notNull(),
    status: text("status", { enum: lifecycleStatuses }).notNull(),
    error: text("error"),
    paramsJson: text("params_json").notNull(),
    paramsDigest: text("params_digest").notNull(),
    aggregatorVersion: text("aggregator_version").notNull(),
    createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
    finishedAt: integer("finished_at", { mode: "timestamp_ms" }),
  },
  (table) => [
    uniqueIndex("evals_id_run_unique").on(table.evalId, table.runId),
    index("evals_run_created_idx").on(table.runId, table.createdAt, table.evalId),
    index("evals_run_status_created_idx").on(
      table.runId,
      table.status,
      table.createdAt,
      table.evalId
    ),
  ]
);

export const evalParams = sqliteTable(
  "eval_params",
  {
    evalId: text("eval_id")
      .notNull()
      .references(() => evals.evalId, { onDelete: "cascade" }),
    key: text("key").notNull(),
    valueType: text("value_type", { enum: paramValueTypes }).notNull(),
    valueJson: text("value_json").notNull(),
    textValue: text("text_value"),
    numberValue: real("number_value"),
    booleanValue: integer("boolean_value", { mode: "boolean" }),
  },
  (table) => [
    primaryKey({ columns: [table.evalId, table.key] }),
    index("eval_params_text_idx").on(table.key, table.textValue, table.evalId),
    index("eval_params_number_idx").on(table.key, table.numberValue, table.evalId),
    index("eval_params_boolean_idx").on(table.key, table.booleanValue, table.evalId),
  ]
);

export const evalEvaluators = sqliteTable(
  "eval_evaluators",
  {
    evalId: text("eval_id")
      .notNull()
      .references(() => evals.evalId, { onDelete: "cascade" }),
    evaluatorName: text("evaluator_name").notNull(),
    evaluatorVersion: text("evaluator_version").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.evalId, table.evaluatorName] }),
    index("eval_evaluators_identity_idx").on(
      table.evaluatorName,
      table.evaluatorVersion,
      table.evalId
    ),
  ]
);

export const evalAdapters = sqliteTable(
  "eval_adapters",
  {
    evalId: text("eval_id")
      .notNull()
      .references(() => evals.evalId, { onDelete: "cascade" }),
    adapterName: text("adapter_name").notNull(),
    adapterVersion: text("adapter_version").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.evalId, table.adapterName] }),
    index("eval_adapters_identity_idx").on(
      table.adapterName,
      table.adapterVersion,
      table.evalId
    ),
  ]
);

export const evaluatorResults = sqliteTable(
  "evaluator_results",
  {
    evalId: text("eval_id").notNull(),
    runId: text("run_id").notNull(),
    itemId: text("item_id").notNull(),
    evaluatorName: text("evaluator_name").notNull(),
    status: text("status", { enum: evaluatorResultStatuses }).notNull(),
    message: text("message"),
    startedAt: integer("started_at", { mode: "timestamp_ms" }),
    finishedAt: integer("finished_at", { mode: "timestamp_ms" }),
    durationMs: integer("duration_ms"),
  },
  (table) => [
    primaryKey({
      columns: [table.evalId, table.itemId, table.evaluatorName],
    }),
    foreignKey({
      columns: [table.evalId, table.runId],
      foreignColumns: [evals.evalId, evals.runId],
    }).onDelete("cascade"),
    foreignKey({
      columns: [table.runId, table.itemId],
      foreignColumns: [runItems.runId, runItems.itemId],
    }).onDelete("cascade"),
    foreignKey({
      columns: [table.evalId, table.evaluatorName],
      foreignColumns: [evalEvaluators.evalId, evalEvaluators.evaluatorName],
    }).onDelete("cascade"),
    index("evaluator_results_status_idx").on(
      table.evalId,
      table.evaluatorName,
      table.status,
      table.itemId
    ),
    index("evaluator_results_duration_idx").on(
      table.evalId,
      table.evaluatorName,
      table.durationMs,
      table.itemId
    ),
  ]
);

export const evalScores = sqliteTable(
  "eval_scores",
  {
    evalId: text("eval_id").notNull(),
    itemId: text("item_id").notNull(),
    evaluatorName: text("evaluator_name").notNull(),
    scoreKey: text("score_key").notNull(),
    scoreValue: real("score_value").notNull(),
  },
  (table) => [
    primaryKey({
      columns: [table.evalId, table.itemId, table.evaluatorName, table.scoreKey],
    }),
    foreignKey({
      columns: [table.evalId, table.itemId, table.evaluatorName],
      foreignColumns: [
        evaluatorResults.evalId,
        evaluatorResults.itemId,
        evaluatorResults.evaluatorName,
      ],
    }).onDelete("cascade"),
    index("eval_scores_sort_idx").on(
      table.evalId,
      table.evaluatorName,
      table.scoreKey,
      table.scoreValue,
      table.itemId
    ),
  ]
);

export const evalScoreIdentities = sqliteTable(
  "eval_score_identities",
  {
    evalId: text("eval_id").notNull(),
    evaluatorName: text("evaluator_name").notNull(),
    evaluatorVersion: text("evaluator_version").notNull(),
    scoreKey: text("score_key").notNull(),
  },
  (table) => [
    primaryKey({
      columns: [table.evalId, table.evaluatorName, table.scoreKey],
    }),
    foreignKey({
      columns: [table.evalId, table.evaluatorName],
      foreignColumns: [evalEvaluators.evalId, evalEvaluators.evaluatorName],
    }).onDelete("cascade"),
    index("eval_score_identities_metric_idx").on(
      table.evaluatorName,
      table.evaluatorVersion,
      table.scoreKey,
      table.evalId
    ),
  ]
);

export const aggregateScores = sqliteTable(
  "aggregate_scores",
  {
    evalId: text("eval_id")
      .notNull()
      .references(() => evals.evalId, { onDelete: "cascade" }),
    scoreKey: text("score_key").notNull(),
    scoreValue: real("score_value").notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.evalId, table.scoreKey] }),
    index("aggregate_scores_metric_idx").on(table.scoreKey, table.evalId),
  ]
);

export const indexMetadata = sqliteTable("index_metadata", {
  id: integer("id").primaryKey(),
  schemaVersion: integer("schema_version").notNull(),
  state: text("state", { enum: ["ready", "rebuilding"] }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
});

export const reindexFences = sqliteTable("reindex_fences", {
  scopeKey: text("scope_key").primaryKey(),
  scopeType: text("scope_type", {
    enum: ["all", "experiment", "run", "eval"],
  }).notNull(),
  experimentName: text("experiment_name"),
  runId: text("run_id"),
  evalId: text("eval_id"),
  leaseId: text("lease_id").notNull(),
  revision: integer("revision").notNull(),
});
