import path from "node:path";
import type { CommandModule } from "yargs";
import { z } from "zod";

import { adapterIdentities, selectAdapterConfig } from "@evalens/adapters/config";
import {
  Params,
  digestCanonicalJson,
  executeEvaluation,
  prepareRun,
  type AdapterConfigFor,
  type AdapterNames,
  type DatasetItem,
  type Experiment,
  type ParamsSchema,
} from "@evalens/core";

import { loadEvalensConfig, type EvalensConfig } from "../config";
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

const RawReevalParams = z.object({ eval: Params.default({}) }).strict();

export type ReevalCommandOptions<EvalParamsSchema extends ParamsSchema> = {
  runId: string;
  params?: z.input<EvalParamsSchema>;
  config: EvalensConfig;
  configDir?: string;
};

type ReevalArguments = {
  experiment: string;
  config: string;
  "params-file"?: string;
  "run-id": string;
  "--"?: unknown[];
};

export const reevalCommand: CommandModule<{}, ReevalArguments> = {
  command: "reeval <experiment>",
  describe: "Re-evaluate an existing run",
  builder: (reeval) =>
    reeval
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
      .option("run-id", {
        type: "string",
        demandOption: true,
        description: "The run id to re-evaluate",
      }),
  handler: async (argv) => {
    const experiment = await loadExperiment(argv.experiment);
    const configPath = path.resolve(argv.config);
    const config = await loadEvalensConfig(configPath);
    const rawParams = Array.isArray(argv["--"]) ? argv["--"].map(String) : [];
    if (argv["params-file"] && rawParams.length > 0) {
      throw new Error("params-file cannot be combined with params after --");
    }
    const params = RawReevalParams.parse(
      argv["params-file"]
        ? await readCliParamsFile(argv["params-file"])
        : parseCliParams(rawParams)
    );

    await reeval(experiment, {
      runId: argv["run-id"],
      params: params.eval,
      config,
      configDir: path.dirname(configPath),
    });
  },
};

export async function reeval<
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
  options: ReevalCommandOptions<EvalParamsSchema>
) {
  const evalAdapterNames = phaseAdapters(definition.adapters?.eval);
  const evalAdapterConfig = selectAdapterConfig(
    evalAdapterNames,
    options.config.adapters ?? {}
  );
  const evalParams = parseParams(definition.params?.eval, options.params);
  await using store = await createStore(options.config);
  const runReader = store.openRun(definition.name, options.runId);
  const runManifest = await runReader.readManifest();
  if (runManifest.status !== "finished") {
    throw new Error(
      `cannot create evaluation for run ${runManifest.runId} with status ${runManifest.status}`
    );
  }
  const runParams = parseParams(
    definition.params?.run,
    runManifest.params as z.input<RunParamsSchema>
  );
  if (digestCanonicalJson(runParams) !== runManifest.paramsDigest) {
    throw new Error("run params do not match the current experiment schema");
  }
  const prepared = await prepareRun(definition, {
    filter: runManifest.selectedItemIds,
    datasetSource: createDatasetSource(options.config, options.configDir),
    params: runParams,
  });
  if (
    prepared.dataset.name !== runManifest.datasetName ||
    prepared.datasetDigest !== runManifest.datasetDigest ||
    prepared.datasetSelectionDigest !== runManifest.datasetSelectionDigest ||
    prepared.dataset.items.some(
      (item, index) => item.id !== runManifest.selectedItemIds[index]
    )
  ) {
    throw new Error("run dataset reference does not match the current experiment");
  }
  await using writer = await store.createEvaluation(runReader, {
    evaluators: evaluatorIdentities(definition.evaluators),
    aggregatorVersion: definition.aggregator.version,
    params: evalParams,
    paramsDigest: digestCanonicalJson(evalParams),
    adapters: adapterIdentities(evalAdapterNames),
  });
  const evalId = writer.evalId;
  await executeEvaluation<
    Item,
    Result,
    z.output<EvalParamsSchema>,
    Evaluators,
    AdapterConfigFor<EvalAdapters>
  >(definition, {
    run: runReader,
    dataset: prepared.dataset,
    writer,
    params: evalParams,
    adapterConfig: evalAdapterConfig,
    concurrency: options.config.concurrency,
  });

  return { runId: options.runId, evalId };
}
