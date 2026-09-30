import {
  metricIdentityKey,
  MAX_COMPARE_EVALUATIONS,
  type DataState,
  type EvalCatalogEntry,
  type EvalComparison,
  type EvalFilters,
  type MetricIdentity,
  type EvaluatorResultCell,
  type ExperimentSummary,
  type QueryService,
  type RunFilters,
  type RunItemSummary,
  type RunSummary,
  type Page,
} from "@evalens/core/api";
import * as schema from "./metadata/schema";
import { METADATA_SCHEMA_VERSION } from "./metadata/version";
import { Params } from "@evalens/core/schemas";
import {
  and,
  asc,
  count,
  countDistinct,
  desc,
  eq,
  exists,
  gte,
  inArray,
  like,
  lte,
  max,
  or,
  sql,
} from "drizzle-orm";
import type { AnySQLiteColumn, BaseSQLiteDatabase } from "drizzle-orm/sqlite-core";

type Database = BaseSQLiteDatabase<"async", unknown, typeof schema>;

export class SqlQueryService implements QueryService {
  constructor(private readonly database: Database) {}

  async getState(): Promise<DataState> {
    const [row] = await this.database
      .select({
        schemaVersion: schema.indexMetadata.schemaVersion,
        state: schema.indexMetadata.state,
      })
      .from(schema.indexMetadata)
      .where(eq(schema.indexMetadata.id, 1))
      .limit(1);
    return row?.schemaVersion === METADATA_SCHEMA_VERSION && row.state === "ready"
      ? "ready"
      : "reindexing";
  }

  async listExperiments(): Promise<ExperimentSummary[]> {
    const rows = await this.database
      .select({
        name: schema.runs.experimentName,
        runCount: count(),
        latestRunAt: max(schema.runs.createdAt),
      })
      .from(schema.runs)
      .groupBy(schema.runs.experimentName)
      .orderBy(desc(max(schema.runs.createdAt)), asc(schema.runs.experimentName));

    return Promise.all(
      rows.map(async (row) => {
        const [latest] = await this.database
          .select({ description: schema.runs.description })
          .from(schema.runs)
          .where(eq(schema.runs.experimentName, row.name))
          .orderBy(desc(schema.runs.createdAt), desc(schema.runs.runId))
          .limit(1);
        return {
          name: row.name,
          ...(latest?.description ? { description: latest.description } : {}),
          runCount: row.runCount,
          ...(row.latestRunAt ? { latestRunAt: row.latestRunAt.toISOString() } : {}),
        };
      })
    );
  }

  async listRuns(filters: RunFilters = {}): Promise<Page<RunSummary>> {
    const conditions = [];
    if (filters.experimentName) {
      conditions.push(eq(schema.runs.experimentName, filters.experimentName));
    }
    if (filters.status) conditions.push(eq(schema.runs.status, filters.status));
    if (filters.query) {
      const pattern = `%${filters.query}%`;
      conditions.push(
        or(
          like(schema.runs.runId, pattern),
          like(schema.runs.datasetName, pattern),
          exists(
            this.database
              .select({ runId: schema.runTags.runId })
              .from(schema.runTags)
              .where(
                and(
                  eq(schema.runTags.runId, schema.runs.runId),
                  like(schema.runTags.tag, pattern)
                )
              )
          )
        )!
      );
    }
    if (filters.tag) {
      conditions.push(
        exists(
          this.database
            .select({ runId: schema.runTags.runId })
            .from(schema.runTags)
            .where(
              and(
                eq(schema.runTags.runId, schema.runs.runId),
                eq(schema.runTags.tag, filters.tag)
              )
            )
        )
      );
    }
    if (filters.createdAfter) {
      conditions.push(gte(schema.runs.createdAt, new Date(filters.createdAfter)));
    }
    if (filters.createdBefore) {
      conditions.push(lte(schema.runs.createdAt, new Date(filters.createdBefore)));
    }
    for (const [key, value] of Object.entries(filters.params ?? {})) {
      conditions.push(
        exists(
          this.database
            .select({ runId: schema.runParams.runId })
            .from(schema.runParams)
            .where(
              and(
                eq(schema.runParams.runId, schema.runs.runId),
                eq(schema.runParams.key, key),
                eq(schema.runParams.valueJson, JSON.stringify(value))
              )
            )
        )
      );
    }
    const condition = and(...conditions);
    const page = Math.max(1, filters.page ?? 1);
    const pageSize = Math.min(100, Math.max(1, filters.pageSize ?? 25));
    const [totalRow] = await this.database
      .select({ value: count() })
      .from(schema.runs)
      .where(condition);
    return {
      items: await this.queryRuns(condition, pageSize, (page - 1) * pageSize, true),
      page,
      pageSize,
      total: totalRow?.value ?? 0,
    };
  }

  async getRun(runId: string): Promise<RunSummary | null> {
    const [run] = await this.queryRuns(eq(schema.runs.runId, runId));
    return run ?? null;
  }

  async listEvaluations(filters: EvalFilters = {}): Promise<Page<EvalCatalogEntry>> {
    const conditions = [];
    if (filters.runId) conditions.push(eq(schema.evals.runId, filters.runId));
    if (filters.status) conditions.push(eq(schema.evals.status, filters.status));
    if (filters.experimentName) {
      conditions.push(eq(schema.runs.experimentName, filters.experimentName));
    }
    if (filters.query) {
      const pattern = `%${filters.query}%`;
      conditions.push(
        or(
          like(schema.evals.evalId, pattern),
          like(schema.evals.runId, pattern),
          like(schema.runs.experimentName, pattern)
        )!
      );
    }
    if (filters.tag) {
      conditions.push(
        exists(
          this.database
            .select({ runId: schema.runTags.runId })
            .from(schema.runTags)
            .where(
              and(
                eq(schema.runTags.runId, schema.runs.runId),
                eq(schema.runTags.tag, filters.tag)
              )
            )
        )
      );
    }
    if (filters.createdAfter) {
      conditions.push(gte(schema.evals.createdAt, new Date(filters.createdAfter)));
    }
    if (filters.createdBefore) {
      conditions.push(lte(schema.evals.createdAt, new Date(filters.createdBefore)));
    }
    for (const [key, value] of Object.entries(filters.runParams ?? {})) {
      conditions.push(
        exists(
          this.database
            .select({ runId: schema.runParams.runId })
            .from(schema.runParams)
            .where(
              and(
                eq(schema.runParams.runId, schema.runs.runId),
                eq(schema.runParams.key, key),
                eq(schema.runParams.valueJson, JSON.stringify(value))
              )
            )
        )
      );
    }
    for (const [key, value] of Object.entries(filters.evalParams ?? {})) {
      conditions.push(
        exists(
          this.database
            .select({ evalId: schema.evalParams.evalId })
            .from(schema.evalParams)
            .where(
              and(
                eq(schema.evalParams.evalId, schema.evals.evalId),
                eq(schema.evalParams.key, key),
                eq(schema.evalParams.valueJson, JSON.stringify(value))
              )
            )
        )
      );
    }
    const condition = and(...conditions);
    const page = Math.max(1, filters.page ?? 1);
    const pageSize = Math.min(100, Math.max(1, filters.pageSize ?? 25));
    const [totalRow, rows] = await Promise.all([
      this.database
        .select({ value: count() })
        .from(schema.evals)
        .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
        .where(condition)
        .then(([row]) => row),
      this.database
        .select({ eval: schema.evals, run: schema.runs })
        .from(schema.evals)
        .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
        .where(condition)
        .orderBy(desc(schema.evals.createdAt), desc(schema.evals.evalId))
        .limit(pageSize)
        .offset((page - 1) * pageSize),
    ]);
    const entries = await this.hydrateEvaluations(rows);
    return { items: entries, page, pageSize, total: totalRow?.value ?? 0 };
  }

  async getEvaluation(evalId: string): Promise<EvalCatalogEntry | null> {
    const rows = await this.database
      .select({ eval: schema.evals, run: schema.runs })
      .from(schema.evals)
      .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
      .where(eq(schema.evals.evalId, evalId))
      .limit(1);
    const [evaluation] = await this.hydrateEvaluations(rows);
    return evaluation ?? null;
  }

  async listRunItems(
    runId: string,
    evalId?: string,
    page = 1,
    pageSize = 50
  ): Promise<Page<RunItemSummary>> {
    if (evalId) {
      const [evaluation] = await this.database
        .select({ runId: schema.evals.runId })
        .from(schema.evals)
        .where(eq(schema.evals.evalId, evalId))
        .limit(1);
      if (evaluation?.runId !== runId) {
        throw new Error(`evaluation ${evalId} does not belong to run ${runId}`);
      }
    }
    return this.queryRunItemsPage(runId, evalId, page, pageSize);
  }

  async compareEvaluations(
    evalIds: string[],
    itemPage = 1,
    itemPageSize = 100,
    _referenceEvalId?: string
  ): Promise<EvalComparison> {
    const uniqueIds = [...new Set(evalIds)];
    if (uniqueIds.length > MAX_COMPARE_EVALUATIONS) {
      throw new Error(
        `cannot compare more than ${MAX_COMPARE_EVALUATIONS} evaluations`
      );
    }
    const page = Math.max(1, itemPage);
    const pageSize = Math.min(200, Math.max(1, itemPageSize));
    if (uniqueIds.length === 0) {
      return {
        evaluations: [],
        sharedItemCount: 0,
        itemPage: page,
        itemPageSize: pageSize,
        itemMetrics: [],
      };
    }
    const rows = await this.database
      .select({ eval: schema.evals, run: schema.runs })
      .from(schema.evals)
      .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
      .where(inArray(schema.evals.evalId, uniqueIds));
    const catalog = await this.hydrateEvaluations(rows);
    const foundIds = new Set(catalog.map(({ id }) => id));
    const missingIds = uniqueIds.filter((id) => !foundIds.has(id));
    if (missingIds.length > 0) {
      throw new Error(`evaluations not found: ${missingIds.join(", ")}`);
    }
    const unfinishedIds = catalog
      .filter(({ status }) => status !== "finished")
      .map(({ id }) => id);
    if (unfinishedIds.length > 0) {
      throw new Error(`evaluations are not finished: ${unfinishedIds.join(", ")}`);
    }
    const byId = new Map(catalog.map((entry) => [entry.id, entry]));
    const runIds = catalog.map((entry) => entry.run.id);
    const sharedItems = await this.querySharedItems(runIds, page, pageSize);
    const evaluations: EvalComparison["evaluations"] = [];
    for (const evalId of uniqueIds) {
      const entry = byId.get(evalId);
      if (!entry) continue;
      evaluations.push({
        ...entry,
        items: await this.queryRunItems(entry.run.id, evalId, sharedItems.itemIds),
      });
    }
    return {
      evaluations,
      sharedItemCount: sharedItems.total,
      itemPage: page,
      itemPageSize: pageSize,
      itemMetrics: commonItemMetrics(evaluations),
    };
  }

  private async queryRuns(
    condition?: ReturnType<typeof eq>,
    limit?: number,
    offset?: number,
    includeLatestFinishedEvaluation = false
  ): Promise<RunSummary[]> {
    let query = this.database
      .select()
      .from(schema.runs)
      .where(condition)
      .orderBy(desc(schema.runs.createdAt), desc(schema.runs.runId))
      .$dynamic();
    if (limit !== undefined) query = query.limit(limit);
    if (offset !== undefined) query = query.offset(offset);
    const rows = await query;
    const runIds = rows.map(({ runId }) => runId);
    const [tags, adapters, itemCounts, evalCounts, updatedAt, latestEvaluations] =
      await Promise.all([
        this.queryRunTags(runIds),
        this.queryRunAdapters(runIds),
        this.queryRunItemCounts(runIds),
        this.queryEvalCounts(runIds),
        this.queryRunUpdatedAt(runIds),
        includeLatestFinishedEvaluation
          ? this.queryLatestFinishedEvaluations(rows)
          : Promise.resolve(new Map<string, EvalCatalogEntry>()),
      ]);
    return rows.map((row) => ({
      id: row.runId,
      experimentName: row.experimentName,
      ...(row.description === null ? {} : { description: row.description }),
      datasetName: row.datasetName,
      datasetDigest: row.datasetDigest,
      datasetSelectionDigest: row.datasetSelectionDigest,
      targetItemCount: row.targetItemCount,
      status: row.status,
      tags: tags.get(row.runId) ?? [],
      adapters: adapters.get(row.runId) ?? [],
      params: Params.parse(JSON.parse(row.paramsJson)),
      createdAt: row.createdAt.toISOString(),
      updatedAt: latestDate(
        row.createdAt,
        row.finishedAt,
        updatedAt.get(row.runId)
      ).toISOString(),
      ...(row.finishedAt ? { finishedAt: row.finishedAt.toISOString() } : {}),
      itemCounts: itemCounts.get(row.runId) ?? { completed: 0, error: 0 },
      evalCount: evalCounts.get(row.runId) ?? 0,
      ...(latestEvaluations.get(row.runId)
        ? { latestFinishedEvaluation: latestEvaluations.get(row.runId)! }
        : {}),
    }));
  }

  private async queryLatestFinishedEvaluations(
    runs: Array<typeof schema.runs.$inferSelect>
  ): Promise<Map<string, EvalCatalogEntry>> {
    const byRun = new Map<string, EvalCatalogEntry>();
    if (runs.length === 0) return byRun;
    const ranked = this.database
      .select({
        evalId: schema.evals.evalId,
        rank: sql<number>`row_number() over (
          partition by ${schema.evals.runId}
          order by ${schema.evals.createdAt} desc, ${schema.evals.evalId} desc
        )`.as("rank"),
      })
      .from(schema.evals)
      .where(
        and(
          inArray(
            schema.evals.runId,
            runs.map(({ runId }) => runId)
          ),
          eq(schema.evals.status, "finished")
        )
      )
      .as("ranked_evaluations");
    const latestIds = await this.database
      .select({ evalId: ranked.evalId })
      .from(ranked)
      .where(eq(ranked.rank, 1));
    if (latestIds.length === 0) return byRun;
    const rows = await this.database
      .select()
      .from(schema.evals)
      .where(
        inArray(
          schema.evals.evalId,
          latestIds.map(({ evalId }) => evalId)
        )
      );
    const runsById = new Map(runs.map((run) => [run.runId, run]));
    const catalog = await this.hydrateEvaluations(
      rows.flatMap((evaluation) => {
        const run = runsById.get(evaluation.runId);
        return run ? [{ eval: evaluation, run }] : [];
      })
    );
    for (const entry of catalog) byRun.set(entry.run.id, entry);
    return byRun;
  }

  private async hydrateEvaluations(
    rows: Array<{
      eval: typeof schema.evals.$inferSelect;
      run: typeof schema.runs.$inferSelect;
    }>
  ): Promise<EvalCatalogEntry[]> {
    const evalIds = rows.map(({ eval: row }) => row.evalId);
    const runIds = rows.map(({ run }) => run.runId);
    const [
      evaluators,
      scoreIdentities,
      evalAdapters,
      aggregates,
      tags,
      resultCounts,
      runItemCounts,
    ] = await Promise.all([
      this.queryEvalEvaluators(evalIds),
      this.queryEvalScoreIdentities(evalIds),
      this.queryEvalAdapters(evalIds),
      this.queryAggregateScores(evalIds),
      this.queryRunTags(runIds),
      this.queryEvalResultCounts(evalIds),
      this.queryRunItemCounts(runIds),
    ]);
    return rows.map(({ eval: row, run }) => ({
      id: row.evalId,
      status: row.status,
      params: Params.parse(JSON.parse(row.paramsJson)),
      aggregatorVersion: row.aggregatorVersion,
      evaluators: evaluators.get(row.evalId) ?? [],
      scoreIdentities: scoreIdentities.get(row.evalId) ?? [],
      adapters: evalAdapters.get(row.evalId) ?? [],
      aggregateScores: aggregates.get(row.evalId) ?? {},
      resultCounts: {
        target:
          ((runItemCounts.get(run.runId)?.completed ?? 0) +
            (runItemCounts.get(run.runId)?.error ?? 0)) *
          (evaluators.get(row.evalId)?.length ?? 0),
        ...(resultCounts.get(row.evalId) ?? { completed: 0, error: 0, skipped: 0 }),
      },
      createdAt: row.createdAt.toISOString(),
      ...(row.finishedAt ? { finishedAt: row.finishedAt.toISOString() } : {}),
      ...(row.error === null ? {} : { error: row.error }),
      run: {
        id: run.runId,
        experimentName: run.experimentName,
        datasetName: run.datasetName,
        datasetDigest: run.datasetDigest,
        datasetSelectionDigest: run.datasetSelectionDigest,
        tags: tags.get(run.runId) ?? [],
        params: Params.parse(JSON.parse(run.paramsJson)),
        createdAt: run.createdAt.toISOString(),
      },
    }));
  }

  private async queryRunTags(runIds: string[]): Promise<Map<string, string[]>> {
    const grouped = new Map<string, string[]>();
    if (runIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.runTags)
      .where(inArray(schema.runTags.runId, runIds))
      .orderBy(asc(schema.runTags.tag));
    for (const row of rows) pushGrouped(grouped, row.runId, row.tag);
    return grouped;
  }

  private async queryRunAdapters(runIds: string[]) {
    const grouped = new Map<string, Array<{ name: string; version: string }>>();
    if (runIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.runAdapters)
      .where(inArray(schema.runAdapters.runId, runIds))
      .orderBy(asc(schema.runAdapters.adapterName));
    for (const row of rows) {
      pushGrouped(grouped, row.runId, {
        name: row.adapterName,
        version: row.adapterVersion,
      });
    }
    return grouped;
  }

  private async queryRunItemCounts(runIds: string[]) {
    const grouped = new Map<string, { completed: number; error: number }>();
    if (runIds.length === 0) return grouped;
    const rows = await this.database
      .select({
        runId: schema.runItems.runId,
        status: schema.runItems.status,
        count: count(),
      })
      .from(schema.runItems)
      .where(inArray(schema.runItems.runId, runIds))
      .groupBy(schema.runItems.runId, schema.runItems.status);
    for (const row of rows) {
      const values = grouped.get(row.runId) ?? { completed: 0, error: 0 };
      values[row.status] = row.count;
      grouped.set(row.runId, values);
    }
    return grouped;
  }

  private async queryEvalCounts(runIds: string[]) {
    const grouped = new Map<string, number>();
    if (runIds.length === 0) return grouped;
    const rows = await this.database
      .select({ runId: schema.evals.runId, count: count() })
      .from(schema.evals)
      .where(inArray(schema.evals.runId, runIds))
      .groupBy(schema.evals.runId);
    for (const row of rows) grouped.set(row.runId, row.count);
    return grouped;
  }

  private async queryRunUpdatedAt(runIds: string[]) {
    const grouped = new Map<string, Date>();
    if (runIds.length === 0) return grouped;
    const [items, evaluations, evaluatorResults] = await Promise.all([
      this.database
        .select({
          runId: schema.runItems.runId,
          updatedAt: max(schema.runItems.finishedAt),
        })
        .from(schema.runItems)
        .where(inArray(schema.runItems.runId, runIds))
        .groupBy(schema.runItems.runId),
      this.database
        .select({
          runId: schema.evals.runId,
          latestCreatedAt: max(schema.evals.createdAt),
          latestFinishedAt: max(schema.evals.finishedAt),
        })
        .from(schema.evals)
        .where(inArray(schema.evals.runId, runIds))
        .groupBy(schema.evals.runId),
      this.database
        .select({
          runId: schema.evaluatorResults.runId,
          updatedAt: max(schema.evaluatorResults.finishedAt),
        })
        .from(schema.evaluatorResults)
        .where(inArray(schema.evaluatorResults.runId, runIds))
        .groupBy(schema.evaluatorResults.runId),
    ]);
    for (const row of items) {
      if (row.updatedAt) grouped.set(row.runId, row.updatedAt);
    }
    for (const row of evaluations) {
      grouped.set(
        row.runId,
        latestDate(grouped.get(row.runId), row.latestCreatedAt, row.latestFinishedAt)
      );
    }
    for (const row of evaluatorResults) {
      if (row.updatedAt) {
        grouped.set(row.runId, latestDate(grouped.get(row.runId), row.updatedAt));
      }
    }
    return grouped;
  }

  private async queryEvalEvaluators(evalIds: string[]) {
    const grouped = new Map<string, Array<{ name: string; version: string }>>();
    if (evalIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.evalEvaluators)
      .where(inArray(schema.evalEvaluators.evalId, evalIds))
      .orderBy(asc(schema.evalEvaluators.evaluatorName));
    for (const row of rows) {
      pushGrouped(grouped, row.evalId, {
        name: row.evaluatorName,
        version: row.evaluatorVersion,
      });
    }
    return grouped;
  }

  private async queryEvalScoreIdentities(evalIds: string[]) {
    const grouped = new Map<string, MetricIdentity[]>();
    if (evalIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.evalScoreIdentities)
      .where(inArray(schema.evalScoreIdentities.evalId, evalIds))
      .orderBy(
        asc(schema.evalScoreIdentities.evaluatorName),
        asc(schema.evalScoreIdentities.evaluatorVersion),
        asc(schema.evalScoreIdentities.scoreKey)
      );
    for (const row of rows) {
      pushGrouped(grouped, row.evalId, {
        evaluatorName: row.evaluatorName,
        evaluatorVersion: row.evaluatorVersion,
        scoreKey: row.scoreKey,
      });
    }
    return grouped;
  }

  private async queryEvalAdapters(evalIds: string[]) {
    const grouped = new Map<string, Array<{ name: string; version: string }>>();
    if (evalIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.evalAdapters)
      .where(inArray(schema.evalAdapters.evalId, evalIds))
      .orderBy(asc(schema.evalAdapters.adapterName));
    for (const row of rows) {
      pushGrouped(grouped, row.evalId, {
        name: row.adapterName,
        version: row.adapterVersion,
      });
    }
    return grouped;
  }

  private async queryAggregateScores(evalIds: string[]) {
    const grouped = new Map<string, Record<string, number>>();
    if (evalIds.length === 0) return grouped;
    const rows = await this.database
      .select()
      .from(schema.aggregateScores)
      .where(inArray(schema.aggregateScores.evalId, evalIds))
      .orderBy(asc(schema.aggregateScores.scoreKey));
    for (const row of rows) {
      const values = grouped.get(row.evalId) ?? {};
      values[row.scoreKey] = row.scoreValue;
      grouped.set(row.evalId, values);
    }
    return grouped;
  }

  private async queryEvalResultCounts(evalIds: string[]) {
    const grouped = new Map<
      string,
      { completed: number; error: number; skipped: number }
    >();
    if (evalIds.length === 0) return grouped;
    const rows = await this.database
      .select({
        evalId: schema.evaluatorResults.evalId,
        status: schema.evaluatorResults.status,
        value: count(),
      })
      .from(schema.evaluatorResults)
      .where(inArray(schema.evaluatorResults.evalId, evalIds))
      .groupBy(schema.evaluatorResults.evalId, schema.evaluatorResults.status);
    for (const row of rows) {
      const values = grouped.get(row.evalId) ?? { completed: 0, error: 0, skipped: 0 };
      values[row.status] = row.value;
      grouped.set(row.evalId, values);
    }
    return grouped;
  }

  private async queryRunItems(
    runId: string,
    evalId?: string,
    itemIds?: string[]
  ): Promise<RunItemSummary[]> {
    if (itemIds?.length === 0) return [];
    const condition = itemIds
      ? and(
          eq(schema.runItems.runId, runId),
          inJsonArray(schema.runItems.itemId, itemIds)
        )
      : eq(schema.runItems.runId, runId);
    const rows = await this.database
      .select()
      .from(schema.runItems)
      .where(condition)
      .orderBy(asc(schema.runItems.itemId));
    const results = evalId
      ? await this.queryEvaluatorResults(evalId, itemIds)
      : new Map<string, EvaluatorResultCell[]>();
    return rows.map((row) => ({
      id: row.itemId,
      digest: row.itemDigest,
      status: row.status,
      durationMs: row.durationMs,
      ...(row.error === null ? {} : { error: row.error }),
      evaluatorResults: results.get(row.itemId) ?? [],
    }));
  }

  private async queryRunItemsPage(
    runId: string,
    evalId: string | undefined,
    requestedPage: number,
    requestedPageSize: number
  ): Promise<Page<RunItemSummary>> {
    const page = Math.max(1, requestedPage);
    const pageSize = Math.min(200, Math.max(1, requestedPageSize));
    const [totalRow, ids] = await Promise.all([
      this.database
        .select({ value: count() })
        .from(schema.runItems)
        .where(eq(schema.runItems.runId, runId))
        .then(([row]) => row),
      this.database
        .select({ itemId: schema.runItems.itemId })
        .from(schema.runItems)
        .where(eq(schema.runItems.runId, runId))
        .orderBy(asc(schema.runItems.itemId))
        .limit(pageSize)
        .offset((page - 1) * pageSize),
    ]);
    return {
      items: await this.queryRunItems(
        runId,
        evalId,
        ids.map(({ itemId }) => itemId)
      ),
      page,
      pageSize,
      total: totalRow?.value ?? 0,
    };
  }

  private async querySharedItems(
    runIds: string[],
    page: number,
    pageSize: number
  ): Promise<{ total: number; itemIds: string[] }> {
    const uniqueRunIds = [...new Set(runIds)];
    if (uniqueRunIds.length === 0) return { total: 0, itemIds: [] };
    const shared = this.database
      .select({
        itemId: schema.runItems.itemId,
      })
      .from(schema.runItems)
      .where(inArray(schema.runItems.runId, uniqueRunIds))
      .groupBy(schema.runItems.itemId)
      .having(
        and(
          eq(countDistinct(schema.runItems.runId), uniqueRunIds.length),
          eq(countDistinct(schema.runItems.itemDigest), 1)
        )
      )
      .as("shared_items");
    const [totalRow, rows] = await Promise.all([
      this.database
        .select({ value: count() })
        .from(shared)
        .then(([row]) => row),
      this.database
        .select({ itemId: shared.itemId })
        .from(shared)
        .orderBy(asc(shared.itemId))
        .limit(pageSize)
        .offset((page - 1) * pageSize),
    ]);
    return {
      total: totalRow?.value ?? 0,
      itemIds: rows.map(({ itemId }) => itemId),
    };
  }

  private async queryEvaluatorResults(evalId: string, itemIds?: string[]) {
    const resultCondition = itemIds
      ? and(
          eq(schema.evaluatorResults.evalId, evalId),
          inJsonArray(schema.evaluatorResults.itemId, itemIds)
        )
      : eq(schema.evaluatorResults.evalId, evalId);
    const scoreCondition = itemIds
      ? and(
          eq(schema.evalScores.evalId, evalId),
          inJsonArray(schema.evalScores.itemId, itemIds)
        )
      : eq(schema.evalScores.evalId, evalId);
    const [rows, scoreRows] = await Promise.all([
      this.database
        .select({
          itemId: schema.evaluatorResults.itemId,
          evaluatorName: schema.evaluatorResults.evaluatorName,
          evaluatorVersion: schema.evalEvaluators.evaluatorVersion,
          status: schema.evaluatorResults.status,
          message: schema.evaluatorResults.message,
          durationMs: schema.evaluatorResults.durationMs,
        })
        .from(schema.evaluatorResults)
        .innerJoin(
          schema.evalEvaluators,
          and(
            eq(schema.evalEvaluators.evalId, schema.evaluatorResults.evalId),
            eq(
              schema.evalEvaluators.evaluatorName,
              schema.evaluatorResults.evaluatorName
            )
          )
        )
        .where(resultCondition)
        .orderBy(
          asc(schema.evaluatorResults.itemId),
          asc(schema.evaluatorResults.evaluatorName)
        ),
      this.database
        .select()
        .from(schema.evalScores)
        .where(scoreCondition)
        .orderBy(asc(schema.evalScores.scoreKey)),
    ]);
    const scores = new Map<string, Record<string, number>>();
    for (const row of scoreRows) {
      const key = resultKey(row.itemId, row.evaluatorName);
      const values = scores.get(key) ?? {};
      values[row.scoreKey] = row.scoreValue;
      scores.set(key, values);
    }
    const grouped = new Map<string, EvaluatorResultCell[]>();
    for (const row of rows) {
      pushGrouped(grouped, row.itemId, {
        evaluatorName: row.evaluatorName,
        evaluatorVersion: row.evaluatorVersion,
        status: row.status,
        scores: scores.get(resultKey(row.itemId, row.evaluatorName)) ?? {},
        ...(row.message === null ? {} : { message: row.message }),
        ...(row.durationMs === null ? {} : { durationMs: row.durationMs }),
      });
    }
    return grouped;
  }
}

function pushGrouped<Key, Value>(map: Map<Key, Value[]>, key: Key, value: Value) {
  const values = map.get(key) ?? [];
  values.push(value);
  map.set(key, values);
}

function latestDate(...values: Array<Date | null | undefined>): Date {
  const dates = values.filter((value): value is Date => value instanceof Date);
  if (dates.length === 0) {
    throw new Error("latestDate requires at least one date");
  }
  return new Date(Math.max(...dates.map((value) => value.getTime())));
}

function resultKey(itemId: string, evaluatorName: string): string {
  return JSON.stringify([itemId, evaluatorName]);
}

function inJsonArray(column: AnySQLiteColumn, values: string[]) {
  // D1 permits 100 bound parameters per statement, so bind the bounded page
  // as one JSON value instead of expanding every item id into its own parameter.
  return sql`${column} in (select value from json_each(${JSON.stringify(values)}))`;
}

function commonItemMetrics(
  evaluations: EvalComparison["evaluations"]
): EvalComparison["itemMetrics"] {
  if (evaluations.length === 0) return [];
  const metricsByEvaluation = evaluations.map((evaluation) => {
    const metrics = new Map<string, EvalComparison["itemMetrics"][number]>();
    for (const item of evaluation.items) {
      for (const result of item.evaluatorResults) {
        for (const scoreKey of Object.keys(result.scores)) {
          const metric = {
            evaluatorName: result.evaluatorName,
            evaluatorVersion: result.evaluatorVersion,
            scoreKey,
          };
          metrics.set(metricIdentityKey(metric), metric);
        }
      }
    }
    return metrics;
  });
  return [...metricsByEvaluation[0]!.entries()]
    .filter(([key]) => metricsByEvaluation.every((metrics) => metrics.has(key)))
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([, metric]) => metric);
}
