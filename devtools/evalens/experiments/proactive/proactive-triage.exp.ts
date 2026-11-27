import path from "node:path";
import { defineExperiment, NoParamsSchema } from "@evalens/core";

import {
  ProactiveTriageRunParamsSchema,
  ProactiveTriageRunResultSchema,
  type ProactiveObservation,
  type ProactiveTriageRunResult,
} from "./contracts";
import { loadProactiveDataset, type ProactiveEvalItem } from "./dataset";
import {
  fatigueBudgetEvaluator,
  proactiveTriageAggregator,
  triageAccuracyEvaluator,
  type ProactiveTriageEvaluators,
} from "./evaluation";
import { executeProactiveScenario, loadRecordedObservations } from "./runner";

const DEFAULT_RUNNER_SCRIPT = path.resolve(
  import.meta.dirname,
  "./shadow_replay_runner.exs"
);

const recordedCache = new Map<string, Promise<Map<string, ProactiveObservation>>>();

function getRecordedObservations(
  resultsPath: string
): Promise<Map<string, ProactiveObservation>> {
  let cached = recordedCache.get(resultsPath);
  if (!cached) {
    cached = loadRecordedObservations(resultsPath);
    recordedCache.set(resultsPath, cached);
  }
  return cached;
}

export default defineExperiment<
  ProactiveEvalItem,
  ProactiveTriageRunResult,
  ProactiveTriageEvaluators,
  typeof ProactiveTriageRunParamsSchema,
  typeof NoParamsSchema,
  readonly [],
  readonly []
>({
  name: "proactive-triage",
  description:
    "Evaluates Comma Proactive triage accuracy, counterfactual sensitivity, and multi-item fatigue budgets against frozen Evalens datasets.",
  metadata: {
    tags: ["comma", "proactive", "triage", "restraint", "fatigue"],
  },
  params: { run: ProactiveTriageRunParamsSchema, eval: NoParamsSchema },
  adapters: { run: [], eval: [] },
  datasetLoader: loadProactiveDataset,
  async runItem(item, context) {
    const { params } = context;

    if (params.resultsPath) {
      const recorded = await getRecordedObservations(params.resultsPath);
      const scenarios =
        item.input.kind === "counterfactual_pair"
          ? { primary: item.input.base, variant: item.input.variant }
          : { primary: item.input.scenario, variant: undefined };

      const observations = scenarios.primary.items.map((src) => {
        const obs = recorded.get(src.itemId);
        if (!obs) {
          throw new Error(
            `recorded results ${params.resultsPath} missing item ${src.itemId}`
          );
        }
        return obs;
      });

      const variantObservations = scenarios.variant?.items.map((src) => {
        const obs = recorded.get(src.itemId);
        if (!obs) {
          throw new Error(
            `recorded results ${params.resultsPath} missing variant item ${src.itemId}`
          );
        }
        return obs;
      });

      return {
        result: ProactiveTriageRunResultSchema.parse({
          revision: params.revision,
          model: params.model,
          observations,
          ...(variantObservations ? { variantObservations } : {}),
        }),
        trajectories: [],
      };
    }

    if (!params.systemsDir) {
      throw new Error(
        "either run.systemsDir or run.resultsPath is required for proactive-triage"
      );
    }

    if (item.input.kind === "counterfactual_pair") {
      const [observations, variantObservations] = await Promise.all([
        executeProactiveScenario({
          systemsDir: params.systemsDir,
          runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
          scenario: item.input.base,
          model: params.model,
          ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
          timeoutMs: params.timeoutMs,
        }),
        executeProactiveScenario({
          systemsDir: params.systemsDir,
          runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
          scenario: item.input.variant,
          model: params.model,
          ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
          timeoutMs: params.timeoutMs,
        }),
      ]);

      return {
        result: ProactiveTriageRunResultSchema.parse({
          revision: params.revision,
          model: params.model,
          observations,
          variantObservations,
        }),
        trajectories: [],
      };
    }

    const observations = await executeProactiveScenario({
      systemsDir: params.systemsDir,
      runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
      scenario: item.input.scenario,
      model: params.model,
      ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
      timeoutMs: params.timeoutMs,
    });

    return {
      result: ProactiveTriageRunResultSchema.parse({
        revision: params.revision,
        model: params.model,
        observations,
      }),
      trajectories: [],
    };
  },
  evaluators: [triageAccuracyEvaluator, fatigueBudgetEvaluator],
  aggregator: proactiveTriageAggregator,
});
