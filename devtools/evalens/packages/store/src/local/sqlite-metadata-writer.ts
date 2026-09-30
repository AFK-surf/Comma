import { Database } from "bun:sqlite";
import { fileURLToPath } from "node:url";
import {
  and,
  eq,
  inArray,
  notExists,
  notInArray,
  or,
  sql,
  type ExtractTablesWithRelations,
  type SQL,
} from "drizzle-orm";
import { drizzle, type BunSQLiteDatabase } from "drizzle-orm/bun-sqlite";
import { migrate } from "drizzle-orm/bun-sqlite/migrator";
import type { SQLiteBunTransaction } from "drizzle-orm/bun-sqlite/session";

import {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  MetadataRepairLeaseLostError,
  type MetadataRepairToken,
  type ParsedEvalManifestMetadata as EvalManifestMetadataValue,
  type MetadataWriter,
  type MetadataWriteOptions,
  projectParams,
  RunItemCommitMetadata,
  RunManifestMetadata,
  type ParsedRunManifestMetadata as RunManifestMetadataValue,
} from "../metadata/contracts";
import {
  type IndexMetadataWriter,
  reindexScopeKey,
  type ReindexScope,
} from "../metadata/index-service";
import { metadataMigrationsUrl } from "../metadata/migrations";
import * as schema from "../metadata/schema";
import { METADATA_SCHEMA_VERSION } from "../metadata/version";
import { omit, truncateUtf8 } from "@evalens/utils";

const MESSAGE_MAX_BYTES = 2048;
type MetadataTransaction = SQLiteBunTransaction<
  typeof schema,
  ExtractTablesWithRelations<typeof schema>
>;

export class SqliteMetadataWriter implements MetadataWriter, IndexMetadataWriter {
  private readonly db: BunSQLiteDatabase<typeof schema>;

  constructor(readonly database: Database) {
    database.run("PRAGMA busy_timeout = 5000");
    database.run("PRAGMA foreign_keys = ON");
    if (database.filename !== ":memory:") {
      database.run("PRAGMA journal_mode = WAL");
    }
    this.db = drizzle(database, { schema });
    migrate(this.db, {
      migrationsFolder: fileURLToPath(metadataMigrationsUrl),
    });
    initializeIndexMetadata(this.db);
  }

  static open(filename: string): SqliteMetadataWriter {
    return new SqliteMetadataWriter(new Database(filename, { create: true }));
  }

  getIndexState(): "ready" | "rebuilding" {
    const metadata = this.db
      .select({ state: schema.indexMetadata.state })
      .from(schema.indexMetadata)
      .where(eq(schema.indexMetadata.id, 1))
      .get();
    if (!metadata) throw new Error("index metadata is missing");
    return metadata.state;
  }

  getRunExperimentName(runId: string): string | undefined {
    return this.db
      .select({ experimentName: schema.runs.experimentName })
      .from(schema.runs)
      .where(eq(schema.runs.runId, runId))
      .get()?.experimentName;
  }

  getEvaluationScopes(evalIds: string[]) {
    if (evalIds.length === 0) return [];
    return this.db
      .select({
        evalId: schema.evals.evalId,
        runId: schema.evals.runId,
        experimentName: schema.runs.experimentName,
      })
      .from(schema.evals)
      .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
      .where(inArray(schema.evals.evalId, evalIds))
      .all();
  }

  async upsertRunManifest(
    metadata: RunManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = RunManifestMetadata.parse(metadata);
    const params = projectParams(parsed.params);
    const row = toRunRow(parsed);

    this.db.transaction((tx) => {
      this.prepareMetadataWrite(
        tx,
        { experimentName: parsed.experimentName, runId: parsed.runId },
        options
      );
      tx.insert(schema.runs)
        .values(row)
        .onConflictDoUpdate({
          target: schema.runs.runId,
          set: omit(row, ["runId"]),
        })
        .run();

      tx.delete(schema.runTags).where(eq(schema.runTags.runId, parsed.runId)).run();
      if (parsed.tags.length > 0) {
        tx.insert(schema.runTags)
          .values(parsed.tags.map((tag) => ({ runId: parsed.runId, tag })))
          .run();
      }

      tx.delete(schema.runAdapters)
        .where(eq(schema.runAdapters.runId, parsed.runId))
        .run();
      if (parsed.adapters.length > 0) {
        tx.insert(schema.runAdapters)
          .values(
            parsed.adapters.map(({ name, version }) => ({
              runId: parsed.runId,
              adapterName: name,
              adapterVersion: version,
            }))
          )
          .run();
      }

      tx.delete(schema.runParams).where(eq(schema.runParams.runId, parsed.runId)).run();
      if (params.length > 0) {
        tx.insert(schema.runParams)
          .values(
            params.map((param) => ({
              runId: parsed.runId,
              key: param.key,
              valueType: param.valueType,
              valueJson: param.valueJson,
              textValue: param.textValue,
              numberValue: param.numberValue,
              booleanValue: param.booleanValue,
            }))
          )
          .run();
      }
    });
  }

  async commitRunItem(
    metadata: RunItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = RunItemCommitMetadata.parse(metadata);
    const error =
      parsed.status === "error" ? truncateUtf8(parsed.error, MESSAGE_MAX_BYTES) : null;

    this.db.transaction((tx) => {
      const experimentName = options?.repair
        ? undefined
        : tx
            .select({ experimentName: schema.runs.experimentName })
            .from(schema.runs)
            .where(eq(schema.runs.runId, parsed.runId))
            .get()?.experimentName;
      this.prepareMetadataWrite(tx, { experimentName, runId: parsed.runId }, options);
      tx.insert(schema.runItems)
        .values({
          runId: parsed.runId,
          itemId: parsed.itemId,
          itemDigest: parsed.itemDigest,
          status: parsed.status,
          error,
          startedAt: parsed.timing.startedAt,
          finishedAt: parsed.timing.finishedAt,
          durationMs: parsed.timing.durationMs,
        })
        .onConflictDoUpdate({
          target: [schema.runItems.runId, schema.runItems.itemId],
          set: {
            itemDigest: parsed.itemDigest,
            status: parsed.status,
            error,
            startedAt: parsed.timing.startedAt,
            finishedAt: parsed.timing.finishedAt,
            durationMs: parsed.timing.durationMs,
          },
        })
        .run();
    });
  }

  async upsertEvalManifest(
    metadata: EvalManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = EvalManifestMetadata.parse(metadata);
    const params = projectParams(parsed.params);
    const evaluatorNames = parsed.evaluators.map((evaluator) => evaluator.name);
    const row = toEvalRow(parsed);

    this.db.transaction((tx) => {
      const experimentName = options?.repair
        ? undefined
        : tx
            .select({ experimentName: schema.runs.experimentName })
            .from(schema.runs)
            .where(eq(schema.runs.runId, parsed.runId))
            .get()?.experimentName;
      this.prepareMetadataWrite(
        tx,
        { experimentName, runId: parsed.runId, evalId: parsed.evalId },
        options
      );
      tx.insert(schema.evals)
        .values(row)
        .onConflictDoUpdate({
          target: schema.evals.evalId,
          set: omit(row, ["evalId"]),
        })
        .run();

      tx.delete(schema.evalParams)
        .where(eq(schema.evalParams.evalId, parsed.evalId))
        .run();
      if (params.length > 0) {
        tx.insert(schema.evalParams)
          .values(
            params.map((param) => ({
              evalId: parsed.evalId,
              key: param.key,
              valueType: param.valueType,
              valueJson: param.valueJson,
              textValue: param.textValue,
              numberValue: param.numberValue,
              booleanValue: param.booleanValue,
            }))
          )
          .run();
      }

      tx.delete(schema.evalAdapters)
        .where(eq(schema.evalAdapters.evalId, parsed.evalId))
        .run();
      if (parsed.adapters.length > 0) {
        tx.insert(schema.evalAdapters)
          .values(
            parsed.adapters.map(({ name, version }) => ({
              evalId: parsed.evalId,
              adapterName: name,
              adapterVersion: version,
            }))
          )
          .run();
      }

      for (const evaluator of parsed.evaluators) {
        tx.insert(schema.evalEvaluators)
          .values({
            evalId: parsed.evalId,
            evaluatorName: evaluator.name,
            evaluatorVersion: evaluator.version,
          })
          .onConflictDoUpdate({
            target: [schema.evalEvaluators.evalId, schema.evalEvaluators.evaluatorName],
            set: { evaluatorVersion: evaluator.version },
          })
          .run();
        tx.update(schema.evalScoreIdentities)
          .set({ evaluatorVersion: evaluator.version })
          .where(
            and(
              eq(schema.evalScoreIdentities.evalId, parsed.evalId),
              eq(schema.evalScoreIdentities.evaluatorName, evaluator.name)
            )
          )
          .run();
      }
      tx.delete(schema.evalEvaluators)
        .where(
          and(
            eq(schema.evalEvaluators.evalId, parsed.evalId),
            notInArray(schema.evalEvaluators.evaluatorName, evaluatorNames)
          )
        )
        .run();
    });
  }

  async commitEvalItem(
    metadata: EvalItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = EvalItemCommitMetadata.parse(metadata);

    this.db.transaction((tx) => {
      const experimentName = options?.repair
        ? undefined
        : tx
            .select({ experimentName: schema.runs.experimentName })
            .from(schema.runs)
            .where(eq(schema.runs.runId, parsed.runId))
            .get()?.experimentName;
      this.prepareMetadataWrite(
        tx,
        { experimentName, runId: parsed.runId, evalId: parsed.evalId },
        options
      );
      const configuredEvaluators = tx
        .select({
          name: schema.evalEvaluators.evaluatorName,
          version: schema.evalEvaluators.evaluatorVersion,
        })
        .from(schema.evalEvaluators)
        .where(eq(schema.evalEvaluators.evalId, parsed.evalId))
        .all();
      const evaluatorVersions = new Map(
        configuredEvaluators.map(({ name, version }) => [name, version])
      );
      const resultEvaluatorNames = new Set(
        parsed.results.map((result) => result.evaluatorName)
      );
      if (
        configuredEvaluators.length !== resultEvaluatorNames.size ||
        configuredEvaluators.some(({ name }) => !resultEvaluatorNames.has(name))
      ) {
        throw new Error(
          "eval item results must exactly match the configured evaluator names"
        );
      }

      const previousIdentities = tx
        .select({
          evaluatorName: schema.evalScores.evaluatorName,
          scoreKey: schema.evalScores.scoreKey,
        })
        .from(schema.evalScores)
        .where(
          and(
            eq(schema.evalScores.evalId, parsed.evalId),
            eq(schema.evalScores.itemId, parsed.itemId)
          )
        )
        .all();
      const nextIdentities = new Set<string>();

      tx.delete(schema.evaluatorResults)
        .where(
          and(
            eq(schema.evaluatorResults.evalId, parsed.evalId),
            eq(schema.evaluatorResults.itemId, parsed.itemId)
          )
        )
        .run();

      for (const result of parsed.results) {
        const timing = "timing" in result ? result.timing : undefined;
        tx.insert(schema.evaluatorResults)
          .values({
            evalId: parsed.evalId,
            runId: parsed.runId,
            itemId: parsed.itemId,
            evaluatorName: result.evaluatorName,
            status: result.status,
            message:
              result.status === "completed"
                ? result.explanation === undefined
                  ? null
                  : truncateUtf8(result.explanation, MESSAGE_MAX_BYTES)
                : result.status === "error"
                  ? truncateUtf8(result.error, MESSAGE_MAX_BYTES)
                  : truncateUtf8(result.reason, MESSAGE_MAX_BYTES),
            startedAt: timing?.startedAt ?? null,
            finishedAt: timing?.finishedAt ?? null,
            durationMs: timing?.durationMs ?? null,
          })
          .run();

        if (result.status === "completed") {
          const evaluatorVersion = evaluatorVersions.get(result.evaluatorName);
          if (!evaluatorVersion) {
            throw new Error(`evaluator version is missing: ${result.evaluatorName}`);
          }
          const scores = Object.entries(result.score);
          tx.insert(schema.evalScores)
            .values(
              scores.map(([scoreKey, scoreValue]) => ({
                evalId: parsed.evalId,
                itemId: parsed.itemId,
                evaluatorName: result.evaluatorName,
                scoreKey,
                scoreValue,
              }))
            )
            .run();
          for (const [scoreKey] of scores) {
            nextIdentities.add(identityKey(result.evaluatorName, scoreKey));
            tx.insert(schema.evalScoreIdentities)
              .values({
                evalId: parsed.evalId,
                evaluatorName: result.evaluatorName,
                evaluatorVersion,
                scoreKey,
              })
              .onConflictDoUpdate({
                target: [
                  schema.evalScoreIdentities.evalId,
                  schema.evalScoreIdentities.evaluatorName,
                  schema.evalScoreIdentities.scoreKey,
                ],
                set: { evaluatorVersion },
              })
              .run();
          }
        }
      }

      for (const identity of previousIdentities) {
        if (
          nextIdentities.has(identityKey(identity.evaluatorName, identity.scoreKey))
        ) {
          continue;
        }
        tx.delete(schema.evalScoreIdentities)
          .where(
            and(
              eq(schema.evalScoreIdentities.evalId, parsed.evalId),
              eq(schema.evalScoreIdentities.evaluatorName, identity.evaluatorName),
              eq(schema.evalScoreIdentities.scoreKey, identity.scoreKey),
              notExists(
                tx
                  .select({ evalId: schema.evalScores.evalId })
                  .from(schema.evalScores)
                  .where(
                    and(
                      eq(schema.evalScores.evalId, parsed.evalId),
                      eq(schema.evalScores.evaluatorName, identity.evaluatorName),
                      eq(schema.evalScores.scoreKey, identity.scoreKey)
                    )
                  )
              )
            )
          )
          .run();
      }
    });
  }

  async replaceAggregateScores(
    metadata: AggregateScoresMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = AggregateScoresMetadata.parse(metadata);

    this.db.transaction((tx) => {
      const scope = options?.repair
        ? {}
        : (tx
            .select({
              runId: schema.evals.runId,
              experimentName: schema.runs.experimentName,
            })
            .from(schema.evals)
            .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
            .where(eq(schema.evals.evalId, parsed.evalId))
            .get() ?? {});
      this.prepareMetadataWrite(tx, { ...scope, evalId: parsed.evalId }, options);
      tx.delete(schema.aggregateScores)
        .where(eq(schema.aggregateScores.evalId, parsed.evalId))
        .run();
      const scores = Object.entries(parsed.scores);
      if (scores.length > 0) {
        tx.insert(schema.aggregateScores)
          .values(
            scores.map(([scoreKey, scoreValue]) => ({
              evalId: parsed.evalId,
              scoreKey,
              scoreValue,
            }))
          )
          .run();
      }
    });
  }

  async beginReindex(scope: ReindexScope): Promise<MetadataRepairToken> {
    const token: MetadataRepairToken = {
      scopeKey: reindexScopeKey(scope),
      scopeType: scope.type,
      leaseId: crypto.randomUUID(),
    };
    this.db.transaction((tx) => {
      const overlap = repairFenceOverlap(scope);
      const fences = tx.delete(schema.reindexFences);
      if (overlap) fences.where(overlap).run();
      else fences.run();
      tx.insert(schema.reindexFences)
        .values({
          scopeKey: token.scopeKey,
          scopeType: scope.type,
          experimentName: scope.type === "all" ? null : scope.experimentName,
          runId: scope.type === "run" || scope.type === "eval" ? scope.runId : null,
          evalId: scope.type === "eval" ? scope.evalId : null,
          leaseId: token.leaseId,
          revision: 0,
        })
        .run();
      if (scope.type === "all") {
        const updatedAt = new Date();
        tx.insert(schema.indexMetadata)
          .values({
            id: 1,
            schemaVersion: METADATA_SCHEMA_VERSION,
            state: "rebuilding",
            updatedAt,
          })
          .onConflictDoUpdate({
            target: schema.indexMetadata.id,
            set: {
              schemaVersion: METADATA_SCHEMA_VERSION,
              state: "rebuilding",
              updatedAt,
            },
          })
          .run();
        tx.delete(schema.runs).run();
        return;
      }
      if (scope.type === "experiment") {
        tx.delete(schema.runs)
          .where(eq(schema.runs.experimentName, scope.experimentName))
          .run();
        return;
      }
      if (scope.type === "run") {
        tx.delete(schema.runs).where(eq(schema.runs.runId, scope.runId)).run();
        return;
      }
      tx.delete(schema.evals).where(eq(schema.evals.evalId, scope.evalId)).run();
    });
    return token;
  }

  async finishReindex(token: MetadataRepairToken): Promise<boolean> {
    return this.db.transaction((tx) => {
      const condition = and(
        eq(schema.reindexFences.scopeKey, token.scopeKey),
        eq(schema.reindexFences.leaseId, token.leaseId),
        eq(schema.reindexFences.revision, 0)
      );
      if (!tx.select().from(schema.reindexFences).where(condition).get()) return false;
      if (token.scopeType === "all") {
        tx.update(schema.indexMetadata)
          .set({
            schemaVersion: METADATA_SCHEMA_VERSION,
            state: "ready",
            updatedAt: new Date(),
          })
          .where(eq(schema.indexMetadata.id, 1))
          .run();
      }
      tx.delete(schema.reindexFences).where(condition).run();
      return true;
    });
  }

  private prepareMetadataWrite(
    tx: MetadataTransaction,
    scope: MetadataMutationScope,
    options?: MetadataWriteOptions
  ): void {
    const repair = options?.repair;
    if (repair) {
      const current = tx
        .select({ scopeKey: schema.reindexFences.scopeKey })
        .from(schema.reindexFences)
        .where(
          and(
            eq(schema.reindexFences.scopeKey, repair.scopeKey),
            eq(schema.reindexFences.leaseId, repair.leaseId),
            eq(schema.reindexFences.revision, 0)
          )
        )
        .get();
      if (!current) throw new MetadataRepairLeaseLostError(repair);
      return;
    }
    this.touchRepairFences(tx, scope);
  }

  private touchRepairFences(
    tx: MetadataTransaction,
    scope: MetadataMutationScope
  ): void {
    const conditions = [eq(schema.reindexFences.scopeType, "all")];
    if (scope.experimentName) {
      conditions.push(
        and(
          eq(schema.reindexFences.scopeType, "experiment"),
          eq(schema.reindexFences.experimentName, scope.experimentName)
        )!
      );
    }
    if (scope.runId) {
      conditions.push(
        and(
          eq(schema.reindexFences.scopeType, "run"),
          eq(schema.reindexFences.runId, scope.runId)
        )!
      );
    }
    if (scope.evalId) {
      conditions.push(
        and(
          eq(schema.reindexFences.scopeType, "eval"),
          eq(schema.reindexFences.evalId, scope.evalId)
        )!
      );
    }
    tx.update(schema.reindexFences)
      .set({ revision: sql`${schema.reindexFences.revision} + 1` })
      .where(or(...conditions))
      .run();
  }
}

type MetadataMutationScope = {
  experimentName?: string;
  runId?: string;
  evalId?: string;
};

function repairFenceOverlap(scope: ReindexScope): SQL | undefined {
  if (scope.type === "all") return undefined;
  const global = eq(schema.reindexFences.scopeType, "all");
  const experiment = and(
    eq(schema.reindexFences.scopeType, "experiment"),
    eq(schema.reindexFences.experimentName, scope.experimentName)
  )!;
  if (scope.type === "experiment") {
    return or(global, eq(schema.reindexFences.experimentName, scope.experimentName));
  }
  if (scope.type === "run") {
    return or(global, experiment, eq(schema.reindexFences.runId, scope.runId));
  }
  return or(
    global,
    experiment,
    and(
      eq(schema.reindexFences.scopeType, "run"),
      eq(schema.reindexFences.runId, scope.runId)
    )!,
    eq(schema.reindexFences.evalId, scope.evalId)
  );
}

function identityKey(evaluatorName: string, scoreKey: string): string {
  return JSON.stringify([evaluatorName, scoreKey]);
}

function toRunRow(parsed: RunManifestMetadataValue) {
  const { params, tags: _tags, adapters: _adapters, finishedAt, ...manifest } = parsed;
  return {
    ...manifest,
    description: manifest.description ?? null,
    paramsJson: JSON.stringify(params),
    finishedAt: finishedAt ?? null,
  };
}

function toEvalRow(parsed: EvalManifestMetadataValue) {
  const {
    params,
    evaluators: _evaluators,
    adapters: _adapters,
    finishedAt,
    error,
    ...manifest
  } = parsed;
  return {
    ...manifest,
    error: error === undefined ? null : truncateUtf8(error, MESSAGE_MAX_BYTES),
    paramsJson: JSON.stringify(params),
    finishedAt: finishedAt ?? null,
  };
}

function initializeIndexMetadata(database: BunSQLiteDatabase<typeof schema>): void {
  database
    .insert(schema.indexMetadata)
    .values({
      id: 1,
      schemaVersion: METADATA_SCHEMA_VERSION,
      state: "rebuilding",
      updatedAt: new Date(0),
    })
    .onConflictDoNothing({ target: schema.indexMetadata.id })
    .run();

  const metadata = database
    .select({
      schemaVersion: schema.indexMetadata.schemaVersion,
      state: schema.indexMetadata.state,
    })
    .from(schema.indexMetadata)
    .where(eq(schema.indexMetadata.id, 1))
    .get();
  if (!metadata) {
    throw new Error("index metadata is missing");
  }
  if (metadata.schemaVersion > METADATA_SCHEMA_VERSION) {
    throw new Error(`unsupported metadata schema version: ${metadata.schemaVersion}`);
  }
  if (metadata.schemaVersion < METADATA_SCHEMA_VERSION) {
    database
      .update(schema.indexMetadata)
      .set({
        schemaVersion: METADATA_SCHEMA_VERSION,
        state: "rebuilding",
        updatedAt: new Date(),
      })
      .where(eq(schema.indexMetadata.id, 1))
      .run();
  }
}
