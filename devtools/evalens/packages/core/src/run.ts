import type { Archive } from "bun";
import { z } from "zod";

import { AdapterIdentities, type DeepReadonly } from "./adapter";

import {
  type Dataset,
  type DatasetItem,
  type DatasetSource,
  DatasetItem as DatasetItemSchema,
} from "./dataset";
import type { EvalensLogger } from "./logger";
import type { Trajectory } from "./message";
import {
  DatasetName,
  Digest,
  ExperimentName,
  ItemId,
  LifecycleStatus,
  Params,
  RunId,
  Tag,
  Tags,
  type Timing,
} from "./schemas";
import type { RunWriterContract } from "./store/contracts";
import {
  digestDataset,
  digestDatasetItem,
  digestDatasetSelection,
  type ItemDigest,
} from "./store/digest";
import { clamp, measure, type Awaitable } from "@evalens/utils";

export type RunOutput<T extends z.JSONType> = {
  result: T;
  artifacts?: Archive;
  trajectories: Trajectory[];
};

type CompletedRunResult<T extends z.JSONType> = RunOutput<T> & {
  status: "completed";
  timing: Timing;
};

type ErrorRunResult = {
  status: "error";
  error: string;
  timing: Timing;
};

export type RunResult<T extends z.JSONType> = CompletedRunResult<T> | ErrorRunResult;

export type RunContext<
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object = {},
> = {
  /** the unique id of this run */
  id: string;
  /** the parameters passed to the run */
  params: Params;
  /** the logger for this dataset item */
  logger: EvalensLogger;
  /** parsed environment configuration for declared run adapters */
  adapterConfig: DeepReadonly<AdapterConfig>;
};

export const RunManifest = z
  .object({
    formatVersion: z.literal(2),
    runId: RunId,
    sourceRunId: RunId.optional(),
    experimentName: ExperimentName,
    description: z.string().optional(),
    datasetName: DatasetName,
    datasetDigest: Digest,
    datasetSelectionDigest: Digest,
    selectedItemIds: z.array(ItemId).min(1),
    targetItemCount: z.number().int().positive(),
    createdAt: z.coerce.date(),
    finishedAt: z.coerce.date().optional(),
    status: LifecycleStatus,
    tags: Tags,
    params: Params,
    paramsDigest: Digest,
    adapters: AdapterIdentities,
  })
  .superRefine(({ selectedItemIds, targetItemCount }, context) => {
    if (new Set(selectedItemIds).size !== selectedItemIds.length) {
      context.addIssue({
        code: "custom",
        path: ["selectedItemIds"],
        message: "selected item ids must be unique",
      });
    }
    if (selectedItemIds.length !== targetItemCount) {
      context.addIssue({
        code: "custom",
        path: ["targetItemCount"],
        message: "target item count must match selected item ids",
      });
    }
  });
export type RunManifest = z.infer<typeof RunManifest>;

export const RunItemReference = z
  .object({
    itemId: ItemId,
    itemDigest: Digest,
  })
  .strict();
export type RunItemReference = z.infer<typeof RunItemReference>;

export type RunDefinition<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>> = {},
  AdapterConfig extends object = {},
> = {
  name: string;
  description?: string;
  metadata: {
    tags: string[];
  };
  datasetLoader: (
    source: DatasetSource | undefined,
    params: Params
  ) => Awaitable<Dataset<Item>>;
  runItem: (
    item: Item,
    context: RunContext<Params, AdapterConfig>
  ) => Awaitable<RunOutput<Result>>;
};

export type RunOptions<
  Item extends DatasetItem<unknown, unknown>,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object = {},
> = {
  writer: RunWriterContract;
  dataset: Dataset<Item>;
  itemDigests: ReadonlyMap<string, string>;
  params: Params;
  adapterConfig: DeepReadonly<AdapterConfig>;
  concurrency?: number;
  retry?: RunRetryOptions;
};

export type RunRetryOptions = {
  maxRetries: number;
  initialDelayMs: number;
  maxDelayMs: number;
  multiplier: number;
};

export const DEFAULT_RUN_RETRY_OPTIONS: RunRetryOptions = {
  maxRetries: 3,
  initialDelayMs: 5_000,
  maxDelayMs: 60_000,
  multiplier: 2,
};

export async function prepareRun<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object,
>(
  definition: RunDefinition<Item, Result, Params, AdapterConfig>,
  options: {
    filter?: string[];
    datasetSource?: DatasetSource;
    params: Params;
  }
): Promise<{
  dataset: Dataset<Item>;
  tags: string[];
  itemDigests: ReadonlyMap<string, string>;
  datasetDigest: string;
  datasetSelectionDigest: string;
}> {
  const tags = validateTags(definition.metadata.tags);
  const loadedDataset = await definition.datasetLoader(
    options.datasetSource,
    options.params
  );
  if (loadedDataset.items.length === 0) {
    throw new Error("dataset must contain at least one item");
  }

  validateRunItems(loadedDataset.items);
  const allDigestEntries: ItemDigest[] = loadedDataset.items.map((item) => ({
    itemId: item.id,
    itemDigest: digestDatasetItem(item),
  }));
  const allItemDigests = new Map(
    allDigestEntries.map(({ itemId, itemDigest }) => [itemId, itemDigest])
  );
  const datasetDigest = loadedDataset.digest ?? digestDataset(allDigestEntries);

  let items = loadedDataset.items;
  if (options.filter !== undefined) {
    if (options.filter.length === 0) {
      throw new Error("run filter must contain at least one item id");
    }
    const filterIds = [...new Set(options.filter.map((id) => ItemId.parse(id)))];
    const datasetIds = new Set(loadedDataset.items.map((item) => item.id));
    const missingIds = filterIds.filter((id) => !datasetIds.has(id));
    if (missingIds.length > 0) {
      throw new Error(`run filter contains unknown item ids: ${missingIds.join(", ")}`);
    }
    const selectedIds = new Set(filterIds);
    items = loadedDataset.items.filter((item) => selectedIds.has(item.id));
  }

  const digestEntries: ItemDigest[] = items.map((item) => ({
    itemId: item.id,
    itemDigest: allItemDigests.get(item.id) ?? digestDatasetItem(item),
  }));
  return {
    dataset: { ...loadedDataset, items },
    tags,
    itemDigests: new Map(
      digestEntries.map(({ itemId, itemDigest }) => [itemId, itemDigest])
    ),
    datasetDigest,
    datasetSelectionDigest: digestDatasetSelection(
      datasetDigest,
      digestEntries.map(({ itemId }) => itemId)
    ),
  };
}

export async function executeRun<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  Params extends Readonly<Record<string, z.JSONType>>,
  AdapterConfig extends object,
>(
  definition: RunDefinition<Item, Result, Params, AdapterConfig>,
  options: RunOptions<Item, Params, AdapterConfig>
) {
  const {
    writer,
    dataset,
    itemDigests,
    params,
    adapterConfig,
    concurrency = 1,
    retry = DEFAULT_RUN_RETRY_OPTIONS,
  } = options;

  const items = [...dataset.items];
  let completedItemCount = 0;
  let errorItemCount = 0;
  while (items.length > 0) {
    await Promise.all(
      items.splice(0, clamp(concurrency, 1, items.length)).map(async (item) => {
        let runResult: RunResult<Result>;
        {
          await using loggerHandle = writer.createItemLogger(item.id);
          const measured = await measure(() =>
            runItemWithRetry(
              () =>
                definition.runItem(item, {
                  id: writer.runId,
                  logger: loggerHandle.logger,
                  params,
                  adapterConfig,
                }),
              retry,
              (attempt, delayMs, error) => {
                loggerHandle.logger.warn(
                  {
                    attempt,
                    maxRetries: retry.maxRetries,
                    delayMs,
                    error: error instanceof Error ? error.message : String(error),
                  },
                  "run item failed; retrying with a fresh attempt"
                );
              }
            )
          );
          if (measured.status === "fulfilled") {
            completedItemCount += 1;
            runResult = {
              ...measured.value,
              status: "completed",
              timing: measured.timing,
            };
          } else {
            errorItemCount += 1;
            runResult = {
              status: "error",
              error:
                measured.reason instanceof Error
                  ? measured.reason.message
                  : String(measured.reason),
              timing: measured.timing,
            };
          }
        }

        const itemDigest = itemDigests.get(item.id);
        if (itemDigest === undefined) {
          throw new Error(`missing preflight digest for dataset item: ${item.id}`);
        }
        await writer.commitItem(item.id, runResult, itemDigest);
      })
    );
  }

  await writer.finish();
  return { completedItemCount, errorItemCount };
}

async function runItemWithRetry<T>(
  operation: () => Awaitable<T>,
  options: RunRetryOptions,
  onRetry: (attempt: number, delayMs: number, error: unknown) => void
): Promise<T> {
  let retryCount = 0;
  while (true) {
    try {
      return await operation();
    } catch (error) {
      if (!isRetryableRunItemError(error) || retryCount >= options.maxRetries) {
        throw error;
      }
      const delayMs = Math.min(
        options.maxDelayMs,
        Math.round(options.initialDelayMs * options.multiplier ** retryCount)
      );
      retryCount += 1;
      onRetry(retryCount, delayMs, error);
      await Bun.sleep(delayMs);
    }
  }
}

export function isRetryableRunItemError(error: unknown): boolean {
  if (error instanceof AggregateError) {
    return error.errors.length > 0 && error.errors.every(isRetryableRunItemError);
  }
  if (!(error instanceof Error)) return false;
  const code =
    "code" in error && typeof error.code === "string" ? error.code.toUpperCase() : "";
  if (
    [
      "ECONNREFUSED",
      "ECONNRESET",
      "ECONNABORTED",
      "EHOSTUNREACH",
      "ENETDOWN",
      "ENETUNREACH",
      "EPIPE",
      "UND_ERR_CONNECT_TIMEOUT",
      "UND_ERR_SOCKET",
    ].includes(code)
  ) {
    return true;
  }
  const message = error.message.toLowerCase();
  if (
    message.includes("fetch failed") ||
    message.includes("connection refused") ||
    message.includes("connection reset") ||
    message.includes("socket hang up") ||
    message.includes("broken pipe")
  ) {
    return true;
  }
  if (
    message.includes("salix api") &&
    (message.includes("returned 502") ||
      message.includes("returned 503") ||
      message.includes("returned 504"))
  ) {
    return true;
  }
  return error.cause !== undefined && isRetryableRunItemError(error.cause);
}

function validateTags(tags: readonly string[]): string[] {
  const uniqueTags = new Set<string>();
  for (const tag of tags) {
    Tag.parse(tag);
    uniqueTags.add(tag);
  }
  return [...uniqueTags];
}

function validateRunItems(items: readonly DatasetItem<unknown, unknown>[]): void {
  const ids = new Set<string>();
  for (const item of items) {
    DatasetItemSchema.parse(item);
    if (ids.has(item.id)) {
      throw new Error(`duplicate dataset item id: ${item.id}`);
    }
    ids.add(item.id);
  }
}
