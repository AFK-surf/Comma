import path from "node:path";
import { defineExperiment, NoParamsSchema } from "@evalens/core";

import {
  CftTriageRunParamsSchema,
  CftTriageRunResultSchema,
  type CftTriageObservation,
  type CftTriageRunResult,
} from "./contracts";
import { loadCftTriageDataset, payloadItemId, type CftTriageEvalItem } from "./dataset";
import {
  cftParticipationEvaluator,
  cftTriageAggregator,
  type CftTriageEvaluators,
} from "./evaluation";
import { executeCftScenario, loadRecordedCftObservations } from "./runner";

const DEFAULT_RUNNER_SCRIPT = path.resolve(
  import.meta.dirname,
  "./cft_triage_replay_runner.exs"
);

const recordedCache = new Map<string, Promise<Map<string, CftTriageObservation>>>();

function getRecordedObservations(
  resultsPath: string
): Promise<Map<string, CftTriageObservation>> {
  let cached = recordedCache.get(resultsPath);
  if (!cached) {
    cached = loadRecordedCftObservations(resultsPath);
    recordedCache.set(resultsPath, cached);
  }
  return cached;
}

export default defineExperiment<
  CftTriageEvalItem,
  CftTriageRunResult,
  CftTriageEvaluators,
  typeof CftTriageRunParamsSchema,
  typeof NoParamsSchema,
  readonly [],
  readonly []
>({
  name: "cft-triage",
  description:
    "Evaluates Comma for Teams (CFT) group-chat Triage participation restraint, helpfulness, delegation/follow-up discipline, and counterfactual sensitivity across Worker participation and native TriageEvaluator lanes.",
  metadata: {
    tags: ["comma", "cft", "triage", "restraint", "group-chat"],
  },
  params: { run: CftTriageRunParamsSchema, eval: NoParamsSchema },
  adapters: { run: [], eval: [] },
  datasetLoader: loadCftTriageDataset,
  async runItem(item, context) {
    const { params } = context;
    const primaryPayload =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.payload;
    const variantPayload =
      item.input.kind === "counterfactual_pair" ? item.input.variant : undefined;

    if (params.resultsPath) {
      const recorded = await getRecordedObservations(params.resultsPath);
      const primaryId = payloadItemId(primaryPayload);
      const observation = recorded.get(primaryId);
      if (!observation) {
        throw new Error(
          `recorded results ${params.resultsPath} missing item ${primaryId}`
        );
      }

      let variantObservation: CftTriageObservation | undefined;
      if (variantPayload) {
        const variantId = payloadItemId(variantPayload);
        variantObservation = recorded.get(variantId);
        if (!variantObservation) {
          throw new Error(
            `recorded results ${params.resultsPath} missing variant item ${variantId}`
          );
        }
      }

      return {
        result: CftTriageRunResultSchema.parse({
          revision: params.revision,
          model: params.model,
          observation,
          ...(variantObservation ? { variantObservation } : {}),
        }),
        trajectories: [],
      };
    }

    if (!params.systemsDir) {
      throw new Error(
        "either run.systemsDir or run.resultsPath is required for cft-triage"
      );
    }

    if (variantPayload) {
      const [observation, variantObservation] = await Promise.all([
        executeCftScenario({
          systemsDir: params.systemsDir,
          runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
          payload: primaryPayload,
          model: params.model,
          ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
          timeoutMs: params.timeoutMs,
        }),
        executeCftScenario({
          systemsDir: params.systemsDir,
          runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
          payload: variantPayload,
          model: params.model,
          ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
          timeoutMs: params.timeoutMs,
        }),
      ]);

      return {
        result: CftTriageRunResultSchema.parse({
          revision: params.revision,
          model: params.model,
          observation,
          variantObservation,
        }),
        trajectories: [],
      };
    }

    const observation = await executeCftScenario({
      systemsDir: params.systemsDir,
      runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
      payload: primaryPayload,
      model: params.model,
      ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
      timeoutMs: params.timeoutMs,
    });

    return {
      result: CftTriageRunResultSchema.parse({
        revision: params.revision,
        model: params.model,
        observation,
      }),
      trajectories: [],
    };
  },
  evaluators: [cftParticipationEvaluator],
  aggregator: cftTriageAggregator,
});
