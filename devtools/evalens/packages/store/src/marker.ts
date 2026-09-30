import { z } from "zod";

import { EvalId, ExperimentName, RunId } from "@evalens/core/schemas";

export const ReindexMarkerScope = z.discriminatedUnion("type", [
  z.object({ type: z.literal("experiment"), experimentName: ExperimentName }).strict(),
  z
    .object({
      type: z.literal("run"),
      experimentName: ExperimentName,
      runId: RunId,
    })
    .strict(),
  z
    .object({
      type: z.literal("eval"),
      experimentName: ExperimentName,
      runId: RunId,
      evalId: EvalId,
    })
    .strict(),
]);
export type ReindexMarkerScope = z.infer<typeof ReindexMarkerScope>;

export const ReindexMarker = z
  .object({
    formatVersion: z.literal(1),
    detectedAt: z.coerce.date(),
    reason: z.string(),
    scope: ReindexMarkerScope,
  })
  .strict();

export type ReindexMarker = z.infer<typeof ReindexMarker>;

export const EvaluationScopeRecord = z
  .object({
    formatVersion: z.literal(1),
    experimentName: ExperimentName,
    runId: RunId,
    evalId: EvalId,
  })
  .strict();
export type EvaluationScopeRecord = z.infer<typeof EvaluationScopeRecord>;
