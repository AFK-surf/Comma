import { z } from "zod";

import { AdapterIdentities, type DeepReadonly } from "./adapter";

import { type Dataset, DatasetItem } from "./dataset";
import type { EvalensLogger } from "./logger";
import type { RunOutput, RunResult } from "./run";
import {
  Digest,
  EvalId,
  EvaluatorIdentities,
  Identifier,
  LifecycleStatus,
  NonEmptyScore,
  Params,
  RunId,
  Score,
  Timing,
} from "./schemas";
import type { EvalWriterContract, RunReaderContract } from "./store/contracts";
import { digestDatasetItem } from "./store/digest";
import { measure, type Awaitable } from "@evalens/utils";

const EvaluatorOutput = z
  .object({
    score: NonEmptyScore,
    explanation: z.string().optional(),
  })
  .strict();
export type EvaluatorOutput = z.infer<typeof EvaluatorOutput>;

export const EvalResult = z.discriminatedUnion("status", [
  EvaluatorOutput.extend({
    evaluator: Identifier,
    evaluatorVersion: Identifier,
    status: z.literal("completed"),
    timing: Timing,
  }).strict(),
  z
    .object({
      evaluator: Identifier,
      evaluatorVersion: Identifier,
      status: z.literal("error"),
      error: z.string(),
      timing: Timing,
    })
    .strict(),
  z
    .object({
      evaluator: Identifier,
      evaluatorVersion: Identifier,
      status: z.literal("skipped"),
      reason: z.string(),
    })
    .strict(),
]);
export type EvalResult = z.infer<typeof EvalResult>;

export const UPSTREAM_RUN_FAILED_REASON = "upstream run failed";

export type EvalContext<
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object = {},
> = {
  logger: EvalensLogger;
  params: Params;
  adapterConfig: DeepReadonly<AdapterConfig>;
};

export type Evaluator<
  Item extends DatasetItem<unknown, unknown>,
  R extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object = {},
  Name extends string = string,
  Version extends string = string,
  Output extends EvaluatorOutput = EvaluatorOutput,
> = {
  name: Name;
  version: Version;
  evaluate: (
    item: Item,
    runOutput: RunOutput<R>,
    context: EvalContext<Params, AdapterConfig>
  ) => Awaitable<Output>;
};

type EvaluatorReturn<EvaluatorDefinition> = EvaluatorDefinition extends {
  evaluate: (...args: infer _Args) => infer Output;
}
  ? Awaited<Output>
  : never;

type AggregationEntry<EvaluatorDefinition> = {
  itemId: string;
} & EvaluatorReturn<EvaluatorDefinition>;

export type AggregationResults<Evaluators extends readonly unknown[]> = {
  [
    EvaluatorDefinition in Evaluators[number] as EvaluatorDefinition extends {
      name: infer Name extends string;
    }
      ? Name
      : never
  ]: AggregationEntry<EvaluatorDefinition>[];
};

export type EvaluationDefinition<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>> = {},
  Evaluators extends readonly unknown[] = readonly Evaluator<Item, Result, Params>[],
  AdapterConfig extends object = {},
> = {
  evaluators: Evaluators &
    readonly Evaluator<NoInfer<Item>, NoInfer<Result>, Params, AdapterConfig>[];
  aggregator: {
    version: string;
    aggregate: (
      results: AggregationResults<Evaluators>
    ) => Awaitable<Record<string, number>>;
  };
};

export type EvaluationOptions<
  Item extends DatasetItem<unknown, unknown>,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object = {},
> = {
  run: RunReaderContract;
  dataset: Dataset<Item>;
  writer: EvalWriterContract;
  params: Params;
  adapterConfig: DeepReadonly<AdapterConfig>;
  concurrency?: number;
};

export const EvalManifest = z.object({
  formatVersion: z.literal(1),
  evalId: EvalId,
  runId: RunId,
  evaluators: EvaluatorIdentities,
  aggregatorVersion: Identifier,
  paramsDigest: Digest,
  adapters: AdapterIdentities,
  createdAt: z.coerce.date(),
  finishedAt: z.coerce.date().optional(),
  status: LifecycleStatus,
  error: z.string().optional(),
  params: Params,
});
export type EvalManifest = z.infer<typeof EvalManifest>;

export function validateEvaluationDefinition(definition: {
  evaluators: readonly { name: string; version: string }[];
  aggregator: { version: string };
}): void {
  if (definition.evaluators.length === 0) {
    throw new Error("experiment must define at least one evaluator");
  }

  const names = new Set<string>();
  for (const evaluator of definition.evaluators) {
    const name = Identifier.parse(evaluator.name);
    Identifier.parse(evaluator.version);
    if (names.has(name)) {
      throw new Error(`duplicate evaluator name: ${name}`);
    }
    names.add(name);
  }
  Identifier.parse(definition.aggregator.version);
}

export async function evaluateRunResult<
  Item extends DatasetItem<unknown, unknown>,
  R extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object,
>(
  evaluators: readonly Evaluator<Item, R, Params, AdapterConfig>[],
  item: Item,
  runResult: RunResult<R>,
  logger: EvalensLogger,
  params: Params,
  adapterConfig: DeepReadonly<AdapterConfig>
): Promise<EvalResult[]> {
  if (runResult.status === "error") {
    return evaluators.map((evaluator) => ({
      evaluator: evaluator.name,
      evaluatorVersion: evaluator.version,
      status: "skipped",
      reason: UPSTREAM_RUN_FAILED_REASON,
    }));
  }

  const { status: _status, timing: _timing, ...runOutput } = runResult;
  return Promise.all(
    evaluators.map(async (evaluator): Promise<EvalResult> => {
      const context: EvalContext<Params, AdapterConfig> = {
        logger: logger.child({ evaluator: evaluator.name }),
        params,
        adapterConfig,
      };
      const measured = await measure(() =>
        evaluator.evaluate(item, runOutput, context)
      );
      if (measured.status === "rejected") {
        const output = {
          evaluator: evaluator.name,
          evaluatorVersion: evaluator.version,
          status: "error" as const,
          error:
            measured.reason instanceof Error
              ? measured.reason.message
              : String(measured.reason),
          timing: measured.timing,
        };
        context.logger.error(output.error);
        return output;
      }

      try {
        const output = EvaluatorOutput.parse(measured.value);
        return {
          evaluator: evaluator.name,
          evaluatorVersion: evaluator.version,
          status: "completed",
          timing: measured.timing,
          ...output,
        };
      } catch (error) {
        const output = {
          evaluator: evaluator.name,
          evaluatorVersion: evaluator.version,
          status: "error" as const,
          error: error instanceof Error ? error.message : String(error),
          timing: measured.timing,
        };
        context.logger.error(output.error);
        return output;
      }
    })
  );
}

export async function executeEvaluation<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  Evaluators extends readonly unknown[],
  AdapterConfig extends object,
>(
  definition: EvaluationDefinition<Item, Result, Params, Evaluators, AdapterConfig>,
  options: EvaluationOptions<Item, Params, AdapterConfig>
) {
  const { run, dataset, writer, params, adapterConfig, concurrency = 1 } = options;
  const batchSize = Math.max(1, concurrency);
  const datasetItems = new Map<string, Item>();
  for (const item of dataset.items) {
    if (datasetItems.has(item.id)) {
      throw new Error(`evaluation dataset contains duplicate item: ${item.id}`);
    }
    datasetItems.set(item.id, item);
  }
  const runManifest = await run.readManifest();
  const datasetItemIds = dataset.items.map((item) => item.id);
  if (
    datasetItemIds.length !== runManifest.selectedItemIds.length ||
    datasetItemIds.some(
      (itemId, index) => itemId !== runManifest.selectedItemIds[index]
    )
  ) {
    throw new Error("evaluation dataset does not match the run selection");
  }

  const aggregationResults = Object.fromEntries(
    (definition.evaluators as readonly { name: string }[]).map((evaluator) => [
      evaluator.name,
      [],
    ])
  ) as unknown as AggregationResults<Evaluators>;
  const batch: Array<{ item: Item; runResult: RunResult<Result> }> = [];
  for await (const runItem of run.iterateItems<Result>()) {
    const item = datasetItems.get(runItem.itemId);
    if (!item) {
      throw new Error(`run item is missing from referenced dataset: ${runItem.itemId}`);
    }
    const itemDigest = digestDatasetItem(item);
    if (itemDigest !== runItem.itemDigest) {
      throw new Error(
        `run item digest does not match referenced dataset: ${runItem.itemId}`
      );
    }
    batch.push({ item, runResult: runItem.runResult });
    if (batch.length < batchSize) continue;

    addCompletedResults(
      aggregationResults,
      await evaluateBatch(definition, writer, batch.splice(0), params, adapterConfig)
    );
  }
  if (batch.length > 0) {
    addCompletedResults(
      aggregationResults,
      await evaluateBatch(definition, writer, batch, params, adapterConfig)
    );
  }

  let aggregatedEvalResults: Record<string, number>;
  try {
    aggregatedEvalResults = Score.parse(
      await definition.aggregator.aggregate(aggregationResults)
    );
  } catch (error) {
    await writer.fail(error instanceof Error ? error.message : String(error));
    throw error;
  }
  await writer.saveAggregate(aggregatedEvalResults);
  await writer.finish();
}

async function evaluateBatch<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  Evaluators extends readonly unknown[],
  AdapterConfig extends object,
>(
  definition: EvaluationDefinition<Item, Result, Params, Evaluators, AdapterConfig>,
  writer: EvalWriterContract,
  batch: Array<{ item: Item; runResult: RunResult<Result> }>,
  params: Params,
  adapterConfig: DeepReadonly<AdapterConfig>
) {
  return Promise.all(
    batch.map(async ({ item, runResult }) => {
      let itemEvalResults: EvalResult[];
      {
        await using loggerHandle = writer.createItemLogger(item.id);
        itemEvalResults = await evaluateRunResult(
          definition.evaluators,
          item,
          runResult,
          loggerHandle.logger,
          params,
          adapterConfig
        );
      }
      await writer.commitItem(item.id, itemEvalResults);
      return { itemId: item.id, results: itemEvalResults };
    })
  );
}

function addCompletedResults<Evaluators extends readonly unknown[]>(
  aggregationResults: AggregationResults<Evaluators>,
  items: { itemId: string; results: EvalResult[] }[]
): void {
  const mutableResults = aggregationResults as unknown as Record<
    string,
    { itemId: string; score: Record<string, number>; explanation?: string }[]
  >;
  for (const { itemId, results } of items) {
    for (const result of results) {
      if (result.status !== "completed") continue;
      const {
        evaluator,
        evaluatorVersion: _evaluatorVersion,
        status: _status,
        timing: _timing,
        ...output
      } = result;
      mutableResults[evaluator]?.push({ itemId, ...output });
    }
  }
}
