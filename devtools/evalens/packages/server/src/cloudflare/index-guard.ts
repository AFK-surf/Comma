import {
  collapseReindexScopes,
  reindexScopeKey,
  type IndexService,
  type ReindexScope,
} from "@evalens/store/metadata/index-service";
import * as schema from "@evalens/store/metadata/schema";
import { METADATA_SCHEMA_VERSION } from "@evalens/store/metadata/version";
import { eq, inArray } from "drizzle-orm";
import { drizzle, type DrizzleD1Database } from "drizzle-orm/d1";

import type { QueryIndexGuard } from "../contracts";

export class ReindexScheduler {
  private readonly pending = new Set<string>();

  constructor(
    private readonly indexService: IndexService,
    private readonly scheduleBackground: (operation: Promise<void>) => void,
    private readonly onError: (scope: ReindexScope, error: unknown) => void = (
      scope,
      error
    ) => console.error(`reindex failed for ${scope.type} scope`, error)
  ) {}

  schedule(scope: ReindexScope): void {
    const key = reindexScopeKey(scope);
    if (this.pending.has(key)) return;
    this.pending.add(key);
    const operation = this.indexService
      .reindex(scope)
      .catch((error) => this.onError(scope, error))
      .finally(() => this.pending.delete(key));
    this.scheduleBackground(operation);
  }

  scheduleBootstrap(): void {
    const key = "bootstrap";
    if (this.pending.has(key)) return;
    this.pending.add(key);
    const operation = this.indexService
      .bootstrap()
      .catch((error) => this.onError({ type: "all" }, error))
      .finally(() => this.pending.delete(key));
    this.scheduleBackground(operation);
  }
}

export class CloudflareIndexGuard implements QueryIndexGuard {
  private readonly database: DrizzleD1Database<typeof schema>;

  constructor(
    database: D1Database,
    private readonly indexService: IndexService,
    private readonly scheduler: ReindexScheduler
  ) {
    this.database = drizzle(database, { schema });
  }

  async ensureAll(): Promise<boolean> {
    if (!(await this.isGlobalIndexReady())) {
      this.scheduler.scheduleBootstrap();
      return false;
    }
    return this.ensureScope({ type: "all" });
  }

  async ensureExperiment(experimentName: string): Promise<boolean> {
    if (!(await this.isGlobalIndexReady())) {
      this.scheduler.scheduleBootstrap();
      return false;
    }
    return this.ensureScope({ type: "experiment", experimentName });
  }

  async ensureRun(runId: string): Promise<boolean> {
    if (!(await this.isGlobalIndexReady())) {
      this.scheduler.scheduleBootstrap();
      return false;
    }
    const row = await this.database
      .select({ experimentName: schema.runs.experimentName })
      .from(schema.runs)
      .where(eq(schema.runs.runId, runId))
      .get();
    if (!row) {
      const markers = await this.indexService.findRunMarkers(runId);
      for (const dirtyScope of collapseReindexScopes(
        markers.map(({ marker }) => marker.scope)
      )) {
        this.scheduler.schedule(dirtyScope);
      }
      return markers.length === 0;
    }
    return this.ensureScope({
      type: "run",
      experimentName: row.experimentName,
      runId,
    });
  }

  async ensureEvaluations(evalIds: string[]): Promise<boolean> {
    if (!(await this.isGlobalIndexReady())) {
      this.scheduler.scheduleBootstrap();
      return false;
    }
    const uniqueIds = [...new Set(evalIds)];
    if (uniqueIds.length === 0) return true;
    const rows = await this.database
      .select({
        evalId: schema.evals.evalId,
        runId: schema.evals.runId,
        experimentName: schema.runs.experimentName,
      })
      .from(schema.evals)
      .innerJoin(schema.runs, eq(schema.runs.runId, schema.evals.runId))
      .where(inArray(schema.evals.evalId, uniqueIds));
    const indexedIds = new Set(rows.map(({ evalId }) => evalId));
    const locatedScopes = await this.indexService.findEvaluationScopes(
      uniqueIds.filter((evalId) => !indexedIds.has(evalId))
    );
    const results = await Promise.all(
      [...rows, ...locatedScopes].map(({ experimentName, runId, evalId }) =>
        this.ensureScope({ type: "eval", experimentName, runId, evalId })
      )
    );
    return results.every(Boolean);
  }

  private async ensureScope(scope: ReindexScope): Promise<boolean> {
    const markers = await this.indexService.findRelevantMarkers(scope);
    if (markers.length === 0) return true;
    for (const dirtyScope of collapseReindexScopes(
      markers.map(({ marker }) => marker.scope)
    )) {
      this.scheduler.schedule(dirtyScope);
    }
    return false;
  }

  private async isGlobalIndexReady(): Promise<boolean> {
    const row = await this.database
      .select({
        schemaVersion: schema.indexMetadata.schemaVersion,
        state: schema.indexMetadata.state,
      })
      .from(schema.indexMetadata)
      .where(eq(schema.indexMetadata.id, 1))
      .get();
    return row?.schemaVersion === METADATA_SCHEMA_VERSION && row.state === "ready";
  }
}
