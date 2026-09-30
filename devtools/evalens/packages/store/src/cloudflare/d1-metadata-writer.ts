import {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  MetadataRepairLeaseLostError,
  type MetadataRepairToken,
  type MetadataWriteOptions,
  projectParams,
  RunItemCommitMetadata,
  RunManifestMetadata,
} from "../metadata/contracts";
import {
  type IndexMetadataWriter,
  reindexScopeKey,
  type ReindexScope,
} from "../metadata/index-service";
import * as schema from "../metadata/schema";
import { METADATA_SCHEMA_VERSION } from "../metadata/version";
import { truncateUtf8 } from "@evalens/utils";
import { and, eq, notExists, notInArray, or, sql, type SQL } from "drizzle-orm";
import type { BatchItem } from "drizzle-orm/batch";
import { drizzle, type DrizzleD1Database } from "drizzle-orm/d1";

const MESSAGE_MAX_BYTES = 2048;
const D1_MAX_BINDINGS_PER_STATEMENT = 90;
type Query = BatchItem<"sqlite">;

export class D1MetadataWriter implements IndexMetadataWriter {
  private readonly db: DrizzleD1Database<typeof schema>;

  constructor(database: D1Database) {
    this.db = drizzle(database, { schema });
  }

  async upsertRunManifest(
    metadata: RunManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = RunManifestMetadata.parse(metadata);
    const params = projectParams(parsed.params);
    const row = {
      runId: parsed.runId,
      formatVersion: parsed.formatVersion,
      experimentName: parsed.experimentName,
      description: parsed.description ?? null,
      datasetName: parsed.datasetName,
      datasetDigest: parsed.datasetDigest,
      datasetSelectionDigest: parsed.datasetSelectionDigest,
      targetItemCount: parsed.targetItemCount,
      status: parsed.status,
      paramsJson: JSON.stringify(parsed.params),
      paramsDigest: parsed.paramsDigest,
      createdAt: parsed.createdAt,
      finishedAt: parsed.finishedAt ?? null,
    };
    const queries: Query[] = [
      this.readyQuery(),
      this.db
        .insert(schema.runs)
        .values(row)
        .onConflictDoUpdate({
          target: schema.runs.runId,
          set: {
            formatVersion: row.formatVersion,
            experimentName: row.experimentName,
            description: row.description,
            datasetName: row.datasetName,
            datasetDigest: row.datasetDigest,
            datasetSelectionDigest: row.datasetSelectionDigest,
            targetItemCount: row.targetItemCount,
            status: row.status,
            paramsJson: row.paramsJson,
            paramsDigest: row.paramsDigest,
            createdAt: row.createdAt,
            finishedAt: row.finishedAt,
          },
        }),
      this.db.delete(schema.runTags).where(eq(schema.runTags.runId, parsed.runId)),
      this.db
        .delete(schema.runAdapters)
        .where(eq(schema.runAdapters.runId, parsed.runId)),
      this.db.delete(schema.runParams).where(eq(schema.runParams.runId, parsed.runId)),
    ];
    if (parsed.tags.length > 0) {
      queries.push(
        this.db
          .insert(schema.runTags)
          .values(parsed.tags.map((tag) => ({ runId: parsed.runId, tag })))
      );
    }
    if (parsed.adapters.length > 0) {
      queries.push(
        this.db.insert(schema.runAdapters).values(
          parsed.adapters.map(({ name, version }) => ({
            runId: parsed.runId,
            adapterName: name,
            adapterVersion: version,
          }))
        )
      );
    }
    if (params.length > 0) {
      queries.push(
        this.db.insert(schema.runParams).values(
          params.map((param) => ({
            runId: parsed.runId,
            ...param,
          }))
        )
      );
    }
    await this.executeMetadataBatch(
      { experimentName: parsed.experimentName, runId: parsed.runId },
      options,
      queries
    );
  }

  async commitRunItem(
    metadata: RunItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = RunItemCommitMetadata.parse(metadata);
    const experimentName = options?.repair
      ? undefined
      : await this.getRunExperimentName(parsed.runId);
    const row = {
      runId: parsed.runId,
      itemId: parsed.itemId,
      itemDigest: parsed.itemDigest,
      status: parsed.status,
      error:
        parsed.status === "error"
          ? truncateUtf8(parsed.error, MESSAGE_MAX_BYTES)
          : null,
      startedAt: parsed.timing.startedAt,
      finishedAt: parsed.timing.finishedAt,
      durationMs: parsed.timing.durationMs,
    };
    await this.executeMetadataBatch({ experimentName, runId: parsed.runId }, options, [
      this.readyQuery(),
      this.db
        .insert(schema.runItems)
        .values(row)
        .onConflictDoUpdate({
          target: [schema.runItems.runId, schema.runItems.itemId],
          set: {
            itemDigest: row.itemDigest,
            status: row.status,
            error: row.error,
            startedAt: row.startedAt,
            finishedAt: row.finishedAt,
            durationMs: row.durationMs,
          },
        }),
    ]);
  }

  async upsertEvalManifest(
    metadata: EvalManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = EvalManifestMetadata.parse(metadata);
    const experimentName = options?.repair
      ? undefined
      : await this.getRunExperimentName(parsed.runId);
    const params = projectParams(parsed.params);
    const evaluatorNames = parsed.evaluators.map(({ name }) => name);
    const row = {
      evalId: parsed.evalId,
      runId: parsed.runId,
      formatVersion: parsed.formatVersion,
      status: parsed.status,
      error:
        parsed.error === undefined
          ? null
          : truncateUtf8(parsed.error, MESSAGE_MAX_BYTES),
      paramsJson: JSON.stringify(parsed.params),
      paramsDigest: parsed.paramsDigest,
      aggregatorVersion: parsed.aggregatorVersion,
      createdAt: parsed.createdAt,
      finishedAt: parsed.finishedAt ?? null,
    };
    const queries: Query[] = [
      this.readyQuery(),
      this.db
        .insert(schema.evals)
        .values(row)
        .onConflictDoUpdate({
          target: schema.evals.evalId,
          set: {
            runId: row.runId,
            formatVersion: row.formatVersion,
            status: row.status,
            error: row.error,
            paramsJson: row.paramsJson,
            paramsDigest: row.paramsDigest,
            aggregatorVersion: row.aggregatorVersion,
            createdAt: row.createdAt,
            finishedAt: row.finishedAt,
          },
        }),
      this.db
        .delete(schema.evalParams)
        .where(eq(schema.evalParams.evalId, parsed.evalId)),
      this.db
        .delete(schema.evalAdapters)
        .where(eq(schema.evalAdapters.evalId, parsed.evalId)),
    ];
    if (params.length > 0) {
      queries.push(
        this.db.insert(schema.evalParams).values(
          params.map((param) => ({
            evalId: parsed.evalId,
            ...param,
          }))
        )
      );
    }
    if (parsed.adapters.length > 0) {
      queries.push(
        this.db.insert(schema.evalAdapters).values(
          parsed.adapters.map(({ name, version }) => ({
            evalId: parsed.evalId,
            adapterName: name,
            adapterVersion: version,
          }))
        )
      );
    }
    queries.push(
      ...parsed.evaluators.map((evaluator) =>
        this.db
          .insert(schema.evalEvaluators)
          .values({
            evalId: parsed.evalId,
            evaluatorName: evaluator.name,
            evaluatorVersion: evaluator.version,
          })
          .onConflictDoUpdate({
            target: [schema.evalEvaluators.evalId, schema.evalEvaluators.evaluatorName],
            set: { evaluatorVersion: evaluator.version },
          })
      ),
      ...parsed.evaluators.map((evaluator) =>
        this.db
          .update(schema.evalScoreIdentities)
          .set({ evaluatorVersion: evaluator.version })
          .where(
            and(
              eq(schema.evalScoreIdentities.evalId, parsed.evalId),
              eq(schema.evalScoreIdentities.evaluatorName, evaluator.name)
            )
          )
      ),
      this.db
        .delete(schema.evalEvaluators)
        .where(
          and(
            eq(schema.evalEvaluators.evalId, parsed.evalId),
            notInArray(schema.evalEvaluators.evaluatorName, evaluatorNames)
          )
        )
    );
    await this.executeMetadataBatch(
      { experimentName, runId: parsed.runId, evalId: parsed.evalId },
      options,
      queries
    );
  }

  async commitEvalItem(
    metadata: EvalItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = EvalItemCommitMetadata.parse(metadata);
    const experimentName = options?.repair
      ? undefined
      : await this.getRunExperimentName(parsed.runId);
    const configured = await this.db
      .select({
        name: schema.evalEvaluators.evaluatorName,
        version: schema.evalEvaluators.evaluatorVersion,
      })
      .from(schema.evalEvaluators)
      .where(eq(schema.evalEvaluators.evalId, parsed.evalId));
    const resultNames = new Set(
      parsed.results.map(({ evaluatorName }) => evaluatorName)
    );
    if (
      configured.length !== resultNames.size ||
      configured.some(({ name }) => !resultNames.has(name))
    ) {
      throw new Error("eval item results must exactly match configured evaluators");
    }
    const evaluatorVersions = new Map(
      configured.map(({ name, version }) => [name, version])
    );
    const previousIdentities = await this.db
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
      );
    const nextIdentities = new Set<string>();

    const queries: Query[] = [
      this.readyQuery(),
      this.db
        .delete(schema.evaluatorResults)
        .where(
          and(
            eq(schema.evaluatorResults.evalId, parsed.evalId),
            eq(schema.evaluatorResults.itemId, parsed.itemId)
          )
        ),
    ];
    for (const result of parsed.results) {
      const timing = "timing" in result ? result.timing : undefined;
      const message =
        result.status === "completed"
          ? result.explanation
          : result.status === "error"
            ? result.error
            : result.reason;
      queries.push(
        this.db.insert(schema.evaluatorResults).values({
          evalId: parsed.evalId,
          runId: parsed.runId,
          itemId: parsed.itemId,
          evaluatorName: result.evaluatorName,
          status: result.status,
          message:
            message === undefined ? null : truncateUtf8(message, MESSAGE_MAX_BYTES),
          startedAt: timing?.startedAt ?? null,
          finishedAt: timing?.finishedAt ?? null,
          durationMs: timing?.durationMs ?? null,
        })
      );
      if (result.status === "completed") {
        const evaluatorVersion = evaluatorVersions.get(result.evaluatorName);
        if (!evaluatorVersion) {
          throw new Error(`evaluator version is missing: ${result.evaluatorName}`);
        }
        const scores = Object.entries(result.score);
        queries.push(
          ...chunk(
            scores.map(([scoreKey, scoreValue]) => ({
              evalId: parsed.evalId,
              itemId: parsed.itemId,
              evaluatorName: result.evaluatorName,
              scoreKey,
              scoreValue,
            })),
            Math.floor(D1_MAX_BINDINGS_PER_STATEMENT / 5)
          ).map((rows) => this.db.insert(schema.evalScores).values(rows))
        );
        for (const [scoreKey] of scores) {
          nextIdentities.add(identityKey(result.evaluatorName, scoreKey));
          queries.push(
            this.db
              .insert(schema.evalScoreIdentities)
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
          );
        }
      }
    }
    for (const identity of previousIdentities) {
      if (nextIdentities.has(identityKey(identity.evaluatorName, identity.scoreKey))) {
        continue;
      }
      queries.push(
        this.db.delete(schema.evalScoreIdentities).where(
          and(
            eq(schema.evalScoreIdentities.evalId, parsed.evalId),
            eq(schema.evalScoreIdentities.evaluatorName, identity.evaluatorName),
            eq(schema.evalScoreIdentities.scoreKey, identity.scoreKey),
            notExists(
              this.db
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
      );
    }
    await this.executeMetadataBatch(
      { experimentName, runId: parsed.runId, evalId: parsed.evalId },
      options,
      queries
    );
  }

  async replaceAggregateScores(
    metadata: AggregateScoresMetadata,
    options?: MetadataWriteOptions
  ): Promise<void> {
    const parsed = AggregateScoresMetadata.parse(metadata);
    const scope = options?.repair ? {} : await this.getEvaluationScope(parsed.evalId);
    const queries: Query[] = [
      this.readyQuery(),
      this.db
        .delete(schema.aggregateScores)
        .where(eq(schema.aggregateScores.evalId, parsed.evalId)),
    ];
    const scores = Object.entries(parsed.scores);
    if (scores.length > 0) {
      queries.push(
        ...chunk(
          scores.map(([scoreKey, scoreValue]) => ({
            evalId: parsed.evalId,
            scoreKey,
            scoreValue,
          })),
          Math.floor(D1_MAX_BINDINGS_PER_STATEMENT / 3)
        ).map((rows) => this.db.insert(schema.aggregateScores).values(rows))
      );
    }
    await this.executeMetadataBatch(
      { ...scope, evalId: parsed.evalId },
      options,
      queries
    );
  }

  async beginReindex(scope: ReindexScope): Promise<MetadataRepairToken> {
    const token: MetadataRepairToken = {
      scopeKey: reindexScopeKey(scope),
      scopeType: scope.type,
      leaseId: crypto.randomUUID(),
    };
    const fence = this.db.insert(schema.reindexFences).values({
      scopeKey: token.scopeKey,
      scopeType: scope.type,
      experimentName: scope.type === "all" ? null : scope.experimentName,
      runId: scope.type === "run" || scope.type === "eval" ? scope.runId : null,
      evalId: scope.type === "eval" ? scope.evalId : null,
      leaseId: token.leaseId,
      revision: 0,
    });
    const overlap = repairFenceOverlap(scope);
    const overlappingFences = overlap
      ? this.db.delete(schema.reindexFences).where(overlap)
      : this.db.delete(schema.reindexFences);
    if (scope.type === "all") {
      const updatedAt = new Date();
      await this.db.batch([
        overlappingFences,
        fence,
        this.db
          .insert(schema.indexMetadata)
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
          }),
        this.db.delete(schema.runs),
      ]);
      return token;
    }
    const deletion =
      scope.type === "experiment"
        ? this.db
            .delete(schema.runs)
            .where(eq(schema.runs.experimentName, scope.experimentName))
        : scope.type === "run"
          ? this.db.delete(schema.runs).where(eq(schema.runs.runId, scope.runId))
          : this.db.delete(schema.evals).where(eq(schema.evals.evalId, scope.evalId));
    await this.db.batch([overlappingFences, fence, deletion]);
    return token;
  }

  async finishReindex(token: MetadataRepairToken): Promise<boolean> {
    const condition = and(
      eq(schema.reindexFences.scopeKey, token.scopeKey),
      eq(schema.reindexFences.leaseId, token.leaseId),
      eq(schema.reindexFences.revision, 0)
    );
    const deletion = this.db.delete(schema.reindexFences).where(condition);
    if (token.scopeType === "all") {
      const [, deletionResult] = await this.db.batch([
        this.db
          .update(schema.indexMetadata)
          .set({
            schemaVersion: METADATA_SCHEMA_VERSION,
            state: "ready",
            updatedAt: new Date(),
          })
          .where(
            and(
              eq(schema.indexMetadata.id, 1),
              sql`exists (select 1 from ${schema.reindexFences} where ${condition})`
            )
          ),
        deletion,
      ]);
      return deletionResult.meta.changes === 1;
    }
    const [deletionResult] = await this.db.batch([deletion]);
    return deletionResult.meta.changes === 1;
  }

  private async getRunExperimentName(runId: string): Promise<string | undefined> {
    return (
      await this.db
        .select({ experimentName: schema.runs.experimentName })
        .from(schema.runs)
        .where(eq(schema.runs.runId, runId))
        .get()
    )?.experimentName;
  }

  private async getEvaluationScope(evalId: string): Promise<MetadataMutationScope> {
    return (
      (await this.db
        .select({
          runId: schema.evals.runId,
          experimentName: schema.runs.experimentName,
        })
        .from(schema.evals)
        .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
        .where(eq(schema.evals.evalId, evalId))
        .get()) ?? {}
    );
  }

  private async executeMetadataBatch(
    scope: MetadataMutationScope,
    options: MetadataWriteOptions | undefined,
    mutations: Query[]
  ): Promise<void> {
    const repair = options?.repair;
    const assertionKey = repair ? `assert:${repair.leaseId}` : undefined;
    const queries: [Query, ...Query[]] = [
      repair
        ? this.repairLeaseAssertionQuery(repair, `assert:${repair.leaseId}`)
        : this.touchRepairFencesQuery(scope),
    ];
    queries.push(...mutations);
    if (assertionKey) {
      queries.push(
        this.db
          .delete(schema.reindexFences)
          .where(eq(schema.reindexFences.scopeKey, assertionKey))
      );
    }
    try {
      await this.db.batch(queries);
    } catch (error) {
      if (repair && !(await this.isRepairLeaseCurrent(repair))) {
        throw new MetadataRepairLeaseLostError(repair);
      }
      throw error;
    }
  }

  private repairLeaseAssertionQuery(
    repair: MetadataRepairToken,
    assertionKey: string
  ): Query {
    const condition = and(
      eq(schema.reindexFences.scopeKey, repair.scopeKey),
      eq(schema.reindexFences.leaseId, repair.leaseId),
      eq(schema.reindexFences.revision, 0)
    );
    // D1 batches are transactional. A lost lease makes this first statement
    // violate lease_id NOT NULL, rolling back the entire metadata mutation.
    return this.db.insert(schema.reindexFences).values({
      scopeKey: assertionKey,
      scopeType: repair.scopeType,
      experimentName: null,
      runId: null,
      evalId: null,
      leaseId: sql`(select ${schema.reindexFences.leaseId} from ${schema.reindexFences} where ${condition} limit 1)`,
      revision: 0,
    });
  }

  private async isRepairLeaseCurrent(repair: MetadataRepairToken): Promise<boolean> {
    return Boolean(
      await this.db
        .select({ scopeKey: schema.reindexFences.scopeKey })
        .from(schema.reindexFences)
        .where(
          and(
            eq(schema.reindexFences.scopeKey, repair.scopeKey),
            eq(schema.reindexFences.leaseId, repair.leaseId),
            eq(schema.reindexFences.revision, 0)
          )
        )
        .get()
    );
  }

  private touchRepairFencesQuery(scope: MetadataMutationScope): Query {
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
    return this.db
      .update(schema.reindexFences)
      .set({ revision: sql`${schema.reindexFences.revision} + 1` })
      .where(or(...conditions));
  }

  private readyQuery(): Query {
    return this.db
      .insert(schema.indexMetadata)
      .values({
        id: 1,
        schemaVersion: METADATA_SCHEMA_VERSION,
        state: "ready",
        updatedAt: new Date(),
      })
      .onConflictDoNothing({ target: schema.indexMetadata.id });
  }
}

function chunk<T>(values: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let offset = 0; offset < values.length; offset += size) {
    chunks.push(values.slice(offset, offset + size));
  }
  return chunks;
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
