import path from "node:path";
import { defineExperiment } from "@evalens/core";

import {
  ProactiveShadowEvalParamsSchema,
  ProactiveShadowRunParamsSchema,
  ProactiveShadowRunResultSchema,
  type ProactiveObservation,
  type ProactiveShadowRunResult,
} from "./contracts";
import { loadProactiveDataset, type ProactiveEvalItem } from "./dataset";
import {
  blindPairwiseJudgeEvaluator,
  proactiveShadowAggregator,
  shadowDiffEvaluator,
  type ProactiveShadowEvaluators,
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

async function resolveBranchObservation(options: {
  itemId: string;
  scenario: ProactiveEvalItem["input"] extends infer Input
    ? Input extends { scenario: infer S }
      ? S
      : never
    : never;
  resultsPath?: string;
  systemsDir?: string;
  model: string;
  baseUrl?: string;
  timeoutMs: number;
  label: string;
}): Promise<ProactiveObservation> {
  if (options.resultsPath) {
    const recorded = await getRecordedObservations(options.resultsPath);
    const obs = recorded.get(options.itemId);
    if (!obs) {
      throw new Error(
        `${options.label} recorded results ${options.resultsPath} missing item ${options.itemId}`
      );
    }
    return obs;
  }

  if (!options.systemsDir) {
    throw new Error(
      `either ${options.label}SystemsDir or ${options.label}ResultsPath is required`
    );
  }

  const observations = await executeProactiveScenario({
    systemsDir: options.systemsDir,
    runnerScriptPath: DEFAULT_RUNNER_SCRIPT,
    scenario: options.scenario,
    model: options.model,
    ...(options.baseUrl ? { baseUrl: options.baseUrl } : {}),
    timeoutMs: options.timeoutMs,
  });
  const first = observations[0];
  if (!first) {
    throw new Error(
      `${options.label} runner returned no observation for ${options.itemId}`
    );
  }
  return first;
}

export default defineExperiment<
  ProactiveEvalItem,
  ProactiveShadowRunResult,
  ProactiveShadowEvaluators,
  typeof ProactiveShadowRunParamsSchema,
  typeof ProactiveShadowEvalParamsSchema,
  readonly [],
  readonly ["codex"]
>({
  name: "proactive-shadow-diff",
  description:
    "Compares Baseline vs Candidate Comma Proactive revisions on matched event streams with decision-flip diffs and two-pass position-debiased blind A/B judging.",
  metadata: {
    tags: ["comma", "proactive", "shadow-diff", "pairwise", "blind-ab"],
  },
  params: {
    run: ProactiveShadowRunParamsSchema,
    eval: ProactiveShadowEvalParamsSchema,
  },
  adapters: { run: [], eval: ["codex"] },
  datasetLoader: loadProactiveDataset,
  async runItem(item, context) {
    const { params } = context;
    const scenario =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.scenario;
    const primarySource = scenario.items[0];
    if (!primarySource) {
      throw new Error(`dataset item ${item.id} contains no source items`);
    }

    const [baseline, candidate] = await Promise.all([
      resolveBranchObservation({
        itemId: primarySource.itemId,
        scenario,
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
        itemId: primarySource.itemId,
        scenario,
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
      result: ProactiveShadowRunResultSchema.parse({
        baselineRevision: params.baselineRevision,
        candidateRevision: params.candidateRevision,
        model: params.model,
        baseline,
        candidate,
      }),
      trajectories: [],
    };
  },
  evaluators: [shadowDiffEvaluator, blindPairwiseJudgeEvaluator],
  aggregator: proactiveShadowAggregator,
});
