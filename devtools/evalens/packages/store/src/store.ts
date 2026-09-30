import { EvalManifest as EvalManifestSchema } from "@evalens/core/evaluation";
import type { LoggerCreator } from "@evalens/core/logger";
import { RunManifest as RunManifestSchema } from "@evalens/core/run";
import { EvalId, RunId } from "@evalens/core/schemas";
import type {
  CreateEvaluationInput,
  CreateRunInput,
  EvalensStore,
  RunReaderContract,
} from "@evalens/core/store/contracts";
import type { MetadataWriter } from "./metadata";
import { EvalWriter } from "./evaluation";
import { keyspace } from "./keys";
import {
  EvaluationScopeRecord,
  ReindexMarker,
  type ReindexMarker as ReindexMarkerValue,
} from "./marker";
import { writeObject, type ObjectNamespace } from "./namespace";
import { ResultReader } from "./result-reader";
import { RunReader, RunWriter } from "./run";

export type WarningSink = (message: string, error: unknown) => void;

export type StoreOptions = {
  namespace: ObjectNamespace;
  metadataWriter: MetadataWriter;
  createLogger: LoggerCreator;
  createId?: () => string;
  warn?: WarningSink;
  dispose?: () => void | Promise<void>;
};

export class Store implements EvalensStore {
  private readonly results: ResultReader;
  private readonly warn: WarningSink;
  private readonly createId: () => string;
  readonly namespace: ObjectNamespace;
  readonly metadataWriter: MetadataWriter;
  readonly createLogger: LoggerCreator;
  private readonly disposeStore?: () => void | Promise<void>;

  constructor(options: StoreOptions) {
    this.namespace = options.namespace;
    this.metadataWriter = options.metadataWriter;
    this.createLogger = options.createLogger;
    this.disposeStore = options.dispose;
    this.results = new ResultReader(options.namespace);
    this.warn = options.warn ?? ((message, error) => console.warn(message, error));
    this.createId = options.createId ?? (() => Bun.randomUUIDv7());
  }

  async createRun(input: CreateRunInput): Promise<RunWriter> {
    const manifest = RunManifestSchema.parse({
      ...input,
      runId: RunId.parse(this.createId()),
      formatVersion: 2,
      createdAt: new Date(),
      status: "running",
    });
    const writer = new RunWriter(this, manifest);
    await writer.initialize();
    return writer;
  }

  openRun(experimentName: string, runId: string): RunReader {
    return this.results.openRun(experimentName, runId);
  }

  async createEvaluation(
    run: RunReaderContract,
    input: CreateEvaluationInput
  ): Promise<EvalWriter> {
    const runManifest = await run.readManifest();
    if (runManifest.status !== "finished") {
      throw new Error(
        `cannot create evaluation for run ${run.runId} with status ${runManifest.status}`
      );
    }
    const manifest = EvalManifestSchema.parse({
      ...input,
      evalId: EvalId.parse(this.createId()),
      formatVersion: 1,
      runId: run.runId,
      createdAt: new Date(),
      status: "running",
    });
    await this.writeEvaluationScope(
      EvaluationScopeRecord.parse({
        formatVersion: 1,
        experimentName: run.experimentName,
        runId: run.runId,
        evalId: manifest.evalId,
      })
    );
    const writer = new EvalWriter(this, run.experimentName, manifest);
    await writer.initialize();
    return writer;
  }

  async markExperimentDirty(experimentName: string, reason: string): Promise<void> {
    await this.writeMarker({ type: "experiment", experimentName }, reason);
  }

  async indexRun(
    experimentName: string,
    runId: string,
    operation: () => Promise<void>
  ): Promise<void> {
    await this.index({ type: "run", experimentName, runId }, operation);
  }

  async indexEval(
    experimentName: string,
    runId: string,
    evalId: string,
    operation: () => Promise<void>
  ): Promise<void> {
    await this.index({ type: "eval", experimentName, runId, evalId }, operation);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.disposeStore?.();
  }

  private async index(
    scope: ReindexMarkerValue["scope"],
    operation: () => Promise<void>
  ): Promise<void> {
    try {
      await operation();
    } catch (metadataError) {
      this.warn(`metadata update failed for ${scope.type} scope`, metadataError);
      const reason = errorString(metadataError);
      try {
        await this.writeMarker(scope, reason);
      } catch (markerError) {
        throw new AggregateError(
          [metadataError, markerError],
          `metadata update and reindex marker write failed for ${scope.type} scope`
        );
      }
    }
  }

  private async writeMarker(
    scope: ReindexMarkerValue["scope"],
    reason: string
  ): Promise<void> {
    const markerId = Bun.randomUUIDv7();
    const markerKey =
      scope.type === "experiment"
        ? keyspace.experimentMarker(scope.experimentName, markerId)
        : scope.type === "run"
          ? keyspace.runMarker(scope.experimentName, scope.runId, markerId)
          : keyspace.evalMarker(
              scope.experimentName,
              scope.runId,
              scope.evalId,
              markerId
            );
    await this.writeMarkerAt(markerKey, scope, reason);
  }

  private async writeEvaluationScope(scope: EvaluationScopeRecord): Promise<void> {
    await writeObject(
      this.namespace,
      keyspace.evaluationScope(scope.evalId),
      JSON.stringify(scope, null, 2)
    );
  }

  private async writeMarkerAt(
    markerKey: string,
    scope: ReindexMarkerValue["scope"],
    reason: string
  ): Promise<void> {
    const marker = ReindexMarker.parse({
      formatVersion: 1,
      detectedAt: new Date(),
      reason,
      scope,
    });
    await writeObject(this.namespace, markerKey, JSON.stringify(marker, null, 2));
  }
}

function errorString(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
