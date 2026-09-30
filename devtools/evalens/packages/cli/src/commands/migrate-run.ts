import path from "node:path";
import type { CommandModule } from "yargs";
import type { z } from "zod";

import {
  digestCanonicalJson,
  digestDatasetSelection,
  type EvalensStore,
  type EvalManifest,
  type EvalResult,
} from "@evalens/core";

import { loadEvalensConfig, type EvalensConfig } from "../config";
import { createStore } from "./execution-utils";

type MigrateRunArguments = {
  experiment: string;
  "from-run": string;
  "source-config": string;
  "target-config": string;
  eval?: string[];
  concurrency?: number;
};

export type MigrateRunOptions = {
  experimentName: string;
  sourceRunId: string;
  evalIds?: string[];
  sourceConfig: EvalensConfig;
  targetConfig: EvalensConfig;
  concurrency?: number;
};

export type MigrateRunBetweenStoresOptions = {
  experimentName: string;
  sourceRunId: string;
  evalIds?: string[];
  sourceStore: EvalensStore;
  targetStore: EvalensStore;
  concurrency?: number;
};

export type MigrateRunResult = {
  sourceRunId: string;
  runId: string;
  itemCount: number;
  evaluations: {
    sourceEvalId: string;
    evalId: string;
  }[];
};

export const migrateRunCommand: CommandModule<{}, MigrateRunArguments> = {
  command: "migrate <experiment>",
  describe: "Copy a complete run and selected evaluations into a remote Store",
  builder: (migrate) =>
    migrate
      .positional("experiment", { type: "string", demandOption: true })
      .option("from-run", {
        type: "string",
        demandOption: true,
        requiresArg: true,
        description: "The complete source run to migrate",
      })
      .option("source-config", {
        type: "string",
        demandOption: true,
        requiresArg: true,
        description: "Path to the source evalens.config.json",
      })
      .option("target-config", {
        type: "string",
        demandOption: true,
        requiresArg: true,
        description: "Path to the remote destination evalens.config.json",
      })
      .option("eval", {
        type: "array",
        string: true,
        description: "Evaluation ID to migrate; repeat for multiple evaluations",
      })
      .option("concurrency", {
        type: "number",
        description: "Maximum number of item copies in flight",
      }),
  handler: async (argv) => {
    const sourceConfigPath = path.resolve(argv["source-config"]);
    const targetConfigPath = path.resolve(argv["target-config"]);
    const result = await migrateRun({
      experimentName: argv.experiment,
      sourceRunId: argv["from-run"],
      ...(argv.eval ? { evalIds: argv.eval } : {}),
      sourceConfig: await loadEvalensConfig(sourceConfigPath),
      targetConfig: await loadEvalensConfig(targetConfigPath),
      ...(argv.concurrency === undefined ? {} : { concurrency: argv.concurrency }),
    });
    console.log(JSON.stringify(result));
  },
};

export async function migrateRun(
  options: MigrateRunOptions
): Promise<MigrateRunResult> {
  if (!("remote" in options.targetConfig)) {
    throw new Error("run migrate requires a remote target config");
  }
  await using sourceStore = await createStore(options.sourceConfig);
  await using targetStore = await createStore(options.targetConfig);
  return migrateRunBetweenStores({
    experimentName: options.experimentName,
    sourceRunId: options.sourceRunId,
    ...(options.evalIds ? { evalIds: options.evalIds } : {}),
    sourceStore,
    targetStore,
    concurrency: options.concurrency ?? options.targetConfig.concurrency,
  });
}

export async function migrateRunBetweenStores(
  options: MigrateRunBetweenStoresOptions
): Promise<MigrateRunResult> {
  const sourceRun = options.sourceStore.openRun(
    options.experimentName,
    options.sourceRunId
  );
  const concurrency = validateConcurrency(options.concurrency ?? 1);
  const sourceManifest = await sourceRun.readManifest();
  if (sourceManifest.experimentName !== options.experimentName) {
    throw new Error(
      `source run experiment mismatch: expected ${options.experimentName}, ` +
        `received ${sourceManifest.experimentName}`
    );
  }
  if (sourceManifest.status !== "finished" || !sourceManifest.finishedAt) {
    throw new Error(
      `source run ${sourceManifest.runId} must be finished before migration`
    );
  }
  if (digestCanonicalJson(sourceManifest.params) !== sourceManifest.paramsDigest) {
    throw new Error(`source run ${sourceManifest.runId} has a params digest mismatch`);
  }

  const itemDigests = new Map<string, string>();
  for await (const stored of sourceRun.iterateItemStates()) {
    if (itemDigests.has(stored.itemId)) {
      throw new Error(`source run contains duplicate item: ${stored.itemId}`);
    }
    if (stored.status !== "completed") {
      throw new Error(
        `source run item ${stored.itemId} has status ${stored.status}; ` +
          "only complete runs can be migrated"
      );
    }
    itemDigests.set(stored.itemId, stored.itemDigest);
  }

  const selectedItemIds = validateRunSelection(
    sourceManifest.runId,
    sourceManifest.datasetDigest,
    sourceManifest.datasetSelectionDigest,
    sourceManifest.targetItemCount,
    sourceManifest.selectedItemIds,
    [...itemDigests.keys()]
  );
  const evalIds = [...new Set(options.evalIds ?? [])];
  if (evalIds.length !== (options.evalIds ?? []).length) {
    throw new Error("evaluation IDs to migrate must be unique");
  }

  const evaluations = [];
  for (const evalId of evalIds) {
    const reader = sourceRun.openEval(evalId);
    const manifest = await reader.readManifest();
    validateEvalManifest(sourceManifest.runId, manifest);
    const aggregateScores = await reader.readAggregateScores();
    await forEachBatch(selectedItemIds, concurrency, async (itemId) =>
      validateEvalItem(manifest, itemId, await reader.readItemResults(itemId))
    );
    evaluations.push({ reader, manifest, aggregateScores });
  }

  let runId: string;
  {
    await using writer = await options.targetStore.createRun({
      sourceRunId: sourceManifest.runId,
      experimentName: sourceManifest.experimentName,
      description: sourceManifest.description,
      datasetName: sourceManifest.datasetName,
      datasetDigest: sourceManifest.datasetDigest,
      datasetSelectionDigest: sourceManifest.datasetSelectionDigest,
      selectedItemIds,
      targetItemCount: sourceManifest.targetItemCount,
      tags: sourceManifest.tags,
      params: sourceManifest.params,
      paramsDigest: sourceManifest.paramsDigest,
      adapters: sourceManifest.adapters,
    });
    runId = writer.runId;
    const migratedItemIds = new Set<string>();
    await forEachAsyncBatch(
      sourceRun.iterateItems<z.JSONType>(),
      concurrency,
      async (stored) => {
        const itemDigest = itemDigests.get(stored.itemId);
        if (!itemDigest) {
          throw new Error(
            `source run changed during migration; unexpected item ${stored.itemId}`
          );
        }
        if (migratedItemIds.has(stored.itemId)) {
          throw new Error(`source run contains duplicate item: ${stored.itemId}`);
        }
        if (
          stored.runResult.status !== "completed" ||
          stored.itemDigest !== itemDigest
        ) {
          throw new Error(`source run item changed during migration: ${stored.itemId}`);
        }
        migratedItemIds.add(stored.itemId);
        await retryMigrationWrite(() =>
          writer.commitItem(stored.itemId, stored.runResult, itemDigest)
        );
      }
    );
    if (migratedItemIds.size !== selectedItemIds.length) {
      throw new Error(
        `source run changed during migration: expected ${selectedItemIds.length} ` +
          `items, received ${migratedItemIds.size}`
      );
    }
    await retryMigrationWrite(() => writer.finish());
  }

  const targetRun = options.targetStore.openRun(options.experimentName, runId);
  const migratedEvaluations: MigrateRunResult["evaluations"] = [];
  for (const evaluation of evaluations) {
    await using writer = await options.targetStore.createEvaluation(targetRun, {
      evaluators: evaluation.manifest.evaluators,
      aggregatorVersion: evaluation.manifest.aggregatorVersion,
      paramsDigest: evaluation.manifest.paramsDigest,
      adapters: evaluation.manifest.adapters,
      params: evaluation.manifest.params,
    });
    await forEachBatch(selectedItemIds, concurrency, async (itemId) => {
      const results = await evaluation.reader.readItemResults(itemId);
      await retryMigrationWrite(() => writer.commitItem(itemId, results));
    });
    await retryMigrationWrite(() => writer.saveAggregate(evaluation.aggregateScores));
    await retryMigrationWrite(() => writer.finish());
    migratedEvaluations.push({
      sourceEvalId: evaluation.manifest.evalId,
      evalId: writer.evalId,
    });
  }

  return {
    sourceRunId: sourceManifest.runId,
    runId,
    itemCount: selectedItemIds.length,
    evaluations: migratedEvaluations,
  };
}

function validateConcurrency(value: number): number {
  if (!Number.isInteger(value) || value < 1) {
    throw new Error("run migrate concurrency must be a positive integer");
  }
  return value;
}

async function forEachBatch<T>(
  values: readonly T[],
  concurrency: number,
  operation: (value: T) => Promise<void> | void
): Promise<void> {
  for (let offset = 0; offset < values.length; offset += concurrency) {
    await Promise.all(values.slice(offset, offset + concurrency).map(operation));
  }
}

async function forEachAsyncBatch<T>(
  values: AsyncIterable<T>,
  concurrency: number,
  operation: (value: T) => Promise<void>
): Promise<void> {
  let batch: T[] = [];
  for await (const value of values) {
    batch.push(value);
    if (batch.length < concurrency) continue;
    await Promise.all(batch.map(operation));
    batch = [];
  }
  await Promise.all(batch.map(operation));
}

async function retryMigrationWrite(
  operation: () => Promise<void>,
  maxAttempts = 4
): Promise<void> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await operation();
      return;
    } catch (error) {
      lastError = error;
      if (!isRetryableMigrationError(error) || attempt === maxAttempts) break;
      await Bun.sleep(1_000 * 2 ** (attempt - 1));
    }
  }
  throw lastError;
}

function isRetryableMigrationError(error: unknown): boolean {
  const candidate = error as {
    code?: unknown;
    status?: unknown;
    message?: unknown;
  };
  const code = String(candidate?.code ?? "").toLowerCase();
  const message = String(candidate?.message ?? error).toLowerCase();
  const status = typeof candidate?.status === "number" ? candidate.status : undefined;
  return (
    /timeout|connectionclosed|connectionreset|networkingerror/.test(code) ||
    status === 408 ||
    status === 429 ||
    (status !== undefined && status >= 500) ||
    /timeout|timed out|connection reset|fetch failed|socket/.test(message)
  );
}

function validateRunSelection(
  runId: string,
  datasetDigest: string,
  datasetSelectionDigest: string,
  targetItemCount: number,
  manifestItemIds: string[],
  storedItemIds: string[]
): string[] {
  if (storedItemIds.length !== targetItemCount) {
    throw new Error(
      `source run ${runId} is incomplete: expected ${targetItemCount} items, ` +
        `received ${storedItemIds.length}`
    );
  }
  const storedIds = new Set(storedItemIds);
  const selectedItemIds = manifestItemIds;
  if (
    selectedItemIds.length !== targetItemCount ||
    new Set(selectedItemIds).size !== selectedItemIds.length
  ) {
    throw new Error(`source run ${runId} has an invalid selected item list`);
  }
  if (selectedItemIds.some((itemId) => !storedIds.has(itemId))) {
    throw new Error(
      `source run ${runId} selected item list does not match committed items`
    );
  }
  if (
    digestDatasetSelection(datasetDigest, selectedItemIds) !== datasetSelectionDigest
  ) {
    throw new Error(`source run ${runId} has a dataset selection digest mismatch`);
  }
  return selectedItemIds;
}

function validateEvalManifest(runId: string, manifest: EvalManifest): void {
  if (manifest.runId !== runId) {
    throw new Error(
      `source evaluation ${manifest.evalId} belongs to run ${manifest.runId}, ` +
        `not ${runId}`
    );
  }
  if (manifest.status !== "finished" || !manifest.finishedAt) {
    throw new Error(
      `source evaluation ${manifest.evalId} must be finished before migration`
    );
  }
  if (digestCanonicalJson(manifest.params) !== manifest.paramsDigest) {
    throw new Error(
      `source evaluation ${manifest.evalId} has a params digest mismatch`
    );
  }
}

function validateEvalItem(
  manifest: EvalManifest,
  itemId: string,
  results: EvalResult[]
): void {
  const expected = new Map(
    manifest.evaluators.map(({ name, version }) => [name, version])
  );
  if (results.length !== expected.size) {
    throw new Error(
      `source evaluation ${manifest.evalId} item ${itemId} has ` +
        `${results.length} results; expected ${expected.size}`
    );
  }
  for (const result of results) {
    const version = expected.get(result.evaluator);
    if (version !== result.evaluatorVersion) {
      throw new Error(
        `source evaluation ${manifest.evalId} item ${itemId} has an ` +
          `unexpected evaluator result: ${result.evaluator}@${result.evaluatorVersion}`
      );
    }
    expected.delete(result.evaluator);
  }
}
