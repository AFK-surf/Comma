import path from "node:path";
import { mkdir } from "node:fs/promises";

import {
  type EvalCatalogEntry,
  type EvalFilters,
  type Page,
  type QueryService,
  type RunFilters,
  type RunSummary,
} from "@evalens/core";

import { IndexService } from "../metadata/index-service";
import { LocalIndexGuard } from "./index-guard";
import { LocalObjectNamespace } from "./object-namespace";
import { SqliteMetadataWriter } from "./sqlite-metadata-writer";
import { SqliteQueryService } from "./sqlite-query-service";

export class LocalQueryNotReadyError extends Error {
  readonly retryable = true;

  constructor(message = "result index is rebuilding") {
    super(message);
    this.name = "LocalQueryNotReadyError";
  }
}

export class LocalQueryRuntime {
  constructor(
    private readonly writer: SqliteMetadataWriter,
    readonly queryService: QueryService,
    readonly indexGuard: LocalIndexGuard
  ) {}

  async listRuns(filters: RunFilters): Promise<Page<RunSummary>> {
    const ready = filters.experimentName
      ? await this.indexGuard.ensureExperiment(filters.experimentName)
      : await this.indexGuard.ensureAll();
    ensureReady(ready);
    return this.queryService.listRuns(filters);
  }

  async getRun(runId: string): Promise<RunSummary | null> {
    ensureReady(await this.indexGuard.ensureRun(runId));
    return this.queryService.getRun(runId);
  }

  async listEvaluations(filters: EvalFilters): Promise<Page<EvalCatalogEntry>> {
    const ready = filters.runId
      ? await this.indexGuard.ensureRun(filters.runId)
      : filters.experimentName
        ? await this.indexGuard.ensureExperiment(filters.experimentName)
        : await this.indexGuard.ensureAll();
    ensureReady(ready);
    return this.queryService.listEvaluations(filters);
  }

  async getEvaluation(evalId: string): Promise<EvalCatalogEntry | null> {
    ensureReady(await this.indexGuard.ensureEvaluations([evalId]));
    return this.queryService.getEvaluation(evalId);
  }

  async [Symbol.asyncDispose]() {
    this.writer.database.close();
  }
}

export async function createLocalQueryRuntime(
  outputDir: string,
  options: {
    bootstrap?: boolean;
    warn?: (message: string, error: unknown) => void;
  } = {}
): Promise<LocalQueryRuntime> {
  const resolvedOutputDir = path.resolve(outputDir);
  const metadataDir = path.join(resolvedOutputDir, ".evalens");
  let writer: SqliteMetadataWriter | undefined;
  try {
    await mkdir(metadataDir, { recursive: true });
    writer = SqliteMetadataWriter.open(path.join(metadataDir, "index.sqlite"));
    const indexService = new IndexService(
      new LocalObjectNamespace(resolvedOutputDir),
      writer
    );
    if (options.bootstrap && writer.getIndexState() !== "ready") {
      await indexService.bootstrap();
    }
    return new LocalQueryRuntime(
      writer,
      new SqliteQueryService(writer.database),
      new LocalIndexGuard(writer, indexService, options.warn)
    );
  } catch (error) {
    writer?.database.close();
    throw error;
  }
}

function ensureReady(ready: boolean) {
  if (!ready) throw new LocalQueryNotReadyError();
}
