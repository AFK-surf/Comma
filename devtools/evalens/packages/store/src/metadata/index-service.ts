import path from "node:path";
import { z } from "zod";

import { EvalResult } from "@evalens/core/evaluation";
import { RunItemReference } from "@evalens/core/run";
import { ItemId, Score, Timing } from "@evalens/core/schemas";
import { keyspace } from "../keys";
import {
  EvaluationScopeRecord,
  ReindexMarker,
  type ReindexMarkerScope,
} from "../marker";
import {
  type AggregateScoresMetadata,
  type EvalItemCommitMetadata,
  EvalManifestMetadata,
  MetadataRepairLeaseLostError,
  type MetadataRepairToken,
  type MetadataWriter,
  type RunItemCommitMetadata,
  RunManifestMetadata,
} from "./contracts";

export type ReindexScope = { type: "all" } | ReindexMarkerScope;

export interface ReindexObjectSource {
  list(prefix: string): AsyncIterable<string>;
  readJson(key: string): Promise<unknown>;
  exists(key: string): Promise<boolean>;
  delete(key: string): Promise<void>;
}

export interface IndexMetadataWriter extends MetadataWriter {
  beginReindex(scope: ReindexScope): Promise<MetadataRepairToken>;
  finishReindex(token: MetadataRepairToken): Promise<boolean>;
}

export type ReindexMarkerRecord = {
  key: string;
  marker: ReindexMarker;
};

type ReindexPlan = {
  runManifests: RunManifestMetadata[];
  runItems: RunItemCommitMetadata[];
  evalManifests: EvalManifestMetadata[];
  evalItems: EvalItemCommitMetadata[];
  aggregates: AggregateScoresMetadata[];
  markerKeys: string[];
};

const StoredRunResult = z.discriminatedUnion("status", [
  z.looseObject({
    status: z.literal("completed"),
    timing: Timing,
  }),
  z.looseObject({
    status: z.literal("error"),
    error: z.string(),
    timing: Timing,
  }),
]);

export class IndexService {
  private readonly reindexes = new Map<string, Promise<void>>();

  constructor(
    private readonly source: ReindexObjectSource,
    private readonly writer: IndexMetadataWriter
  ) {}

  async reindex(scope: ReindexScope): Promise<void> {
    const key = reindexScopeKey(scope);
    const pending = this.reindexes.get(key);
    if (pending) return pending;
    let operation: Promise<void>;
    operation = this.applyPlanAfterBuild(scope, false).finally(() => {
      if (this.reindexes.get(key) === operation) this.reindexes.delete(key);
    });
    this.reindexes.set(key, operation);
    return operation;
  }

  async bootstrap(): Promise<void> {
    const scope = { type: "all" } as const;
    await this.applyPlanAfterBuild(scope, true);
  }

  async repairMarkedScopes(scope: ReindexScope): Promise<void> {
    const markers = await this.findRelevantMarkers(scope);
    for (const dirtyScope of collapseReindexScopes(
      markers.map(({ marker }) => marker.scope)
    )) {
      await this.reindex(dirtyScope);
    }
  }

  async repairRunMarkers(runId: string): Promise<void> {
    const markers = await this.findRunMarkers(runId);
    for (const dirtyScope of collapseReindexScopes(
      markers.map(({ marker }) => marker.scope)
    )) {
      await this.reindex(dirtyScope);
    }
  }

  async findRunMarkers(runId: string): Promise<ReindexMarkerRecord[]> {
    return (await this.findRelevantMarkers({ type: "all" })).filter(({ marker }) => {
      const scope = marker.scope;
      return scope.type !== "experiment" && scope.runId === runId;
    });
  }

  async findEvaluationScopes(evalIds: string[]): Promise<EvaluationScopeRecord[]> {
    const scopes: EvaluationScopeRecord[] = [];
    for (const evalId of new Set(evalIds)) {
      const key = keyspace.evaluationScope(evalId);
      if (!(await this.source.exists(key))) continue;
      const scope = EvaluationScopeRecord.parse(await this.source.readJson(key));
      if (scope.evalId !== evalId) {
        throw new Error(`evaluation scope locator does not match eval id: ${evalId}`);
      }
      scopes.push(scope);
    }
    return scopes;
  }

  private async applyPlan(
    plan: ReindexPlan,
    repair: MetadataRepairToken
  ): Promise<void> {
    const options = { repair };
    for (const metadata of plan.runManifests) {
      await this.writer.upsertRunManifest(metadata, options);
    }
    for (const metadata of plan.runItems) {
      await this.writer.commitRunItem(metadata, options);
    }
    for (const metadata of plan.evalManifests) {
      await this.writer.upsertEvalManifest(metadata, options);
    }
    for (const metadata of plan.evalItems) {
      await this.writer.commitEvalItem(metadata, options);
    }
    for (const metadata of plan.aggregates) {
      await this.writer.replaceAggregateScores(metadata, options);
    }
  }

  private async applyPlanAfterBuild(
    scope: ReindexScope,
    allowRunning: boolean
  ): Promise<void> {
    // Validate before destructive replacement. Every normal writer advances an
    // overlapping persistent fence; only an untouched lease can publish and
    // clear the exact marker keys captured by its plan. A changed fence replays
    // from object storage instead of publishing stale repair writes.
    await this.buildPlan(scope, allowRunning);
    while (true) {
      const repair = await this.writer.beginReindex(scope);
      const plan = await this.buildPlan(scope, allowRunning);
      try {
        await this.applyPlan(plan, repair);
      } catch (error) {
        if (error instanceof MetadataRepairLeaseLostError) continue;
        throw error;
      }
      if (!(await this.writer.finishReindex(repair))) continue;
      for (const markerKey of plan.markerKeys) {
        await this.source.delete(markerKey);
      }
      return;
    }
  }

  async findRelevantMarkers(scope: ReindexScope): Promise<ReindexMarkerRecord[]> {
    const keys = new Set<string>();
    if (scope.type === "all") {
      await this.addMarkerKeys(keys, keyspace.reindexMarkers());
    } else if (scope.type === "experiment") {
      await this.addMarkerKeys(keys, keyspace.experimentMarkers(scope.experimentName));
    } else if (scope.type === "run") {
      await this.addMarkerKeys(
        keys,
        keyspace.experimentMarkerDirectory(scope.experimentName)
      );
      await this.addMarkerKeys(
        keys,
        path.posix.dirname(
          keyspace.runMarkerDirectory(scope.experimentName, scope.runId)
        )
      );
    } else {
      await this.addMarkerKeys(
        keys,
        keyspace.experimentMarkerDirectory(scope.experimentName)
      );
      await this.addMarkerKeys(
        keys,
        keyspace.runMarkerDirectory(scope.experimentName, scope.runId)
      );
      await this.addMarkerKeys(
        keys,
        keyspace.evalMarkerDirectory(scope.experimentName, scope.runId, scope.evalId)
      );
    }

    const records: ReindexMarkerRecord[] = [];
    for (const key of [...keys].sort()) {
      records.push({
        key,
        marker: ReindexMarker.parse(await this.source.readJson(key)),
      });
    }
    return records;
  }

  private async buildPlan(
    scope: ReindexScope,
    allowRunning: boolean
  ): Promise<ReindexPlan> {
    const plan: ReindexPlan = {
      runManifests: [],
      runItems: [],
      evalManifests: [],
      evalItems: [],
      aggregates: [],
      markerKeys: await this.findCoveredMarkerKeys(scope),
    };

    await this.appendRunMetadata(
      plan,
      await this.findRunManifestKeys(scope),
      allowRunning
    );
    await this.appendEvalMetadata(
      plan,
      await this.findEvalManifestKeys(scope),
      allowRunning
    );
    return plan;
  }

  private async appendRunMetadata(
    plan: ReindexPlan,
    manifestKeys: string[],
    allowRunning: boolean
  ): Promise<void> {
    for (const manifestKey of manifestKeys) {
      const manifest = RunManifestMetadata.parse(
        await this.source.readJson(manifestKey)
      );
      if (!allowRunning) assertNotRunning("run", manifest.runId, manifest.status);
      plan.runManifests.push(RunManifestMetadata.parse(manifest));

      const itemsPrefix = keyspace.runItems(manifest.experimentName, manifest.runId);
      for await (const key of this.source.list(itemsPrefix)) {
        if (!key.endsWith("/item.json")) continue;
        const reference = RunItemReference.parse(await this.source.readJson(key));
        const keyItemId = ItemId.parse(reference.itemId);
        const itemDirectory = path.posix.basename(path.posix.dirname(key));
        if (keyItemId !== itemDirectory) {
          throw new Error(
            `run item id does not match its object key: ${reference.itemId}`
          );
        }
        const result = StoredRunResult.parse(
          await this.source.readJson(
            path.posix.join(path.posix.dirname(key), "run_result.json")
          )
        );
        plan.runItems.push(
          result.status === "error"
            ? {
                runId: manifest.runId,
                ...reference,
                status: result.status,
                error: result.error,
                timing: result.timing,
              }
            : {
                runId: manifest.runId,
                ...reference,
                status: result.status,
                timing: result.timing,
              }
        );
      }
    }
  }

  private async appendEvalMetadata(
    plan: ReindexPlan,
    manifestKeys: string[],
    allowRunning: boolean
  ): Promise<void> {
    for (const manifestKey of manifestKeys) {
      const manifest = EvalManifestMetadata.parse(
        await this.source.readJson(manifestKey)
      );
      if (!allowRunning) {
        assertNotRunning("evaluation", manifest.evalId, manifest.status);
      }
      plan.evalManifests.push(EvalManifestMetadata.parse(manifest));

      const experimentName = experimentNameFromKey(manifestKey);
      const itemsPrefix = keyspace.evalItems(
        experimentName,
        manifest.runId,
        manifest.evalId
      );
      for await (const key of this.source.list(itemsPrefix)) {
        if (!key.endsWith("/eval_results.json")) continue;
        const itemDirectory = path.posix.basename(path.posix.dirname(key));
        const itemId = ItemId.parse(itemDirectory);
        const results = EvalResult.array()
          .min(1)
          .parse(await this.source.readJson(key));
        plan.evalItems.push({
          evalId: manifest.evalId,
          runId: manifest.runId,
          itemId,
          results: results.map((result) => {
            if (result.status === "completed") {
              return {
                evaluatorName: result.evaluator,
                status: result.status,
                score: result.score,
                explanation: result.explanation,
                timing: result.timing,
              };
            }
            if (result.status === "error") {
              return {
                evaluatorName: result.evaluator,
                status: result.status,
                error: result.error,
                timing: result.timing,
              };
            }
            return {
              evaluatorName: result.evaluator,
              status: result.status,
              reason: result.reason,
            };
          }),
        });
      }

      const aggregateKey = path.posix.join(
        keyspace.eval(experimentName, manifest.runId, manifest.evalId),
        "aggregated_eval_results.json"
      );
      if (await this.source.exists(aggregateKey)) {
        plan.aggregates.push({
          evalId: manifest.evalId,
          scores: Score.parse(await this.source.readJson(aggregateKey)),
        });
      }
    }
  }

  private async findRunManifestKeys(scope: ReindexScope): Promise<string[]> {
    if (scope.type === "eval") return [];
    if (scope.type === "run") {
      const key = keyspace.runManifest(scope.experimentName, scope.runId);
      if (!(await this.source.exists(key))) {
        throw new Error(`run manifest does not exist: ${scope.runId}`);
      }
      return [key];
    }
    const prefix =
      scope.type === "all" ? "experiments" : keyspace.experiment(scope.experimentName);
    return this.findKeys(prefix, isRunManifestKey);
  }

  private async findEvalManifestKeys(scope: ReindexScope): Promise<string[]> {
    if (scope.type === "eval") {
      const key = keyspace.evalManifest(
        scope.experimentName,
        scope.runId,
        scope.evalId
      );
      if (!(await this.source.exists(key))) {
        throw new Error(`evaluation manifest does not exist: ${scope.evalId}`);
      }
      return [key];
    }
    const prefix =
      scope.type === "all"
        ? "experiments"
        : scope.type === "experiment"
          ? keyspace.experiment(scope.experimentName)
          : keyspace.run(scope.experimentName, scope.runId);
    return this.findKeys(prefix, isEvalManifestKey);
  }

  private async findCoveredMarkerKeys(scope: ReindexScope): Promise<string[]> {
    const prefix =
      scope.type === "all"
        ? keyspace.reindexMarkers()
        : scope.type === "experiment"
          ? keyspace.experimentMarkers(scope.experimentName)
          : scope.type === "run"
            ? path.posix.dirname(
                keyspace.runMarkerDirectory(scope.experimentName, scope.runId)
              )
            : keyspace.evalMarkerDirectory(
                scope.experimentName,
                scope.runId,
                scope.evalId
              );
    return this.findKeys(prefix, isMarkerKey);
  }

  private async findKeys(
    prefix: string,
    predicate: (key: string) => boolean
  ): Promise<string[]> {
    const keys: string[] = [];
    for await (const key of this.source.list(prefix)) {
      if (predicate(key)) keys.push(key);
    }
    return keys.sort();
  }

  private async addMarkerKeys(keys: Set<string>, prefix: string): Promise<void> {
    for (const key of await this.findKeys(prefix, isMarkerKey)) keys.add(key);
  }
}

export function collapseReindexScopes(
  scopes: ReindexMarkerScope[]
): ReindexMarkerScope[] {
  const experimentScopes = new Set(
    scopes
      .filter((scope) => scope.type === "experiment")
      .map((scope) => scope.experimentName)
  );
  const runScopes = new Set(
    scopes
      .filter((scope) => scope.type === "run")
      .map((scope) => JSON.stringify([scope.experimentName, scope.runId]))
  );
  const result = new Map<string, ReindexMarkerScope>();
  for (const scope of scopes) {
    if (scope.type !== "experiment" && experimentScopes.has(scope.experimentName)) {
      continue;
    }
    if (
      scope.type === "eval" &&
      runScopes.has(JSON.stringify([scope.experimentName, scope.runId]))
    ) {
      continue;
    }
    result.set(reindexScopeKey(scope), scope);
  }
  return [...result.values()];
}

export function reindexScopeKey(scope: ReindexScope): string {
  if (scope.type === "all") return "all";
  if (scope.type === "experiment") return `experiment:${scope.experimentName}`;
  if (scope.type === "run") return `run:${scope.experimentName}:${scope.runId}`;
  return `eval:${scope.experimentName}:${scope.runId}:${scope.evalId}`;
}

function isRunManifestKey(key: string): boolean {
  return /^experiments\/[^/]+\/runs\/[^/]+\/manifest\.json$/.test(key);
}

function isEvalManifestKey(key: string): boolean {
  return /^experiments\/[^/]+\/runs\/[^/]+\/evals\/[^/]+\/manifest\.json$/.test(key);
}

function isMarkerKey(key: string): boolean {
  return /^marker(?:-[^/]+)?\.json$/.test(path.posix.basename(key));
}

function experimentNameFromKey(key: string): string {
  const [, experimentName] = key.split("/");
  if (!experimentName) throw new Error(`invalid experiment object key: ${key}`);
  return experimentName;
}

function assertNotRunning(
  kind: "run" | "evaluation",
  id: string,
  status: "running" | "finished" | "error"
): void {
  if (status === "running") throw new Error(`cannot reindex running ${kind}: ${id}`);
}
