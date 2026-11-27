import { z } from "zod";

import {
  CftCommunicationKindSchema,
  CftContextCandidateKindSchema,
  CftSilenceReasonSchema,
  CftTriageLayerSchema,
} from "./dataset";

export const CftObservedContextCandidateSchema = z
  .object({
    kind: CftContextCandidateKindSchema,
    subject: z.string(),
    value: z.string(),
    confidence: z.enum(["explicit", "inferred"]),
    followUpBasis: z.string().optional(),
    recheckAfterHours: z.number().int().positive().optional(),
    resolutionBasis: z.string().optional(),
  })
  .strict();
export type CftObservedContextCandidate = z.infer<
  typeof CftObservedContextCandidateSchema
>;

export const CftTriageObservationSchema = z
  .object({
    itemId: z.string().min(1),
    layer: CftTriageLayerSchema,
    communicationKind: CftCommunicationKindSchema,
    silenceReason: CftSilenceReasonSchema.optional(),
    replyText: z.string().optional(),
    reactionEmoji: z.string().optional(),
    explanation: z.string().optional(),
    delegationCount: z.number().int().nonnegative().default(0),
    delegationTasks: z.array(z.string()).default([]),
    contextCandidates: z.array(CftObservedContextCandidateSchema).default([]),
    validationPassed: z.boolean().default(true),
    promptBytes: z.number().int().nonnegative(),
    llmCalls: z.number().int().nonnegative(),
    latencyMs: z.number().int().nonnegative(),
  })
  .strict();
export type CftTriageObservation = z.infer<typeof CftTriageObservationSchema>;

export const CftTriageRunResultSchema = z
  .object({
    revision: z.string().min(1),
    model: z.string().min(1),
    observation: CftTriageObservationSchema,
    variantObservation: CftTriageObservationSchema.optional(),
  })
  .strict();
export type CftTriageRunResult = z.infer<typeof CftTriageRunResultSchema>;

export const CftShadowRunResultSchema = z
  .object({
    baselineRevision: z.string().min(1),
    candidateRevision: z.string().min(1),
    model: z.string().min(1),
    baseline: CftTriageObservationSchema,
    candidate: CftTriageObservationSchema,
  })
  .strict();
export type CftShadowRunResult = z.infer<typeof CftShadowRunResultSchema>;

export const CftTriageRunParamsSchema = z
  .object({
    datasetName: z.string().min(1),
    datasetDigest: z.string().regex(/^[a-f0-9]{64}$/u),
    revision: z.string().min(1).default("HEAD"),
    systemsDir: z.string().min(1).optional(),
    resultsPath: z.string().min(1).optional(),
    model: z.string().min(1).default("codex"),
    baseUrl: z.string().url().optional(),
    timeoutMs: z.number().int().positive().default(180_000),
  })
  .strict();
export type CftTriageRunParams = z.infer<typeof CftTriageRunParamsSchema>;

export const CftShadowRunParamsSchema = z
  .object({
    datasetName: z.string().min(1),
    datasetDigest: z.string().regex(/^[a-f0-9]{64}$/u),
    baselineRevision: z.string().min(1),
    candidateRevision: z.string().min(1),
    baselineSystemsDir: z.string().min(1).optional(),
    candidateSystemsDir: z.string().min(1).optional(),
    baselineResultsPath: z.string().min(1).optional(),
    candidateResultsPath: z.string().min(1).optional(),
    model: z.string().min(1).default("codex"),
    baseUrl: z.string().url().optional(),
    timeoutMs: z.number().int().positive().default(180_000),
  })
  .strict();
export type CftShadowRunParams = z.infer<typeof CftShadowRunParamsSchema>;

export const CftShadowEvalParamsSchema = z
  .object({
    judgeModel: z.string().min(1).optional(),
    judgeBothSilent: z.boolean().default(false),
    swapPasses: z.boolean().default(true),
  })
  .strict();
export type CftShadowEvalParams = z.infer<typeof CftShadowEvalParamsSchema>;

export const CftPairwisePickSchema = z.enum(["A", "B", "tie"]);
export type CftPairwisePick = z.infer<typeof CftPairwisePickSchema>;

export const CftBlindPairwiseJudgeAnswerSchema = z
  .object({
    winner: CftPairwisePickSchema,
    confidence: z.enum(["high", "medium", "low"]),
    scores: z
      .object({
        restraint: CftPairwisePickSchema,
        helpfulness: CftPairwisePickSchema,
        grounding: CftPairwisePickSchema,
        groupTone: CftPairwisePickSchema,
      })
      .strict(),
    rationale: z.string().min(1),
  })
  .strict();
export type CftBlindPairwiseJudgeAnswer = z.infer<
  typeof CftBlindPairwiseJudgeAnswerSchema
>;

export type CftShadowFlipCategory =
  | "both_silent_no_delegation"
  | "newly_intervened"
  | "newly_silenced"
  | "communication_changed"
  | "delegation_changed"
  | "follow_up_changed"
  | "same_action_copy_diff";

export function isActiveIntervention(obs: CftTriageObservation): boolean {
  return obs.communicationKind !== "silence" || obs.delegationCount > 0;
}

export function hasFollowUpCandidate(obs: CftTriageObservation): boolean {
  return obs.contextCandidates.some((c) => c.kind === "follow_up");
}

export function classifyCftShadowFlip(
  baseline: CftTriageObservation,
  candidate: CftTriageObservation
): CftShadowFlipCategory {
  const baseActive = isActiveIntervention(baseline);
  const candActive = isActiveIntervention(candidate);
  if (!baseActive && !candActive) {
    if (hasFollowUpCandidate(baseline) !== hasFollowUpCandidate(candidate)) {
      return "follow_up_changed";
    }
    return "both_silent_no_delegation";
  }
  if (!baseActive && candActive) return "newly_intervened";
  if (baseActive && !candActive) return "newly_silenced";
  if (baseline.communicationKind !== candidate.communicationKind) {
    return "communication_changed";
  }
  if (
    baseline.communicationKind === "silence" &&
    baseline.delegationCount !== candidate.delegationCount
  ) {
    return "delegation_changed";
  }
  if (hasFollowUpCandidate(baseline) !== hasFollowUpCandidate(candidate)) {
    return "follow_up_changed";
  }
  return "same_action_copy_diff";
}
