import path from "node:path";
import type { CommandModule } from "yargs";
import { z } from "zod";

import { adapterIdentities, selectAdapterConfig } from "@evalens/adapters/config";
import {
  ItemId,
  Params,
  digestCanonicalJson,
  digestDatasetSelection,
  executeEvaluation,
  executeRun,
  prepareRun,
  type AdapterConfigFor,
  type AdapterNames,
  type DatasetItem,
  type Experiment,
  type ParamsSchema,
  type RunResult,
} from "@evalens/core";

import {
  loadEvalensConfig,
  resolveRunRetryOptions,
  type EvalensConfig,
} from "../config";
import { createDatasetSource } from "../dataset";
import {
  createStore,
  evaluatorIdentities,
  loadExperiment,
  parseCliParams,
  parseParams,
  phaseAdapters,
  readCliParamsFile,
} from "./execution-utils";

const RawRerunParams = z.object({ eval: Params.default({}) }).strict();
const RerunItemIds = z.array(ItemId).min(1);

export type RerunCommandOptions<EvalParamsSchema extends ParamsSchema> = {
  sourceRunId: string;
  rerunItemIds?: string[];
  params?: z.input<EvalParamsSchema>;
  config: EvalensConfig;
  configDir?: string;
};

type RerunArguments = {
  experiment: string;
  config: string;
  "params-file"?: string;
  "from-run": string;
  "rerun-items-file"?: string;
  "--"?: unknown[];
};

export const rerunCommand: CommandModule<{}, RerunArguments> = {
  command: "rerun <experiment>",
  describe: "Create a derived run that inherits completed items and reruns the rest",
  builder: (rerun) =>
    rerun
      .positional("experiment", { type: "string", demandOption: true })
      .option("config", {
        type: "string",
        demandOption: true,
        requiresArg: true,
        description: "Path to evalens.config.json",
      })
      .option("params-file", {
        type: "string",
        requiresArg: true,
        description: "Path to a JSON object containing eval params",
      })
      .option("from-run", {
        type: "string",
        demandOption: true,
        requiresArg: true,
        description: "The source run whose completed items should be inherited",
      })
      .option("rerun-items-file", {
        type: "string",
        requiresArg: true,
        description:
          "Path to a JSON array of completed item IDs that must be rerun instead of inherited",
      }),
  handler: async (argv) => {
    const experiment = await loadExperiment(argv.experiment);
    const configPath = path.resolve(argv.config);
    const config = await loadEvalensConfig(configPath);
    const rawParams = Array.isArray(argv["--"]) ? argv["--"].map(String) : [];
    if (argv["params-file"] && rawParams.length > 0) {
      throw new Error("params-file cannot be combined with params after --");
    }
    const params = RawRerunParams.parse(
      argv["params-file"]
        ? await readCliParamsFile(argv["params-file"])
        : parseCliParams(rawParams)
    );

    const result = await rerun(experiment, {
      sourceRunId: argv["from-run"],
      ...(argv["rerun-items-file"]
        ? {
            rerunItemIds: RerunItemIds.parse(
              await Bun.file(path.resolve(argv["rerun-items-file"])).json()
            ),
          }
        : {}),
      params: params.eval,
      config,
      configDir: path.dirname(configPath),
    });
    if (result.itemErrorCount > 0) {
      throw new Error(
        `Experiment rerun completed with ${result.itemErrorCount} item error(s) ` +
          `(sourceRunId=${result.sourceRunId}, runId=${result.runId}, evalId=${result.evalId})`
      );
    }
  },
};

export async function rerun<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  RunParamsSchema extends ParamsSchema,
  EvalParamsSchema extends ParamsSchema,
  Evaluators extends readonly unknown[],
  RunAdapters extends AdapterNames,
  EvalAdapters extends AdapterNames,
>(
  definition: Experiment<
    Item,
    Result,
    RunParamsSchema,
    EvalParamsSchema,
    Evaluators,
    RunAdapters,
    EvalAdapters
  >,
  options: RerunCommandOptions<EvalParamsSchema>
) {
  const runAdapterNames = phaseAdapters(definition.adapters?.run);
  const evalAdapterNames = phaseAdapters(definition.adapters?.eval);
  const runAdapters = adapterIdentities(runAdapterNames);
  const runAdapterConfig = selectAdapterConfig(
    runAdapterNames,
    options.config.adapters ?? {}
  );
  const evalAdapterConfig = selectAdapterConfig(
    evalAdapterNames,
    options.config.adapters ?? {}
  );
  const evalParams = parseParams(definition.params?.eval, options.params);
  await using store = await createStore(options.config);
  const sourceRun = store.openRun(definition.name, options.sourceRunId);
  const sourceManifest = await sourceRun.readManifest();
  if (sourceManifest.status === "running") {
    throw new Error(
      `cannot rerun from source run ${options.sourceRunId} with status running`
    );
  }
  if (
    digestCanonicalJson(sourceManifest.adapters) !== digestCanonicalJson(runAdapters)
  ) {
    throw new Error(
      "source run adapter identities do not match the current experiment"
    );
  }

  const runParams = parseParams(
    definition.params?.run,
    sourceManifest.params as z.input<RunParamsSchema>
  );
  if (digestCanonicalJson(runParams) !== sourceManifest.paramsDigest) {
    throw new Error("source run params do not match the current experiment schema");
  }
  const prepared = await prepareRun(definition, {
    datasetSource: createDatasetSource(options.config, options.configDir),
    params: runParams,
  });
  if (sourceManifest.datasetName !== prepared.dataset.name) {
    throw new Error(
      `source run dataset name mismatch: expected ${sourceManifest.datasetName}, ` +
        `received ${prepared.dataset.name}`
    );
  }
  if (sourceManifest.datasetDigest !== prepared.datasetDigest) {
    throw new Error(
      `source run dataset digest mismatch: expected ${sourceManifest.datasetDigest}, ` +
        `received ${prepared.datasetDigest}`
    );
  }

  const currentFullItems = new Map(
    prepared.dataset.items.map((item) => [item.id, item])
  );
  const sourceItemStatuses = new Map<string, RunResult<Result>["status"]>();
  for await (const stored of sourceRun.iterateItemStates()) {
    if (sourceItemStatuses.has(stored.itemId)) {
      throw new Error(`source run contains duplicate item: ${stored.itemId}`);
    }
    const currentItem = currentFullItems.get(stored.itemId);
    if (!currentItem) {
      throw new Error(
        `source run item is missing from the current dataset: ${stored.itemId}`
      );
    }
    const currentDigest = prepared.itemDigests.get(stored.itemId);
    if (!currentDigest) {
      throw new Error(
        `missing current dataset digest for source item: ${stored.itemId}`
      );
    }
    if (stored.itemDigest !== currentDigest) {
      throw new Error(`source run item digest mismatch: ${stored.itemId}`);
    }
    sourceItemStatuses.set(stored.itemId, stored.status);
  }

  const selectedItemIds = resolveSourceSelection({
    sourceRunId: options.sourceRunId,
    sourceManifest,
    fullDatasetItemIds: prepared.dataset.items.map((item) => item.id),
  });
  const selectedIds = new Set(selectedItemIds);
  for (const itemId of sourceItemStatuses.keys()) {
    if (!selectedIds.has(itemId)) {
      throw new Error(`source run contains an item outside its selection: ${itemId}`);
    }
  }
  const forcedRerunItemIds = new Set(options.rerunItemIds ?? []);
  const unknownForcedItemIds = [...forcedRerunItemIds].filter(
    (itemId) => !selectedIds.has(itemId)
  );
  if (unknownForcedItemIds.length > 0) {
    throw new Error(
      `forced rerun contains item ids outside the source selection: ${unknownForcedItemIds.join(
        ", "
      )}`
    );
  }
  const inheritedItemIds = new Set(
    [...sourceItemStatuses]
      .filter(
        ([itemId, status]) => status === "completed" && !forcedRerunItemIds.has(itemId)
      )
      .map(([itemId]) => itemId)
  );

  const selectedItems = prepared.dataset.items.filter((item) =>
    selectedIds.has(item.id)
  );
  if (selectedItems.length !== sourceManifest.targetItemCount) {
    throw new Error(
      `source run target item count mismatch: expected ${sourceManifest.targetItemCount}, ` +
        `resolved ${selectedItems.length}`
    );
  }
  const pendingItems = selectedItems.filter((item) => !inheritedItemIds.has(item.id));

  let runId: string;
  let itemErrorCount = 0;
  {
    await using writer = await store.createRun({
      sourceRunId: sourceManifest.runId,
      experimentName: sourceManifest.experimentName,
      description: sourceManifest.description,
      datasetName: sourceManifest.datasetName,
      datasetDigest: sourceManifest.datasetDigest,
      datasetSelectionDigest: sourceManifest.datasetSelectionDigest,
      selectedItemIds,
      targetItemCount: sourceManifest.targetItemCount,
      tags: sourceManifest.tags,
      params: runParams,
      paramsDigest: sourceManifest.paramsDigest,
      adapters: runAdapters,
    });
    runId = writer.runId;

    for await (const stored of sourceRun.iterateItems<Result>()) {
      if (
        stored.runResult.status !== "completed" ||
        !inheritedItemIds.has(stored.itemId)
      ) {
        continue;
      }
      const itemDigest = prepared.itemDigests.get(stored.itemId);
      if (!itemDigest) {
        throw new Error(
          `missing current dataset digest for inherited item: ${stored.itemId}`
        );
      }
      {
        await using loggerHandle = writer.createItemLogger(stored.itemId);
        loggerHandle.logger.info(
          { sourceRunId: sourceManifest.runId },
          "inherited completed run item"
        );
      }
      await writer.commitItem(stored.itemId, stored.runResult, itemDigest);
    }

    const summary = await executeRun(definition, {
      writer,
      dataset: { ...prepared.dataset, items: pendingItems },
      itemDigests: prepared.itemDigests,
      params: runParams,
      adapterConfig: runAdapterConfig,
      concurrency: options.config.concurrency,
      ...(options.config.retry === undefined
        ? {}
        : { retry: resolveRunRetryOptions(options.config.retry) }),
    });
    itemErrorCount = summary.errorItemCount;
  }

  const runReader = store.openRun(definition.name, runId);
  let evalId: string;
  {
    await using writer = await store.createEvaluation(runReader, {
      evaluators: evaluatorIdentities(definition.evaluators),
      aggregatorVersion: definition.aggregator.version,
      params: evalParams,
      paramsDigest: digestCanonicalJson(evalParams),
      adapters: adapterIdentities(evalAdapterNames),
    });
    evalId = writer.evalId;
    await executeEvaluation<
      Item,
      Result,
      z.output<EvalParamsSchema>,
      Evaluators,
      AdapterConfigFor<EvalAdapters>
    >(definition, {
      run: runReader,
      dataset: { ...prepared.dataset, items: selectedItems },
      writer,
      params: evalParams,
      adapterConfig: evalAdapterConfig,
      concurrency: options.config.concurrency,
    });
  }

  return {
    sourceRunId: sourceManifest.runId,
    runId,
    evalId,
    inheritedItemCount: inheritedItemIds.size,
    rerunItemCount: pendingItems.length,
    itemErrorCount,
  };
}

function resolveSourceSelection(input: {
  sourceRunId: string;
  sourceManifest: {
    targetItemCount: number;
    datasetDigest: string;
    datasetSelectionDigest: string;
    selectedItemIds: string[];
  };
  fullDatasetItemIds: string[];
}) {
  const selectedItemIds = input.sourceManifest.selectedItemIds;
  const uniqueItemIds = new Set(selectedItemIds);
  const fullDatasetIds = new Set(input.fullDatasetItemIds);
  const resolvedItemIds = input.fullDatasetItemIds.filter((itemId) =>
    uniqueItemIds.has(itemId)
  );
  if (
    selectedItemIds.length !== input.sourceManifest.targetItemCount ||
    uniqueItemIds.size !== selectedItemIds.length ||
    selectedItemIds.some((itemId) => !fullDatasetIds.has(itemId)) ||
    selectedItemIds.some((itemId, index) => itemId !== resolvedItemIds[index]) ||
    digestDatasetSelection(input.sourceManifest.datasetDigest, selectedItemIds) !==
      input.sourceManifest.datasetSelectionDigest
  ) {
    throw new Error(
      `source run ${input.sourceRunId} has an invalid persisted dataset selection`
    );
  }
  return selectedItemIds;
}
