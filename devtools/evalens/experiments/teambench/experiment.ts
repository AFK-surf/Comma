import { SalixAdapter } from "@evalens/adapters/salix";
import { defineExperiment, NoParamsSchema, type Experiment } from "@evalens/core";

import { TeamBenchNativeRunParams, type TeamBenchNativeResult } from "./contracts";
import type { TeamBenchDatasetItem } from "./dataset";
import {
  teamBenchNativeAggregator,
  teamBenchNativeEvaluator,
  type TeamBenchNativeEvaluators,
} from "./evaluation";
import { runCodexNative, runSalixNative } from "./native";

type NativeDefinitionInput<Target extends "salix" | "codex"> = Pick<
  Experiment<
    TeamBenchDatasetItem,
    TeamBenchNativeResult,
    typeof TeamBenchNativeRunParams,
    typeof NoParamsSchema,
    TeamBenchNativeEvaluators,
    readonly [Target],
    readonly []
  >,
  "name" | "description" | "datasetLoader"
>;

export function defineSalixNativeExperiment(input: NativeDefinitionInput<"salix">) {
  return defineExperiment<
    TeamBenchDatasetItem,
    TeamBenchNativeResult,
    TeamBenchNativeEvaluators,
    typeof TeamBenchNativeRunParams,
    typeof NoParamsSchema,
    readonly ["salix"],
    readonly []
  >({
    ...input,
    metadata: {
      tags: ["teambench", "native", "salix", "router-worker", "local-grader"],
    },
    params: { run: TeamBenchNativeRunParams, eval: NoParamsSchema },
    adapters: { run: ["salix"], eval: [] },
    async runItem(item, context) {
      const template = context.adapterConfig.salix.templateId;
      if (!template) {
        throw new Error(
          "salix.templateId is required and must be provisioned for the requested run model"
        );
      }
      return runSalixNative({
        item,
        salix: new SalixAdapter(context.adapterConfig.salix),
        template,
        params: context.params,
      });
    },
    evaluators: [teamBenchNativeEvaluator],
    aggregator: teamBenchNativeAggregator,
  });
}

export function defineCodexNativeExperiment(input: NativeDefinitionInput<"codex">) {
  return defineExperiment<
    TeamBenchDatasetItem,
    TeamBenchNativeResult,
    TeamBenchNativeEvaluators,
    typeof TeamBenchNativeRunParams,
    typeof NoParamsSchema,
    readonly ["codex"],
    readonly []
  >({
    ...input,
    metadata: {
      tags: ["teambench", "native", "codex", "main-subagent", "local-grader"],
    },
    params: { run: TeamBenchNativeRunParams, eval: NoParamsSchema },
    adapters: { run: ["codex"], eval: [] },
    runItem: (item, context) =>
      runCodexNative({
        item,
        adapterConfig: context.adapterConfig.codex,
        params: context.params,
      }),
    evaluators: [teamBenchNativeEvaluator],
    aggregator: teamBenchNativeAggregator,
  });
}

export function nativeDescription(target: "Salix" | "Codex"): string {
  return `Runs the TeamBench leaderboard-90 seed-0 dataset through the native ${target} Planner/Executor/Verifier collaboration topology. Evalens starts only Planner/Main, observes the resulting team, freezes its files, and applies the official grader locally without performing worker handoffs.`;
}
