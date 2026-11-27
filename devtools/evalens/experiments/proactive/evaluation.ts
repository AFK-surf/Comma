import { createHash } from "node:crypto";
import type { CodexAdapterConfig } from "@evalens/adapters/config";
import { CodexCliAdapter } from "@evalens/adapters/codex";
import type { AggregationResults, Evaluator } from "@evalens/core";

import {
  BlindPairwiseJudgeAnswerSchema,
  classifyShadowFlip,
  type BlindPairwiseJudgeAnswer,
  type PairwisePick,
  type ProactiveObservation,
  type ProactiveShadowEvalParams,
  type ProactiveShadowRunResult,
  type ProactiveTriageRunResult,
} from "./contracts";
import type {
  ProactiveBranchExpectation,
  ProactiveEvalItem,
  ProactiveSourceItem,
} from "./dataset";

export type PairwiseWinner = "candidate" | "baseline" | "tie";

function normalizeText(value: string): string {
  return value.normalize("NFKC").toLowerCase().replaceAll(/\s+/gu, " ").trim();
}

function isInterruptLike(observation: ProactiveObservation): boolean {
  return (
    observation.outcome === "routed" &&
    (observation.decision === "interrupt" || observation.decision === "ask")
  );
}

export function scoreBranchExpectation(
  observation: ProactiveObservation,
  expectation: ProactiveBranchExpectation | undefined
): {
  pass: number;
  decisionMatch: number;
  falseInterrupt: number;
  mustSurfaceHit: number;
  factGrounding: number;
  forbiddenClaimFree: number;
  researchMatch: number;
  summary: string;
} {
  if (!expectation) {
    return {
      pass: 1,
      decisionMatch: 1,
      falseInterrupt: 0,
      mustSurfaceHit: 1,
      factGrounding: 1,
      forbiddenClaimFree: 1,
      researchMatch: 1,
      summary: "no-expectation",
    };
  }

  const outcomeOk =
    !expectation.allowedOutcomes ||
    expectation.allowedOutcomes.includes(observation.outcome);
  const decisionOk =
    !expectation.allowedDecisions ||
    expectation.allowedDecisions.includes(observation.decision);
  const decisionMatch = outcomeOk && decisionOk ? 1 : 0;

  const falseInterrupt =
    expectation.mustNotInterrupt === true && isInterruptLike(observation) ? 1 : 0;

  const mustSurfaceHit =
    expectation.mustSurface === true ? (observation.outcome === "routed" ? 1 : 0) : 1;

  const normalizedMessage = normalizeText(observation.message ?? "");
  const factGrounding =
    expectation.requiredFacts.length === 0
      ? 1
      : expectation.requiredFacts.filter((fact) =>
          normalizedMessage.includes(normalizeText(fact))
        ).length / expectation.requiredFacts.length;

  const hasForbidden = expectation.forbiddenClaims.some((claim) =>
    normalizedMessage.includes(normalizeText(claim))
  );
  const forbiddenClaimFree = hasForbidden ? 0 : 1;

  const didResearch = (observation.research?.queries.length ?? 0) > 0;
  const researchMatch =
    expectation.expectResearch === undefined
      ? 1
      : didResearch === expectation.expectResearch
        ? 1
        : 0;

  const pass =
    decisionMatch === 1 &&
    falseInterrupt === 0 &&
    mustSurfaceHit === 1 &&
    factGrounding === 1 &&
    forbiddenClaimFree === 1 &&
    researchMatch === 1
      ? 1
      : 0;

  return {
    pass,
    decisionMatch,
    falseInterrupt,
    mustSurfaceHit,
    factGrounding,
    forbiddenClaimFree,
    researchMatch,
    summary: `outcome=${observation.outcome} decision=${observation.decision} match=${decisionMatch} falseInterrupt=${falseInterrupt} facts=${factGrounding.toFixed(2)}`,
  };
}

export const triageAccuracyEvaluator = {
  name: "triage-accuracy" as const,
  version: "1" as const,
  evaluate(item, output) {
    const primaryObs = output.result.observations[0];
    if (!primaryObs) {
      throw new Error(`item ${item.id} produced no proactive observations`);
    }

    const primary = scoreBranchExpectation(primaryObs, item.expected.primary);

    if (item.input.kind === "counterfactual_pair") {
      const variantObs = output.result.variantObservations?.[0];
      if (!variantObs) {
        throw new Error(
          `counterfactual_pair item ${item.id} is missing variantObservations`
        );
      }
      const variant = scoreBranchExpectation(variantObs, item.expected.variant);
      const flipped =
        primaryObs.outcome !== variantObs.outcome ||
        primaryObs.decision !== variantObs.decision;
      const flipOk = item.expected.counterfactualMustFlip === false || flipped;
      const pairPass = primary.pass === 1 && variant.pass === 1 && flipOk ? 1 : 0;

      return {
        score: {
          triagePass: pairPass,
          decisionMatch: (primary.decisionMatch + variant.decisionMatch) / 2,
          falseInterrupt: Math.max(primary.falseInterrupt, variant.falseInterrupt),
          restraintScore: 1 - Math.max(primary.falseInterrupt, variant.falseInterrupt),
          mustSurfaceHit: (primary.mustSurfaceHit + variant.mustSurfaceHit) / 2,
          factGrounding: (primary.factGrounding + variant.factGrounding) / 2,
          forbiddenClaimFree: Math.min(
            primary.forbiddenClaimFree,
            variant.forbiddenClaimFree
          ),
          researchMatch: (primary.researchMatch + variant.researchMatch) / 2,
          isCounterfactual: 1,
          counterfactualFlip: flipOk ? 1 : 0,
        },
        explanation: `base(${primary.summary}) vs variant(${variant.summary}) flipped=${flipped}`,
      };
    }

    return {
      score: {
        triagePass: primary.pass,
        decisionMatch: primary.decisionMatch,
        falseInterrupt: primary.falseInterrupt,
        restraintScore: 1 - primary.falseInterrupt,
        mustSurfaceHit: primary.mustSurfaceHit,
        factGrounding: primary.factGrounding,
        forbiddenClaimFree: primary.forbiddenClaimFree,
        researchMatch: primary.researchMatch,
        isCounterfactual: 0,
        counterfactualFlip: 0,
      },
      explanation: primary.summary,
    };
  },
} satisfies Evaluator<ProactiveEvalItem, ProactiveTriageRunResult, {}>;

export const fatigueBudgetEvaluator = {
  name: "fatigue-budget" as const,
  version: "1" as const,
  evaluate(item, output) {
    const observations = output.result.observations;
    const windowDays =
      item.input.kind === "day_stream"
        ? Math.max(item.input.windowHours / 24, 1 / 24)
        : 1;

    const interrupts = observations.filter(isInterruptLike).length;
    const signals = observations.filter(
      (obs) => obs.outcome === "routed" && obs.decision === "signal"
    ).length;

    const seenRoutedTitles = new Set<string>();
    let duplicateAlerts = 0;
    const sourceById = new Map<string, ProactiveSourceItem>();
    const sourceItems =
      item.input.kind === "counterfactual_pair"
        ? item.input.base.items
        : item.input.scenario.items;
    for (const src of sourceItems) {
      sourceById.set(src.itemId, src);
    }
    for (const obs of observations) {
      if (obs.outcome !== "routed") continue;
      const src = sourceById.get(obs.itemId);
      const dedupKey = normalizeText(src?.title || obs.itemId);
      if (seenRoutedTitles.has(dedupKey)) {
        duplicateAlerts += 1;
      } else {
        seenRoutedTitles.add(dedupKey);
      }
    }

    const dailyInterrupts = interrupts / windowDays;
    const dailySignals = signals / windowDays;

    const interruptBudgetOk =
      item.expected.maxDailyInterrupts === undefined ||
      dailyInterrupts <= item.expected.maxDailyInterrupts;
    const signalBudgetOk =
      item.expected.maxDailySignals === undefined ||
      dailySignals <= item.expected.maxDailySignals;
    const dupBudgetOk =
      item.expected.maxDuplicateAlerts === undefined ||
      duplicateAlerts <= item.expected.maxDuplicateAlerts;

    return {
      score: {
        fatiguePass: interruptBudgetOk && signalBudgetOk && dupBudgetOk ? 1 : 0,
        dailyInterrupts: Number(dailyInterrupts.toFixed(3)),
        dailySignals: Number(dailySignals.toFixed(3)),
        duplicateAlerts,
        avgPromptBytes: Math.round(
          observations.reduce((sum, obs) => sum + obs.promptBytes, 0) /
            observations.length
        ),
        avgLatencyMs: Math.round(
          observations.reduce((sum, obs) => sum + obs.latencyMs, 0) /
            observations.length
        ),
      },
      explanation: `interrupts=${interrupts} (${dailyInterrupts.toFixed(2)}/day), signals=${signals} (${dailySignals.toFixed(2)}/day), duplicates=${duplicateAlerts}`,
    };
  },
} satisfies Evaluator<ProactiveEvalItem, ProactiveTriageRunResult, {}>;

export type ProactiveTriageEvaluators = readonly [
  typeof triageAccuracyEvaluator,
  typeof fatigueBudgetEvaluator,
];

function mean(values: readonly number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((sum, v) => sum + v, 0) / values.length;
}

export const proactiveTriageAggregator = {
  version: "1",
  aggregate(results: AggregationResults<ProactiveTriageEvaluators>) {
    const triage = results["triage-accuracy"] ?? [];
    const fatigue = results["fatigue-budget"] ?? [];
    const cfScores = triage
      .filter((entry) => entry.score.isCounterfactual === 1)
      .map((entry) => entry.score.counterfactualFlip);

    return {
      triagePassRate: Number(mean(triage.map((e) => e.score.triagePass)).toFixed(4)),
      decisionMatchRate: Number(
        mean(triage.map((e) => e.score.decisionMatch)).toFixed(4)
      ),
      falseInterruptRate: Number(
        mean(triage.map((e) => e.score.falseInterrupt)).toFixed(4)
      ),
      restraintScore: Number(
        mean(triage.map((e) => e.score.restraintScore)).toFixed(4)
      ),
      factGroundingRate: Number(
        mean(triage.map((e) => e.score.factGrounding)).toFixed(4)
      ),
      forbiddenClaimFreeRate: Number(
        mean(triage.map((e) => e.score.forbiddenClaimFree)).toFixed(4)
      ),
      ...(cfScores.length > 0
        ? { counterfactualFlipRate: Number(mean(cfScores).toFixed(4)) }
        : {}),
      fatigueBudgetPassRate: Number(
        mean(fatigue.map((e) => e.score.fatiguePass)).toFixed(4)
      ),
      avgDailyInterrupts: Number(
        mean(fatigue.map((e) => e.score.dailyInterrupts)).toFixed(3)
      ),
      avgDailySignals: Number(
        mean(fatigue.map((e) => e.score.dailySignals)).toFixed(3)
      ),
      avgPromptBytes: Math.round(mean(fatigue.map((e) => e.score.avgPromptBytes))),
      avgLatencyMs: Math.round(mean(fatigue.map((e) => e.score.avgLatencyMs))),
    };
  },
};

export function unblindPick(pick: PairwisePick, aIsCandidate: boolean): PairwiseWinner {
  if (pick === "tie") return "tie";
  if (pick === "A") return aIsCandidate ? "candidate" : "baseline";
  return aIsCandidate ? "baseline" : "candidate";
}

export function resolveTwoPassWinner(
  first: PairwiseWinner,
  second: PairwiseWinner
): { winner: PairwiseWinner; consistent: boolean } {
  if (first === second) return { winner: first, consistent: true };
  if (first === "tie") return { winner: second, consistent: false };
  if (second === "tie") return { winner: first, consistent: false };
  return { winner: "tie", consistent: false };
}

function formatObservationForJudge(obs: ProactiveObservation): string {
  if (obs.outcome !== "routed") {
    return `[QUIET / NOT DELIVERED] decision=${obs.decision}${obs.reason ? ` (internal reason: ${obs.reason})` : ""}`;
  }
  const researchCount = obs.research?.queries.length ?? 0;
  return [
    `[DELIVERED TO HOME] decision=${obs.decision}${obs.role ? ` role=${obs.role}` : ""}${obs.pool ? ` pool=${obs.pool}` : ""}${researchCount > 0 ? ` (research queries=${researchCount})` : ""}`,
    "Message:",
    obs.message ?? "",
  ].join("\n");
}

export function buildBlindPairwiseTask(
  item: ProactiveSourceItem,
  portraitSummary: string,
  optionA: ProactiveObservation,
  optionB: ProactiveObservation
): string {
  return [
    "You are an impartial product quality evaluator for Comma Proactive.",
    "Compare two anonymized assistant behaviors (System A vs System B) for the same incoming item.",
    "Criteria:",
    "1. Restraint: staying QUIET on low-value noise, OTP codes, trivial acks, or routine chatter beats interrupting.",
    "2. Insight & Value: surfacing genuine deadlines, direct asks, blockers, account alerts, or non-obvious cross-source context/prep is valuable.",
    "3. Tier Appropriateness: interrupt/ask only for urgent user action; signal for calm high-value context; quiet/briefing otherwise.",
    "4. Grounding & Craft: delivered messages must be concise, accurate, non-hallucinated, and actionable.",
    "",
    `Source: ${item.toolkit} (${item.relationship})`,
    `Title: ${item.title}`,
    `Excerpt: ${item.excerpt.slice(0, 900)}`,
    ...(item.contextText ? [`Context: ${item.contextText.slice(0, 900)}`] : []),
    ...(portraitSummary ? [`User portrait: ${portraitSummary.slice(0, 600)}`] : []),
    "",
    "SYSTEM A:",
    formatObservationForJudge(optionA),
    "",
    "SYSTEM B:",
    formatObservationForJudge(optionB),
    "",
    'Return ONLY JSON matching {"winner":"A"|"B"|"tie","confidence":"high"|"medium"|"low","scores":{"restraint":"A"|"B"|"tie","insightValue":"A"|"B"|"tie","grounding":"A"|"B"|"tie","actionability":"A"|"B"|"tie"},"rationale":"concise explanation"}.',
  ].join("\n");
}

export type BlindJudgeRunner = (task: string) => Promise<BlindPairwiseJudgeAnswer>;

export function deterministicAIsCandidate(itemId: string): boolean {
  const digest = createHash("sha256").update(itemId).digest();
  return ((digest[0] ?? 0) & 1) === 0;
}

export async function runPositionDebiasedJudge(options: {
  itemId: string;
  sourceItem: ProactiveSourceItem;
  portraitSummary: string;
  baseline: ProactiveObservation;
  candidate: ProactiveObservation;
  swapPasses: boolean;
  runJudge: BlindJudgeRunner;
}): Promise<{
  winner: PairwiseWinner;
  consistent: boolean;
  dimensions: Record<
    "restraint" | "insightValue" | "grounding" | "actionability",
    PairwiseWinner
  >;
  rationale: string;
}> {
  const aIsCand1 = deterministicAIsCandidate(options.itemId);
  const firstTask = buildBlindPairwiseTask(
    options.sourceItem,
    options.portraitSummary,
    aIsCand1 ? options.candidate : options.baseline,
    aIsCand1 ? options.baseline : options.candidate
  );
  const firstAnswer = await options.runJudge(firstTask);
  const firstWinner = unblindPick(firstAnswer.winner, aIsCand1);

  if (!options.swapPasses) {
    return {
      winner: firstWinner,
      consistent: true,
      dimensions: {
        restraint: unblindPick(firstAnswer.scores.restraint, aIsCand1),
        insightValue: unblindPick(firstAnswer.scores.insightValue, aIsCand1),
        grounding: unblindPick(firstAnswer.scores.grounding, aIsCand1),
        actionability: unblindPick(firstAnswer.scores.actionability, aIsCand1),
      },
      rationale: firstAnswer.rationale,
    };
  }

  const aIsCand2 = !aIsCand1;
  const secondTask = buildBlindPairwiseTask(
    options.sourceItem,
    options.portraitSummary,
    aIsCand2 ? options.candidate : options.baseline,
    aIsCand2 ? options.baseline : options.candidate
  );
  const secondAnswer = await options.runJudge(secondTask);
  const secondWinner = unblindPick(secondAnswer.winner, aIsCand2);
  const resolved = resolveTwoPassWinner(firstWinner, secondWinner);

  return {
    winner: resolved.winner,
    consistent: resolved.consistent,
    dimensions: {
      restraint: resolveTwoPassWinner(
        unblindPick(firstAnswer.scores.restraint, aIsCand1),
        unblindPick(secondAnswer.scores.restraint, aIsCand2)
      ).winner,
      insightValue: resolveTwoPassWinner(
        unblindPick(firstAnswer.scores.insightValue, aIsCand1),
        unblindPick(secondAnswer.scores.insightValue, aIsCand2)
      ).winner,
      grounding: resolveTwoPassWinner(
        unblindPick(firstAnswer.scores.grounding, aIsCand1),
        unblindPick(secondAnswer.scores.grounding, aIsCand2)
      ).winner,
      actionability: resolveTwoPassWinner(
        unblindPick(firstAnswer.scores.actionability, aIsCand1),
        unblindPick(secondAnswer.scores.actionability, aIsCand2)
      ).winner,
    },
    rationale: firstAnswer.rationale,
  };
}

function winnerToNumeric(winner: PairwiseWinner): number {
  if (winner === "candidate") return 1;
  if (winner === "tie") return 0.5;
  return 0;
}

export function parseBlindJudgeOutput(rawText: string): BlindPairwiseJudgeAnswer {
  const start = rawText.indexOf("{");
  const end = rawText.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    throw new Error(
      `blind pairwise judge returned no JSON object: ${rawText.slice(0, 200)}`
    );
  }
  return BlindPairwiseJudgeAnswerSchema.parse(
    JSON.parse(rawText.slice(start, end + 1))
  );
}

export const shadowDiffEvaluator = {
  name: "shadow-diff" as const,
  version: "1" as const,
  evaluate(_item, output) {
    const { baseline, candidate } = output.result;
    const flip = classifyShadowFlip(baseline, candidate);
    return {
      score: {
        baselineRouted: baseline.outcome === "routed" ? 1 : 0,
        candidateRouted: candidate.outcome === "routed" ? 1 : 0,
        newlySurfaced: flip === "newly_surfaced" ? 1 : 0,
        newlySilenced: flip === "newly_silenced" ? 1 : 0,
        tierChanged: flip === "tier_changed" ? 1 : 0,
        decisionChanged:
          flip === "newly_surfaced" ||
          flip === "newly_silenced" ||
          flip === "tier_changed"
            ? 1
            : 0,
        candidateResearchUsed: (candidate.research?.queries.length ?? 0) > 0 ? 1 : 0,
        promptBytesDelta: candidate.promptBytes - baseline.promptBytes,
      },
      explanation: `flip=${flip}; baseline=${baseline.outcome}:${baseline.decision} -> candidate=${candidate.outcome}:${candidate.decision}`,
    };
  },
} satisfies Evaluator<
  ProactiveEvalItem,
  ProactiveShadowRunResult,
  ProactiveShadowEvalParams
>;

export const blindPairwiseJudgeEvaluator = {
  name: "blind-pairwise-judge" as const,
  version: "1" as const,
  async evaluate(item, output, context) {
    const { baseline, candidate } = output.result;
    const flip = classifyShadowFlip(baseline, candidate);
    if (flip === "both_quiet" && !context.params.judgeBothQuiet) {
      return {
        score: {
          judged: 0,
          candidateWin: 0.5,
          swapConsistent: 1,
          restraintWin: 0.5,
          insightWin: 0.5,
          groundingWin: 0.5,
          actionabilityWin: 0.5,
        },
        explanation: "both_quiet: skipped blind judge",
      };
    }

    const scenario =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.scenario;
    const sourceItem = scenario.items[0];
    if (!sourceItem) {
      throw new Error(`item ${item.id} has no source item for blind judging`);
    }

    const adapter = new CodexCliAdapter({
      ...context.adapterConfig.codex,
      ...(context.params.judgeModel ? { model: context.params.judgeModel } : {}),
    });

    const judged = await runPositionDebiasedJudge({
      itemId: item.id,
      sourceItem,
      portraitSummary: scenario.context.portraitStatements.join("; "),
      baseline,
      candidate,
      swapPasses: context.params.swapPasses,
      async runJudge(task) {
        const res = await adapter.runTask({ task });
        if (res.exitCode !== 0) {
          throw new Error(
            res.codexErrorMessage ??
              `blind pairwise judge exited with code ${res.exitCode}`
          );
        }
        return parseBlindJudgeOutput(res.finalAnswer);
      },
    });

    return {
      score: {
        judged: 1,
        candidateWin: winnerToNumeric(judged.winner),
        swapConsistent: judged.consistent ? 1 : 0,
        restraintWin: winnerToNumeric(judged.dimensions.restraint),
        insightWin: winnerToNumeric(judged.dimensions.insightValue),
        groundingWin: winnerToNumeric(judged.dimensions.grounding),
        actionabilityWin: winnerToNumeric(judged.dimensions.actionability),
      },
      explanation: `winner=${judged.winner} consistent=${judged.consistent}: ${judged.rationale}`,
    };
  },
} satisfies Evaluator<
  ProactiveEvalItem,
  ProactiveShadowRunResult,
  ProactiveShadowEvalParams,
  { codex: CodexAdapterConfig }
>;

export type ProactiveShadowEvaluators = readonly [
  typeof shadowDiffEvaluator,
  typeof blindPairwiseJudgeEvaluator,
];

export const proactiveShadowAggregator = {
  version: "1",
  aggregate(results: AggregationResults<ProactiveShadowEvaluators>) {
    const diffs = results["shadow-diff"] ?? [];
    const pairwise = (results["blind-pairwise-judge"] ?? []).filter(
      (entry) => entry.score.judged === 1
    );

    const candidateWins = pairwise.filter((e) => e.score.candidateWin === 1).length;
    const baselineWins = pairwise.filter((e) => e.score.candidateWin === 0).length;
    const ties = pairwise.filter((e) => e.score.candidateWin === 0.5).length;
    const decisive = candidateWins + baselineWins;

    return {
      totalItems: diffs.length,
      baselineRoutedCount: diffs.reduce((sum, e) => sum + e.score.baselineRouted, 0),
      candidateRoutedCount: diffs.reduce((sum, e) => sum + e.score.candidateRouted, 0),
      newlySurfacedCount: diffs.reduce((sum, e) => sum + e.score.newlySurfaced, 0),
      newlySilencedCount: diffs.reduce((sum, e) => sum + e.score.newlySilenced, 0),
      tierChangedCount: diffs.reduce((sum, e) => sum + e.score.tierChanged, 0),
      candidateResearchRate: Number(
        mean(diffs.map((e) => e.score.candidateResearchUsed)).toFixed(4)
      ),
      avgPromptBytesDelta: Math.round(mean(diffs.map((e) => e.score.promptBytesDelta))),
      judgedPairs: pairwise.length,
      candidateWins,
      baselineWins,
      ties,
      blindPairwiseWinRate: Number(
        mean(pairwise.map((e) => e.score.candidateWin)).toFixed(4)
      ),
      blindPairwiseWinRateExclTies: Number(
        (decisive > 0 ? candidateWins / decisive : 0.5).toFixed(4)
      ),
      blindSwapConsistencyRate: Number(
        mean(pairwise.map((e) => e.score.swapConsistent)).toFixed(4)
      ),
      restraintWinRate: Number(
        mean(pairwise.map((e) => e.score.restraintWin)).toFixed(4)
      ),
      insightWinRate: Number(mean(pairwise.map((e) => e.score.insightWin)).toFixed(4)),
    };
  },
};
