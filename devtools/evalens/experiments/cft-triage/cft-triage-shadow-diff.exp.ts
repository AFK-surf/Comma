import path from "node:path";
import { defineExperiment } from "@evalens/core";

import {
  CftShadowEvalParamsSchema,
  CftShadowRunParamsSchema,
  CftShadowRunResultSchema,
  type CftShadowRunResult,
  type CftTriageObservation,
} from "./contracts";
import {
  loadCftTriageDataset,
  payloadItemId,
  type CftScenarioPayload,
  type CftTriageEvalItem,
} from "./dataset";
import {
  cftBlindPairwiseJudgeEvaluator,
  cftShadowAggregator,
  cftShadowDiffEvaluator,
  type CftShadowEvaluators,
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

async function resolveBranchObservation(options: {
  payload: CftScenarioPayload;
  resultsPath?: string;
  systemsDir?: string;
  model: string;
  baseUrl?: string;
  timeoutMs: number;
  label: string;
}): Promise<CftTriageObservation> {
  const itemId = payloadItemId(options.payload);
  if (options.resultsPath) {
    const recorded = await getRecordedObservations(options.resultsPath);
    const obs = recorded.get(itemId);
    if (!obs) {
      throw new Error(
        `${options.label} recorded results ${options.resultsPath} missing item ${itemId}`
      );
    }
    return obs;
  }

  if (!options.systemsDir) {
    throw new Error(
      `either ${options.label}SystemsDir or ${options.label}ResultsPath is required`
    );
  }

  return executeCftScenario({
    systemsDir: options.systemsDir,
    runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
    payload: options.payload,
    model: options.model,
    ...(options.baseUrl ? { baseUrl: options.baseUrl } : {}),
    timeoutMs: options.timeoutMs,
  });
}

export default defineExperiment<
  CftTriageEvalItem,
  CftShadowRunResult,
  CftShadowEvaluators,
  typeof CftShadowRunParamsSchema,
  typeof CftShadowEvalParamsSchema,
  readonly [],
  readonly ["codex"]
>({
  name: "cft-triage-shadow-diff",
  description:
    "Compares Baseline vs Candidate Comma for Teams (CFT) group-chat Triage revisions on matched Slack snapshots with intervention/delegation/follow-up diffs and two-pass position-debiased blind A/B judging.",
  metadata: {
    tags: ["comma", "cft", "triage", "shadow-diff", "pairwise", "blind-ab"],
  },
  params: {
    run: CftShadowRunParamsSchema,
    eval: CftShadowEvalParamsSchema,
  },
  adapters: { run: [], eval: ["codex"] },
  datasetLoader: loadCftTriageDataset,
  async runItem(item, context) {
    const { params } = context;
    const payload =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.payload;

    const [baseline, candidate] = await Promise.all([
      resolveBranchObservation({
        payload,
        ...(params.baselineResultsPath
          ? { resultsPath: params.baselineResultsPath }
          : {}),
        ...(params.baselineSystemsDir ? { systemsDir: params.baselineSystemsDir } : {}),
        model: params.model,
        ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
        timeoutMs: params.timeoutMs,
        label: "baseline",
      }),
      resolveBranchObservation({
        payload,
        ...(params.candidateResultsPath
          ? { resultsPath: params.candidateResultsPath }
          : {}),
        ...(params.candidateSystemsDir
          ? { systemsDir: params.candidateSystemsDir }
          : {}),
        model: params.model,
        ...(params.baseUrl ? { baseUrl: params.baseUrl } : {}),
        timeoutMs: params.timeoutMs,
        label: "candidate",
      }),
    ]);

    return {
      result: CftShadowRunResultSchema.parse({
        baselineRevision: params.baselineRevision,
        candidateRevision: params.candidateRevision,
        model: params.model,
        baseline,
        candidate,
      }),
      trajectories: [],
    };
  },
  evaluators: [cftShadowDiffEvaluator, cftBlindPairwiseJudgeEvaluator],
  aggregator: cftShadowAggregator,
});
