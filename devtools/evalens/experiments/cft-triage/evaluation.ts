import { createHash } from "node:crypto";
import type { CodexAdapterConfig } from "@evalens/adapters/config";
import { CodexCliAdapter } from "@evalens/adapters/codex";
import type { AggregationResults, Evaluator } from "@evalens/core";

import {
  CftBlindPairwiseJudgeAnswerSchema,
  classifyCftShadowFlip,
  hasFollowUpCandidate,
  isActiveIntervention,
  type CftBlindPairwiseJudgeAnswer,
  type CftPairwisePick,
  type CftShadowEvalParams,
  type CftShadowRunResult,
  type CftTriageObservation,
  type CftTriageRunResult,
} from "./contracts";
import type {
  CftBranchExpectation,
  CftScenarioPayload,
  CftTriageEvalItem,
} from "./dataset";

export type CftPairwiseWinner = "candidate" | "baseline" | "tie";

function normalizeText(value: string): string {
  return value.normalize("NFKC").toLowerCase().replaceAll(/\s+/gu, " ").trim();
}

function mean(values: readonly number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((sum, v) => sum + v, 0) / values.length;
}

function searchableOutputText(obs: CftTriageObservation): string {
  return normalizeText(
    [obs.replyText ?? "", obs.explanation ?? "", ...obs.delegationTasks].join("\n")
  );
}

export function scoreCftBranchExpectation(
  obs: CftTriageObservation,
  expectation: CftBranchExpectation | undefined
): {
  pass: number;
  communicationMatch: number;
  falseIntervention: number;
  missedHelp: number;
  delegationMatch: number;
  followUpCompliant: number;
  factGrounding: number;
  forbiddenClaimFree: number;
  contractValid: number;
  summary: string;
} {
  const contractValid = obs.validationPassed ? 1 : 0;
  if (!expectation) {
    return {
      pass: contractValid,
      communicationMatch: 1,
      falseIntervention: 0,
      missedHelp: 0,
      delegationMatch: 1,
      followUpCompliant: 1,
      factGrounding: 1,
      forbiddenClaimFree: 1,
      contractValid,
      summary: `comm=${obs.communicationKind} deleg=${obs.delegationCount} valid=${contractValid}`,
    };
  }

  const commOk =
    !expectation.allowedCommunications ||
    expectation.allowedCommunications.includes(obs.communicationKind);
  const reasonOk =
    !expectation.allowedSilenceReasons ||
    obs.communicationKind !== "silence" ||
    (obs.silenceReason !== undefined &&
      expectation.allowedSilenceReasons.includes(obs.silenceReason));
  const communicationMatch = commOk && reasonOk ? 1 : 0;

  const active = isActiveIntervention(obs);
  const falseIntervention =
    expectation.mustStaySilent === true &&
    (obs.communicationKind !== "silence" ||
      (expectation.forbidDelegation === true && obs.delegationCount > 0))
      ? 1
      : 0;

  const missedHelp = expectation.mustAct === true && !active ? 1 : 0;

  let delegationOk = true;
  if (expectation.expectDelegation === true && obs.delegationCount === 0) {
    delegationOk = false;
  }
  if (expectation.forbidDelegation === true && obs.delegationCount > 0) {
    delegationOk = false;
  }
  const delegationMatch = delegationOk ? 1 : 0;

  const followUps = obs.contextCandidates.filter((c) => c.kind === "follow_up");
  let followUpOk = true;
  if (expectation.forbidFollowUp === true && followUps.length > 0) {
    followUpOk = false;
  }
  if (
    expectation.expectFollowUpBasis &&
    !followUps.some((f) => f.followUpBasis === expectation.expectFollowUpBasis)
  ) {
    followUpOk = false;
  }
  const followUpCompliant = followUpOk ? 1 : 0;

  const outputText = searchableOutputText(obs);
  const factGrounding =
    expectation.requiredFacts.length === 0
      ? 1
      : expectation.requiredFacts.filter((fact) =>
          outputText.includes(normalizeText(fact))
        ).length / expectation.requiredFacts.length;

  const publicText = normalizeText(obs.replyText ?? "");
  const hasForbidden = expectation.forbiddenClaims.some((claim) =>
    publicText.includes(normalizeText(claim))
  );
  const forbiddenClaimFree = hasForbidden ? 0 : 1;

  const pass =
    contractValid === 1 &&
    communicationMatch === 1 &&
    falseIntervention === 0 &&
    missedHelp === 0 &&
    delegationMatch === 1 &&
    followUpCompliant === 1 &&
    factGrounding === 1 &&
    forbiddenClaimFree === 1
      ? 1
      : 0;

  return {
    pass,
    communicationMatch,
    falseIntervention,
    missedHelp,
    delegationMatch,
    followUpCompliant,
    factGrounding,
    forbiddenClaimFree,
    contractValid,
    summary: `comm=${obs.communicationKind}${obs.silenceReason ? `(${obs.silenceReason})` : ""} deleg=${obs.delegationCount} fu=${followUps.length} pass=${pass}`,
  };
}

export const cftParticipationEvaluator = {
  name: "cft-participation" as const,
  version: "1" as const,
  evaluate(item, output) {
    const primaryObs = output.result.observation;
    const primary = scoreCftBranchExpectation(primaryObs, item.expected.primary);

    if (item.input.kind === "counterfactual_pair") {
      const variantObs = output.result.variantObservation;
      if (!variantObs) {
        throw new Error(
          `counterfactual_pair item ${item.id} is missing variantObservation`
        );
      }
      const variant = scoreCftBranchExpectation(variantObs, item.expected.variant);
      const flipped =
        primaryObs.communicationKind !== variantObs.communicationKind ||
        primaryObs.delegationCount > 0 !== variantObs.delegationCount > 0 ||
        hasFollowUpCandidate(primaryObs) !== hasFollowUpCandidate(variantObs);
      const flipOk = item.expected.counterfactualMustFlip === false || flipped;
      const pairPass = primary.pass === 1 && variant.pass === 1 && flipOk ? 1 : 0;

      const falseIntervention = Math.max(
        primary.falseIntervention,
        variant.falseIntervention
      );
      const missedHelp = Math.max(primary.missedHelp, variant.missedHelp);

      return {
        score: {
          triagePass: pairPass,
          communicationMatch:
            (primary.communicationMatch + variant.communicationMatch) / 2,
          falseIntervention,
          restraintScore: 1 - falseIntervention,
          missedHelp,
          helpRecall: 1 - missedHelp,
          delegationMatch: (primary.delegationMatch + variant.delegationMatch) / 2,
          followUpCompliant: Math.min(
            primary.followUpCompliant,
            variant.followUpCompliant
          ),
          factGrounding: (primary.factGrounding + variant.factGrounding) / 2,
          forbiddenClaimFree: Math.min(
            primary.forbiddenClaimFree,
            variant.forbiddenClaimFree
          ),
          contractValid: Math.min(primary.contractValid, variant.contractValid),
          isCounterfactual: 1,
          counterfactualFlip: flipOk ? 1 : 0,
          promptBytes: Math.round(
            (primaryObs.promptBytes + variantObs.promptBytes) / 2
          ),
          latencyMs: Math.round((primaryObs.latencyMs + variantObs.latencyMs) / 2),
        },
        explanation: `base(${primary.summary}) vs variant(${variant.summary}) flipped=${flipped}`,
      };
    }

    return {
      score: {
        triagePass: primary.pass,
        communicationMatch: primary.communicationMatch,
        falseIntervention: primary.falseIntervention,
        restraintScore: 1 - primary.falseIntervention,
        missedHelp: primary.missedHelp,
        helpRecall: 1 - primary.missedHelp,
        delegationMatch: primary.delegationMatch,
        followUpCompliant: primary.followUpCompliant,
        factGrounding: primary.factGrounding,
        forbiddenClaimFree: primary.forbiddenClaimFree,
        contractValid: primary.contractValid,
        isCounterfactual: 0,
        counterfactualFlip: 0,
        promptBytes: primaryObs.promptBytes,
        latencyMs: primaryObs.latencyMs,
      },
      explanation: primary.summary,
    };
  },
} satisfies Evaluator<CftTriageEvalItem, CftTriageRunResult, {}>;

export type CftTriageEvaluators = readonly [typeof cftParticipationEvaluator];

export const cftTriageAggregator = {
  version: "1",
  aggregate(results: AggregationResults<CftTriageEvaluators>) {
    const entries = results["cft-participation"] ?? [];
    const cfEntries = entries.filter((e) => e.score.isCounterfactual === 1);

    return {
      totalItems: entries.length,
      triagePassRate: Number(mean(entries.map((e) => e.score.triagePass)).toFixed(4)),
      communicationMatchRate: Number(
        mean(entries.map((e) => e.score.communicationMatch)).toFixed(4)
      ),
      falseInterventionRate: Number(
        mean(entries.map((e) => e.score.falseIntervention)).toFixed(4)
      ),
      restraintScore: Number(
        mean(entries.map((e) => e.score.restraintScore)).toFixed(4)
      ),
      missedHelpRate: Number(mean(entries.map((e) => e.score.missedHelp)).toFixed(4)),
      helpRecall: Number(mean(entries.map((e) => e.score.helpRecall)).toFixed(4)),
      delegationMatchRate: Number(
        mean(entries.map((e) => e.score.delegationMatch)).toFixed(4)
      ),
      followUpComplianceRate: Number(
        mean(entries.map((e) => e.score.followUpCompliant)).toFixed(4)
      ),
      factGroundingRate: Number(
        mean(entries.map((e) => e.score.factGrounding)).toFixed(4)
      ),
      forbiddenClaimFreeRate: Number(
        mean(entries.map((e) => e.score.forbiddenClaimFree)).toFixed(4)
      ),
      contractValidRate: Number(
        mean(entries.map((e) => e.score.contractValid)).toFixed(4)
      ),
      ...(cfEntries.length > 0
        ? {
            counterfactualFlipRate: Number(
              mean(cfEntries.map((e) => e.score.counterfactualFlip)).toFixed(4)
            ),
          }
        : {}),
      avgPromptBytes: Math.round(mean(entries.map((e) => e.score.promptBytes))),
      avgLatencyMs: Math.round(mean(entries.map((e) => e.score.latencyMs))),
    };
  },
};

export function unblindCftPick(
  pick: CftPairwisePick,
  aIsCandidate: boolean
): CftPairwiseWinner {
  if (pick === "tie") return "tie";
  if (pick === "A") return aIsCandidate ? "candidate" : "baseline";
  return aIsCandidate ? "baseline" : "candidate";
}

export function resolveTwoPassCftWinner(
  first: CftPairwiseWinner,
  second: CftPairwiseWinner
): { winner: CftPairwiseWinner; consistent: boolean } {
  if (first === second) return { winner: first, consistent: true };
  if (first === "tie") return { winner: second, consistent: false };
  if (second === "tie") return { winner: first, consistent: false };
  return { winner: "tie", consistent: false };
}

export function deterministicCftAIsCandidate(itemId: string): boolean {
  const digest = createHash("sha256").update(`cft-triage:${itemId}`).digest();
  return ((digest[0] ?? 0) & 1) === 0;
}

export function formatCftScenarioForJudge(payload: CftScenarioPayload): string {
  if (payload.layer === "worker_participation") {
    const w = payload.worker;
    const lines: string[] = [
      `Layer: worker_participation | targetRoute=${w.targetRoute} | isRecheck=${w.isRecheck}`,
    ];
    if (w.channelContext?.before.length) {
      lines.push("Channel context BEFORE:");
      for (const m of w.channelContext.before.slice(-5)) {
        lines.push(`  [${m.actorKind}] ${m.text.slice(0, 260)}`);
      }
    }
    lines.push("Thread messages:");
    for (const m of w.messages.slice(-8)) {
      lines.push(
        `  [${m.actorKind}${m.displayName ? `:${m.displayName}` : ""}] ${m.text.slice(0, 500)}`
      );
    }
    if (w.channelContext?.after.length) {
      lines.push("Channel context AFTER:");
      for (const m of w.channelContext.after.slice(0, 5)) {
        lines.push(`  [${m.actorKind}] ${m.text.slice(0, 260)}`);
      }
    }
    if (w.stillfailCoordination) {
      lines.push(
        `still.fail coordination: disposition=${w.stillfailCoordination.disposition}`
      );
    }
    if (w.contextSources.length) {
      const readable = w.contextSources.filter(
        (cs) => cs.subject.trim().length > 0 || cs.value.trim().length > 0
      );
      if (readable.length > 0) {
        lines.push("Retained project context / follow-ups:");
        for (const cs of readable.slice(0, 6)) {
          const detail = [cs.subject.trim(), cs.value.trim().slice(0, 240)]
            .filter((part) => part.length > 0)
            .join(": ");
          lines.push(
            `  - [${cs.kind}${cs.followUpBasis ? `/${cs.followUpBasis}` : ""}] ${detail}`
          );
        }
      }
    }
    if (w.workspaceFindings.length) {
      lines.push("Available verified workspace findings:");
      for (const f of w.workspaceFindings.slice(0, 6)) {
        lines.push(`  - (${f.source}) ${f.summary.slice(0, 320)}`);
      }
    }
    return lines.join("\n");
  }

  const n = payload.native;
  const lines = [
    `Layer: native_evaluator | lane=${n.lane} | sourceMode=${n.sourceMode} | targetRoute=${n.targetRoute}`,
    `Target summary: ${n.targetSummary.slice(0, 600)}`,
  ];
  if (n.threadPreview.length) {
    lines.push("Thread preview:");
    for (const line of n.threadPreview.slice(-8)) {
      lines.push(`  ${line.slice(0, 400)}`);
    }
  }
  return lines.join("\n");
}

export function formatCftObservationForJudge(obs: CftTriageObservation): string {
  const lines: string[] = [];
  if (obs.communicationKind === "reply") {
    lines.push(`[PUBLIC REPLY IN GROUP CHAT]`);
    lines.push(obs.replyText ?? "");
  } else if (obs.communicationKind === "reaction") {
    lines.push(`[REACTION ONLY] :${obs.reactionEmoji ?? "?"}:`);
  } else {
    lines.push(
      `[SILENT IN GROUP CHAT] reason=${obs.silenceReason ?? "unspecified"}${obs.explanation ? ` — ${obs.explanation}` : ""}`
    );
  }
  if (obs.delegationCount > 0) {
    lines.push(`[DELEGATIONS: ${obs.delegationCount}]`);
    for (const task of obs.delegationTasks.slice(0, 2)) {
      lines.push(`  - ${task.slice(0, 300)}`);
    }
  }
  if (obs.contextCandidates.length > 0) {
    lines.push(`[CONTEXT CANDIDATES: ${obs.contextCandidates.length}]`);
    for (const c of obs.contextCandidates.slice(0, 3)) {
      lines.push(
        `  - ${c.kind}${c.followUpBasis ? `(${c.followUpBasis})` : ""}: ${c.subject} = ${c.value.slice(0, 180)}`
      );
    }
  }
  return lines.join("\n");
}

export function buildCftBlindPairwiseTask(
  payload: CftScenarioPayload,
  optionA: CftTriageObservation,
  optionB: CftTriageObservation
): string {
  return [
    "You are an impartial product quality evaluator for Comma for Teams (CFT) group-chat Triage.",
    "Compare two anonymized assistant behaviors (System A vs System B) on the exact same Slack/team-chat snapshot.",
    "Criteria:",
    "1. Restraint: default to SILENCE on unaddressed casual chatter, venting, engineering musings, already-handled threads, unchanged scheduled rechecks, and unaddressed bot alerts when Comma lacks external system access (do NOT spam group threads asking humans for logins/credentials/logs or creating useless follow-up loops).",
    "2. Helpfulness: step in with a direct answer or focused delegation when there is an explicit ask, unanswered workspace-fact question, factual error with counterevidence, or supplied screenshot/link needing interpretation.",
    "3. Grounding: cite verified workspace facts, keep uncertainty explicit, never hallucinate checks or leak private notes.",
    "4. Group Tone & Follow-up Discipline: sound like a concise, natural colleague (no customer-support interrogations, checklists, or generic textbook lectures); avoid creating unconfirmed or loop-prone follow_ups.",
    "",
    formatCftScenarioForJudge(payload),
    "",
    "SYSTEM A:",
    formatCftObservationForJudge(optionA),
    "",
    "SYSTEM B:",
    formatCftObservationForJudge(optionB),
    "",
    'Return ONLY JSON matching {"winner":"A"|"B"|"tie","confidence":"high"|"medium"|"low","scores":{"restraint":"A"|"B"|"tie","helpfulness":"A"|"B"|"tie","grounding":"A"|"B"|"tie","groupTone":"A"|"B"|"tie"},"rationale":"concise explanation"}.',
  ].join("\n");
}

export type CftBlindJudgeRunner = (
  task: string
) => Promise<CftBlindPairwiseJudgeAnswer>;

export async function runCftPositionDebiasedJudge(options: {
  itemId: string;
  payload: CftScenarioPayload;
  baseline: CftTriageObservation;
  candidate: CftTriageObservation;
  swapPasses: boolean;
  runJudge: CftBlindJudgeRunner;
}): Promise<{
  winner: CftPairwiseWinner;
  consistent: boolean;
  dimensions: Record<
    "restraint" | "helpfulness" | "grounding" | "groupTone",
    CftPairwiseWinner
  >;
  rationale: string;
}> {
  const aIsCand1 = deterministicCftAIsCandidate(options.itemId);
  const firstTask = buildCftBlindPairwiseTask(
    options.payload,
    aIsCand1 ? options.candidate : options.baseline,
    aIsCand1 ? options.baseline : options.candidate
  );
  const firstAnswer = await options.runJudge(firstTask);
  const firstWinner = unblindCftPick(firstAnswer.winner, aIsCand1);

  if (!options.swapPasses) {
    return {
      winner: firstWinner,
      consistent: true,
      dimensions: {
        restraint: unblindCftPick(firstAnswer.scores.restraint, aIsCand1),
        helpfulness: unblindCftPick(firstAnswer.scores.helpfulness, aIsCand1),
        grounding: unblindCftPick(firstAnswer.scores.grounding, aIsCand1),
        groupTone: unblindCftPick(firstAnswer.scores.groupTone, aIsCand1),
      },
      rationale: firstAnswer.rationale,
    };
  }

  const aIsCand2 = !aIsCand1;
  const secondTask = buildCftBlindPairwiseTask(
    options.payload,
    aIsCand2 ? options.candidate : options.baseline,
    aIsCand2 ? options.baseline : options.candidate
  );
  const secondAnswer = await options.runJudge(secondTask);
  const secondWinner = unblindCftPick(secondAnswer.winner, aIsCand2);
  const resolved = resolveTwoPassCftWinner(firstWinner, secondWinner);

  return {
    winner: resolved.winner,
    consistent: resolved.consistent,
    dimensions: {
      restraint: resolveTwoPassCftWinner(
        unblindCftPick(firstAnswer.scores.restraint, aIsCand1),
        unblindCftPick(secondAnswer.scores.restraint, aIsCand2)
      ).winner,
      helpfulness: resolveTwoPassCftWinner(
        unblindCftPick(firstAnswer.scores.helpfulness, aIsCand1),
        unblindCftPick(secondAnswer.scores.helpfulness, aIsCand2)
      ).winner,
      grounding: resolveTwoPassCftWinner(
        unblindCftPick(firstAnswer.scores.grounding, aIsCand1),
        unblindCftPick(secondAnswer.scores.grounding, aIsCand2)
      ).winner,
      groupTone: resolveTwoPassCftWinner(
        unblindCftPick(firstAnswer.scores.groupTone, aIsCand1),
        unblindCftPick(secondAnswer.scores.groupTone, aIsCand2)
      ).winner,
    },
    rationale: firstAnswer.rationale,
  };
}

function winnerToNumeric(winner: CftPairwiseWinner): number {
  if (winner === "candidate") return 1;
  if (winner === "tie") return 0.5;
  return 0;
}

export function parseCftBlindJudgeOutput(rawText: string): CftBlindPairwiseJudgeAnswer {
  const start = rawText.indexOf("{");
  const end = rawText.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    throw new Error(
      `cft blind pairwise judge returned no JSON object: ${rawText.slice(0, 200)}`
    );
  }
  return CftBlindPairwiseJudgeAnswerSchema.parse(
    JSON.parse(rawText.slice(start, end + 1))
  );
}

export const cftShadowDiffEvaluator = {
  name: "cft-shadow-diff" as const,
  version: "1" as const,
  evaluate(_item, output) {
    const { baseline, candidate } = output.result;
    const flip = classifyCftShadowFlip(baseline, candidate);
    const baseFu = hasFollowUpCandidate(baseline) ? 1 : 0;
    const candFu = hasFollowUpCandidate(candidate) ? 1 : 0;

    return {
      score: {
        baselineIntervened: isActiveIntervention(baseline) ? 1 : 0,
        candidateIntervened: isActiveIntervention(candidate) ? 1 : 0,
        baselineReplied: baseline.communicationKind === "reply" ? 1 : 0,
        candidateReplied: candidate.communicationKind === "reply" ? 1 : 0,
        baselineDelegated: baseline.delegationCount > 0 ? 1 : 0,
        candidateDelegated: candidate.delegationCount > 0 ? 1 : 0,
        baselineFollowUp: baseFu,
        candidateFollowUp: candFu,
        newlyIntervened: flip === "newly_intervened" ? 1 : 0,
        newlySilenced: flip === "newly_silenced" ? 1 : 0,
        decisionChanged: flip === "both_silent_no_delegation" ? 0 : 1,
        promptBytesDelta: candidate.promptBytes - baseline.promptBytes,
      },
      explanation: `flip=${flip}; baseline=${baseline.communicationKind}(d=${baseline.delegationCount},fu=${baseFu}) -> candidate=${candidate.communicationKind}(d=${candidate.delegationCount},fu=${candFu})`,
    };
  },
} satisfies Evaluator<CftTriageEvalItem, CftShadowRunResult, CftShadowEvalParams>;

export const cftBlindPairwiseJudgeEvaluator = {
  name: "cft-blind-pairwise-judge" as const,
  version: "1" as const,
  async evaluate(item, output, context) {
    const { baseline, candidate } = output.result;
    const flip = classifyCftShadowFlip(baseline, candidate);
    if (flip === "both_silent_no_delegation" && !context.params.judgeBothSilent) {
      return {
        score: {
          judged: 0,
          candidateWin: 0.5,
          swapConsistent: 1,
          restraintWin: 0.5,
          helpfulnessWin: 0.5,
          groundingWin: 0.5,
          groupToneWin: 0.5,
        },
        explanation: "both_silent_no_delegation: skipped blind judge",
      };
    }

    const payload =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.payload;

    const adapter = new CodexCliAdapter({
      ...context.adapterConfig.codex,
      ...(context.params.judgeModel ? { model: context.params.judgeModel } : {}),
    });

    const judged = await runCftPositionDebiasedJudge({
      itemId: item.id,
      payload,
      baseline,
      candidate,
      swapPasses: context.params.swapPasses,
      async runJudge(task) {
        const res = await adapter.runTask({ task });
        if (res.exitCode !== 0) {
          throw new Error(
            res.codexErrorMessage ??
              `cft blind pairwise judge exited with code ${res.exitCode}`
          );
        }
        return parseCftBlindJudgeOutput(res.finalAnswer);
      },
    });

    return {
      score: {
        judged: 1,
        candidateWin: winnerToNumeric(judged.winner),
        swapConsistent: judged.consistent ? 1 : 0,
        restraintWin: winnerToNumeric(judged.dimensions.restraint),
        helpfulnessWin: winnerToNumeric(judged.dimensions.helpfulness),
        groundingWin: winnerToNumeric(judged.dimensions.grounding),
        groupToneWin: winnerToNumeric(judged.dimensions.groupTone),
      },
      explanation: `winner=${judged.winner} consistent=${judged.consistent}: ${judged.rationale}`,
    };
  },
} satisfies Evaluator<
  CftTriageEvalItem,
  CftShadowRunResult,
  CftShadowEvalParams,
  { codex: CodexAdapterConfig }
>;

export type CftShadowEvaluators = readonly [
  typeof cftShadowDiffEvaluator,
  typeof cftBlindPairwiseJudgeEvaluator,
];

export const cftShadowAggregator = {
  version: "1",
  aggregate(results: AggregationResults<CftShadowEvaluators>) {
    const diffs = results["cft-shadow-diff"] ?? [];
    const pairwise = (results["cft-blind-pairwise-judge"] ?? []).filter(
      (entry) => entry.score.judged === 1
    );

    const candidateWins = pairwise.filter((e) => e.score.candidateWin === 1).length;
    const baselineWins = pairwise.filter((e) => e.score.candidateWin === 0).length;
    const ties = pairwise.filter((e) => e.score.candidateWin === 0.5).length;
    const decisive = candidateWins + baselineWins;

    return {
      totalItems: diffs.length,
      baselineIntervenedCount: diffs.reduce(
        (sum, e) => sum + e.score.baselineIntervened,
        0
      ),
      candidateIntervenedCount: diffs.reduce(
        (sum, e) => sum + e.score.candidateIntervened,
        0
      ),
      baselineRepliedCount: diffs.reduce((sum, e) => sum + e.score.baselineReplied, 0),
      candidateRepliedCount: diffs.reduce(
        (sum, e) => sum + e.score.candidateReplied,
        0
      ),
      baselineDelegatedCount: diffs.reduce(
        (sum, e) => sum + e.score.baselineDelegated,
        0
      ),
      candidateDelegatedCount: diffs.reduce(
        (sum, e) => sum + e.score.candidateDelegated,
        0
      ),
      baselineFollowUpCount: diffs.reduce(
        (sum, e) => sum + e.score.baselineFollowUp,
        0
      ),
      candidateFollowUpCount: diffs.reduce(
        (sum, e) => sum + e.score.candidateFollowUp,
        0
      ),
      newlyIntervenedCount: diffs.reduce((sum, e) => sum + e.score.newlyIntervened, 0),
      newlySilencedCount: diffs.reduce((sum, e) => sum + e.score.newlySilenced, 0),
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
      helpfulnessWinRate: Number(
        mean(pairwise.map((e) => e.score.helpfulnessWin)).toFixed(4)
      ),
      groundingWinRate: Number(
        mean(pairwise.map((e) => e.score.groundingWin)).toFixed(4)
      ),
      groupToneWinRate: Number(
        mean(pairwise.map((e) => e.score.groupToneWin)).toFixed(4)
      ),
    };
  },
};
