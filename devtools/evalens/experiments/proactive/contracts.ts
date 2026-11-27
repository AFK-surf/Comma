import { z } from "zod";

import { ProactiveDecisionSchema, ProactiveOutcomeSchema } from "./dataset";

export const ProactiveResearchTraceSchema = z
  .object({
    localMatches: z.number().int().nonnegative().default(0),
    queries: z
      .array(
        z
          .object({
            source: z.string().min(1),
            query: z.string().min(1),
          })
          .strict()
      )
      .default([]),
  })
  .strict();
export type ProactiveResearchTrace = z.infer<typeof ProactiveResearchTraceSchema>;

export const ProactiveObservationSchema = z
  .object({
    itemId: z.string().min(1),
    outcome: ProactiveOutcomeSchema,
    decision: ProactiveDecisionSchema,
    role: z.string().optional(),
    pool: z.string().optional(),
    message: z.string().optional(),
    reason: z.string().optional(),
    research: ProactiveResearchTraceSchema.optional(),
    promptBytes: z.number().int().nonnegative(),
    llmCalls: z.number().int().nonnegative(),
    latencyMs: z.number().int().nonnegative(),
  })
  .strict();
export type ProactiveObservation = z.infer<typeof ProactiveObservationSchema>;

export const ProactiveTriageRunResultSchema = z
  .object({
    revision: z.string().min(1),
    model: z.string().min(1),
    observations: z.array(ProactiveObservationSchema).min(1),
    variantObservations: z.array(ProactiveObservationSchema).optional(),
  })
  .strict();
export type ProactiveTriageRunResult = z.infer<typeof ProactiveTriageRunResultSchema>;

export const ProactiveShadowRunResultSchema = z
  .object({
    baselineRevision: z.string().min(1),
    candidateRevision: z.string().min(1),
    model: z.string().min(1),
    baseline: ProactiveObservationSchema,
    candidate: ProactiveObservationSchema,
  })
  .strict();
export type ProactiveShadowRunResult = z.infer<typeof ProactiveShadowRunResultSchema>;

export const ProactiveTriageRunParamsSchema = z
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
export type ProactiveTriageRunParams = z.infer<typeof ProactiveTriageRunParamsSchema>;

export const ProactiveShadowRunParamsSchema = z
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
export type ProactiveShadowRunParams = z.infer<typeof ProactiveShadowRunParamsSchema>;

export const ProactiveShadowEvalParamsSchema = z
  .object({
    judgeModel: z.string().min(1).optional(),
    judgeBothQuiet: z.boolean().default(false),
    swapPasses: z.boolean().default(true),
  })
  .strict();
export type ProactiveShadowEvalParams = z.infer<typeof ProactiveShadowEvalParamsSchema>;

export const PairwisePickSchema = z.enum(["A", "B", "tie"]);
export type PairwisePick = z.infer<typeof PairwisePickSchema>;

export const BlindPairwiseJudgeAnswerSchema = z
  .object({
    winner: PairwisePickSchema,
    confidence: z.enum(["high", "medium", "low"]),
    scores: z
      .object({
        restraint: PairwisePickSchema,
        insightValue: PairwisePickSchema,
        grounding: PairwisePickSchema,
        actionability: PairwisePickSchema,
      })
      .strict(),
    rationale: z.string().min(1),
  })
  .strict();
export type BlindPairwiseJudgeAnswer = z.infer<typeof BlindPairwiseJudgeAnswerSchema>;

export type ShadowFlipCategory =
  | "both_quiet"
  | "newly_surfaced"
  | "newly_silenced"
  | "tier_changed"
  | "both_routed_same_tier";

export function classifyShadowFlip(
  baseline: ProactiveObservation,
  candidate: ProactiveObservation
): ShadowFlipCategory {
  const baseRouted = baseline.outcome === "routed";
  const candRouted = candidate.outcome === "routed";
  if (!baseRouted && !candRouted) return "both_quiet";
  if (!baseRouted && candRouted) return "newly_surfaced";
  if (baseRouted && !candRouted) return "newly_silenced";
  if (baseline.decision !== candidate.decision) return "tier_changed";
  return "both_routed_same_tier";
}
