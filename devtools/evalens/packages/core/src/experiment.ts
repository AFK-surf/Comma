import { z } from "zod";

import type { AdapterConfigFor, AdapterNames } from "./adapter";
import type { DatasetItem } from "./dataset";
import {
  type EvaluationDefinition,
  type Evaluator,
  validateEvaluationDefinition,
} from "./evaluation";
import type { RunDefinition } from "./run";
import { ExperimentName, type Params } from "./schemas";

export type ExperimentParams = Readonly<Params>;
export type ParamsSchema = z.ZodType<ExperimentParams, ExperimentParams>;

export const NoParamsSchema = z.strictObject({});

type ExperimentParamSchemas<
  RunParamsSchema extends ParamsSchema,
  EvalParamsSchema extends ParamsSchema,
> = {
  run: RunParamsSchema;
  eval: EvalParamsSchema;
};

export type Experiment<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  RunParamsSchema extends ParamsSchema = typeof NoParamsSchema,
  EvalParamsSchema extends ParamsSchema = typeof NoParamsSchema,
  Evaluators extends readonly unknown[] = readonly Evaluator<
    Item,
    Result,
    z.output<EvalParamsSchema>
  >[],
  RunAdapters extends AdapterNames = readonly [],
  EvalAdapters extends AdapterNames = readonly [],
> = RunDefinition<
  Item,
  Result,
  z.output<RunParamsSchema>,
  AdapterConfigFor<RunAdapters>
> &
  EvaluationDefinition<
    NoInfer<Item>,
    NoInfer<Result>,
    z.output<EvalParamsSchema>,
    Evaluators,
    AdapterConfigFor<EvalAdapters>
  > & {
    params?: Partial<ExperimentParamSchemas<RunParamsSchema, EvalParamsSchema>>;
    adapters?: {
      run: RunAdapters;
      eval: EvalAdapters;
    };
  };

export function defineExperiment<
  Item extends DatasetItem<unknown, unknown>,
  Result extends z.JSONType,
  const Evaluators extends readonly unknown[],
  RunParamsSchema extends ParamsSchema = typeof NoParamsSchema,
  EvalParamsSchema extends ParamsSchema = typeof NoParamsSchema,
  const RunAdapters extends AdapterNames = readonly [],
  const EvalAdapters extends AdapterNames = readonly [],
>(
  definition: Experiment<
    Item,
    Result,
    RunParamsSchema,
    EvalParamsSchema,
    Evaluators,
    RunAdapters,
    EvalAdapters
  >
): Experiment<
  Item,
  Result,
  RunParamsSchema,
  EvalParamsSchema,
  Evaluators,
  RunAdapters,
  EvalAdapters
> {
  ExperimentName.parse(definition.name);
  validateAdapterNames(definition.adapters?.run ?? []);
  validateAdapterNames(definition.adapters?.eval ?? []);
  validateEvaluationDefinition(definition);
  return definition;
}

function validateAdapterNames(names: readonly string[]): void {
  if (new Set(names).size !== names.length) {
    throw new Error("adapter names must be unique within each phase");
  }
}
