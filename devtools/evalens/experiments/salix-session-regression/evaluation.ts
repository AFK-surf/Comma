import type { Evaluator, Trajectory } from "@evalens/core";

import type { SalixSessionRegressionItem } from "./dataset";

export type SalixSessionRegressionResult = {
  answer: string;
  timedOut: boolean;
  targetRole: "router" | "worker";
};

export type TrajectoryHealth = {
  replied: boolean;
  maxIdenticalToolRepeats: number;
  maxConsecutiveToolErrors: number;
};

export function trajectoryHealth(
  result: SalixSessionRegressionResult,
  trajectories: readonly Trajectory[]
): TrajectoryHealth {
  let identicalStreak = 0;
  let maxIdenticalToolRepeats = 0;
  let previousCall = "";
  let errorStreak = 0;
  let maxConsecutiveToolErrors = 0;

  for (const step of trajectories.flatMap((trajectory) => trajectory.steps)) {
    if (step.type === "tool_call") {
      const signature = `${step.name}:${stableJson(step.arguments)}`;
      identicalStreak = signature === previousCall ? identicalStreak + 1 : 1;
      previousCall = signature;
      maxIdenticalToolRepeats = Math.max(maxIdenticalToolRepeats, identicalStreak);
    }

    if (step.type === "tool_result") {
      const failed =
        step.status === "error" ||
        step.errorClass !== undefined ||
        step.errorMessage !== undefined;
      errorStreak = failed ? errorStreak + 1 : 0;
      maxConsecutiveToolErrors = Math.max(maxConsecutiveToolErrors, errorStreak);
    }
  }

  return {
    replied: !result.timedOut && result.answer.trim().length > 0,
    maxIdenticalToolRepeats,
    maxConsecutiveToolErrors,
  };
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, nested]) => `${JSON.stringify(key)}:${stableJson(nested)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export const trajectoryRegressionEvaluator = {
  name: "trajectory-regression",
  version: "1",
  evaluate(item, output) {
    const health = trajectoryHealth(output.result, output.trajectories ?? []);
    const expected = item.expected.trajectoryRegression;
    const replyPass = !expected.mustReply || health.replied;
    const repeatedCallPass =
      health.maxIdenticalToolRepeats <= expected.maxIdenticalToolRepeats;
    const toolErrorPass =
      health.maxConsecutiveToolErrors <= expected.maxConsecutiveToolErrors;

    return {
      score: {
        trajectoryRegression: replyPass && repeatedCallPass && toolErrorPass ? 1 : 0,
        reply: replyPass ? 1 : 0,
        repeatedToolCalls: repeatedCallPass ? 1 : 0,
        consecutiveToolErrors: toolErrorPass ? 1 : 0,
      },
      explanation: [
        `replied=${health.replied}`,
        `identical-tool-streak=${health.maxIdenticalToolRepeats}/${expected.maxIdenticalToolRepeats}`,
        `tool-error-streak=${health.maxConsecutiveToolErrors}/${expected.maxConsecutiveToolErrors}`,
        `source-findings=${expected.confirmedFindings.map((finding) => finding.metric).join(",")}`,
      ].join("; "),
    };
  },
} satisfies Evaluator<SalixSessionRegressionItem, SalixSessionRegressionResult, {}>;

export type SalixSessionRegressionEvaluators = readonly [
  typeof trajectoryRegressionEvaluator,
];
