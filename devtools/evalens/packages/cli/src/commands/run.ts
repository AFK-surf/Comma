import path from "node:path";
import type { CommandModule } from "yargs";
import { z } from "zod";

import { adapterIdentities, selectAdapterConfig } from "@evalens/adapters/config";
import {
  ItemId,
  Params,
  digestCanonicalJson,
  executeEvaluation,
  executeRun,
  prepareRun,
  type AdapterConfigFor,
  type AdapterNames,
  type DatasetItem,
  type Experiment,
  type ParamsSchema,
} from "@evalens/core";

import { loadEvalensConfig, resolveRunRetryOptions } from "../config";
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

const RawExperimentParams = z
  .object({
    run: Params.default({}),
    eval: Params.default({}),
  })
  .strict();
const RawExperimentRequest = RawExperimentParams.extend({
  filter: ItemId.array().min(1).optional(),
}).strict();

export type CommandParams<
  RunParamsSchema extends ParamsSchema,
  EvalParamsSchema extends ParamsSchema,
> = {
  run: z.input<RunParamsSchema>;
  eval: z.input<EvalParamsSchema>;
};

export type RunCommandOptions<
  RunParamsSchema extends ParamsSchema,
  EvalParamsSchema extends ParamsSchema,
> = {
  filter?: string[];
  params?: Partial<CommandParams<RunParamsSchema, EvalParamsSchema>>;
  config: import("../config").EvalensConfig;
  configDir?: string;
};

type RunArguments = {
  experiment: string;
  config: string;
  "params-file"?: string;
  "request-file"?: string;
  filter?: string[];
  "--"?: unknown[];
};

export const runExperimentCommand: CommandModule<{}, RunArguments> = {
  command: "$0 <experiment>",
  describe: "Run an experiment",
  builder: (run) =>
    run
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
        description: "Path to a JSON object containing run and eval params",
      })
      .option("request-file", {
        type: "string",
        requiresArg: true,
        description: "Path to a JSON object containing filter, run, and eval",
      })
      .option("filter", {
        type: "array",
        string: true,
        description: "The filter to apply to the items (array of item ids)",
      }),
  handler: async (argv) => {
    const experiment = await loadExperiment(argv.experiment);
    const configPath = path.resolve(argv.config);
    const config = await loadEvalensConfig(configPath);
    const rawParams = Array.isArray(argv["--"]) ? argv["--"].map(String) : [];
    if (
      argv["request-file"] &&
      (argv["params-file"] || argv.filter || rawParams.length > 0)
    ) {
      throw new Error(
        "request-file cannot be combined with filter, params-file, or params after --"
      );
    }
    if (argv["params-file"] && rawParams.length > 0) {
      throw new Error("params-file cannot be combined with params after --");
    }
    const request = argv["request-file"]
      ? await readCliExperimentRequest(argv["request-file"])
      : {
          ...(argv.filter ? { filter: ItemId.array().min(1).parse(argv.filter) } : {}),
          ...RawExperimentParams.parse(
            argv["params-file"]
              ? await readCliParamsFile(argv["params-file"])
              : parseCliParams(rawParams)
          ),
        };

    const result = await run(experiment, {
      ...(request.filter ? { filter: request.filter } : {}),
      params: { run: request.run, eval: request.eval },
      config,
      configDir: path.dirname(configPath),
    });
    if (result.itemErrorCount > 0) {
      throw new Error(
        `Experiment run completed with ${result.itemErrorCount} item error(s) (runId=${result.runId}, evalId=${result.evalId})`
      );
    }
  },
};

export function parseCliExperimentRequest(value: unknown) {
  return RawExperimentRequest.parse(value);
}

export async function readCliExperimentRequest(filePath: string) {
  return parseCliExperimentRequest(await readCliParamsFile(filePath));
}

export async function run<
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
  options: RunCommandOptions<RunParamsSchema, EvalParamsSchema>
) {
  const runAdapterNames = phaseAdapters(definition.adapters?.run);
  const evalAdapterNames = phaseAdapters(definition.adapters?.eval);
  const runAdapterConfig = selectAdapterConfig(
    runAdapterNames,
    options.config.adapters ?? {}
  );
  const evalAdapterConfig = selectAdapterConfig(
    evalAdapterNames,
    options.config.adapters ?? {}
  );
  const runParams = parseParams(definition.params?.run, options.params?.run);
  const evalParams = parseParams(definition.params?.eval, options.params?.eval);
  const { dataset, tags, itemDigests, datasetDigest, datasetSelectionDigest } =
    await prepareRun(definition, {
      ...(options.filter === undefined ? {} : { filter: options.filter }),
      datasetSource: createDatasetSource(options.config, options.configDir),
      params: runParams,
    });
  await using store = await createStore(options.config);
  let runId: string;
  let itemErrorCount = 0;
  {
    await using writer = await store.createRun({
      experimentName: definition.name,
      description: definition.description,
      datasetName: dataset.name,
      datasetDigest,
      datasetSelectionDigest,
      selectedItemIds: dataset.items.map((item) => item.id),
      targetItemCount: dataset.items.length,
      tags,
      params: runParams,
      paramsDigest: digestCanonicalJson(runParams),
      adapters: adapterIdentities(runAdapterNames),
    });
    runId = writer.runId;
    const summary = await executeRun(definition, {
      writer,
      dataset,
      itemDigests,
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
      dataset,
      writer,
      params: evalParams,
      adapterConfig: evalAdapterConfig,
      concurrency: options.config.concurrency,
    });
  }

  return { runId, evalId, itemErrorCount };
}
