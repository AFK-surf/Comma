import { createHash } from "node:crypto";
import {
  type Dataset,
  type DatasetSource,
  type LoadedDatasetItem,
  ItemId,
} from "@evalens/core";
import { z } from "zod";

export const CftTriageLayerSchema = z.enum([
  "worker_participation",
  "native_evaluator",
]);
export type CftTriageLayer = z.infer<typeof CftTriageLayerSchema>;

export const CftCommunicationKindSchema = z.enum(["reply", "reaction", "silence"]);
export type CftCommunicationKind = z.infer<typeof CftCommunicationKindSchema>;

export const CftSilenceReasonSchema = z.enum([
  "no_useful_addition",
  "already_handled",
  "insufficient_evidence",
  "no_actionable_request",
  "already_answered",
  "stale_or_changed",
  "outside_authority",
  "low_confidence",
  "duplicate",
  "worker_pending",
]);
export type CftSilenceReason = z.infer<typeof CftSilenceReasonSchema>;

export const CftTargetRouteSchema = z.enum(["none", "self", "other", "mixed"]);
export type CftTargetRoute = z.infer<typeof CftTargetRouteSchema>;

export const CftNativeLaneSchema = z.enum([
  "scheduled_recheck",
  "context_extraction",
  "general",
]);
export type CftNativeLane = z.infer<typeof CftNativeLaneSchema>;

export const CftContextCandidateKindSchema = z.enum([
  "project_fact",
  "decision",
  "follow_up",
  "follow_up_resolution",
]);
export type CftContextCandidateKind = z.infer<typeof CftContextCandidateKindSchema>;

export const CftFollowUpBasisSchema = z.enum([
  "unconfirmed",
  "reminder_confirmed",
  "agent_owned",
]);
export type CftFollowUpBasis = z.infer<typeof CftFollowUpBasisSchema>;

export const CftSourceMessageSchema = z
  .object({
    messageTs: z.string().min(1),
    actorKind: z.enum(["human", "agent", "bot", "system"]),
    actorId: z.string().optional(),
    displayName: z.string().optional(),
    text: z.string(),
    sourceRef: z.string().min(1),
    subtype: z.string().optional(),
  })
  .strict();
export type CftSourceMessage = z.infer<typeof CftSourceMessageSchema>;

export const CftChannelContextMessageSchema = z
  .object({
    ts: z.string().optional(),
    actorKind: z.enum(["human", "agent", "bot", "system"]),
    user: z.string().optional(),
    text: z.string(),
  })
  .strict();
export type CftChannelContextMessage = z.infer<typeof CftChannelContextMessageSchema>;

export const CftStillfailCoordinationSchema = z
  .object({
    disposition: z.enum([
      "defer_silence_already_handled",
      "surface_blocker_with_follow_up",
      "verify_public_evidence",
    ]),
    cardKind: z.string().optional(),
    recommendedRecheckHours: z.number().int().positive().optional(),
  })
  .strict();
export type CftStillfailCoordination = z.infer<typeof CftStillfailCoordinationSchema>;

export const CftRetainedContextSourceSchema = z
  .object({
    sourceRef: z.string().min(1),
    kind: z.string().min(1),
    subject: z.string().default(""),
    value: z.string().default(""),
    state: z.string().optional(),
    confidence: z.string().optional(),
    followUpBasis: z.string().optional(),
    recheckAfterHours: z.number().int().positive().optional(),
  })
  .strict();
export type CftRetainedContextSource = z.infer<typeof CftRetainedContextSourceSchema>;

export const CftWorkspaceFindingSchema = z
  .object({
    source: z.string().min(1),
    summary: z.string().min(1),
    url: z.string().optional(),
  })
  .strict();
export type CftWorkspaceFinding = z.infer<typeof CftWorkspaceFindingSchema>;

export const CftExpressionContextSchema = z
  .object({
    allowedEmojis: z.array(z.string().min(1)).default([]),
    guidance: z.string().optional(),
  })
  .strict();
export type CftExpressionContext = z.infer<typeof CftExpressionContextSchema>;

export const CftWorkerScenarioSchema = z
  .object({
    itemId: z.string().min(1),
    channelId: z.string().optional(),
    threadTs: z.string().optional(),
    targetRoute: CftTargetRouteSchema.default("none"),
    isRecheck: z.boolean().default(false),
    recheckContextRefs: z.array(z.string().min(1)).default([]),
    messages: z.array(CftSourceMessageSchema).min(1),
    channelContext: z
      .object({
        before: z.array(CftChannelContextMessageSchema).default([]),
        after: z.array(CftChannelContextMessageSchema).default([]),
      })
      .strict()
      .optional(),
    stillfailCoordination: CftStillfailCoordinationSchema.optional(),
    contextSources: z.array(CftRetainedContextSourceSchema).default([]),
    workspaceFindings: z.array(CftWorkspaceFindingSchema).default([]),
    expressionContext: CftExpressionContextSchema.optional(),
    taskCommand: z.string().optional(),
    capturedAt: z.string().datetime({ offset: true }).optional(),
  })
  .strict();
export type CftWorkerScenario = z.infer<typeof CftWorkerScenarioSchema>;

export const CftNativeScenarioSchema = z
  .object({
    itemId: z.string().min(1),
    lane: CftNativeLaneSchema,
    sourceMode: z.enum([
      "clickhouse_etl",
      "periodic_patrol",
      "scheduled_recheck",
      "callback",
    ]),
    targetRoute: CftTargetRouteSchema,
    channelId: z.string().optional(),
    targetSummary: z.string(),
    threadPreview: z.array(z.string()).default([]),
    modelInput: z.record(z.string(), z.json()),
    capturedAt: z.string().datetime({ offset: true }).optional(),
  })
  .strict();
export type CftNativeScenario = z.infer<typeof CftNativeScenarioSchema>;

export const CftScenarioPayloadSchema = z.discriminatedUnion("layer", [
  z
    .object({
      layer: z.literal("worker_participation"),
      worker: CftWorkerScenarioSchema,
    })
    .strict(),
  z
    .object({
      layer: z.literal("native_evaluator"),
      native: CftNativeScenarioSchema,
    })
    .strict(),
]);
export type CftScenarioPayload = z.infer<typeof CftScenarioPayloadSchema>;

export const CftTriageItemInputSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("ambient_triage"),
      payload: CftScenarioPayloadSchema,
      tags: z.array(z.string()).default([]),
    })
    .strict(),
  z
    .object({
      kind: z.literal("counterfactual_pair"),
      base: CftScenarioPayloadSchema,
      variant: CftScenarioPayloadSchema,
      mutationNote: z.string().min(1),
      tags: z.array(z.string()).default([]),
    })
    .strict(),
  z
    .object({
      kind: z.literal("shadow_diff"),
      payload: CftScenarioPayloadSchema,
      tags: z.array(z.string()).default([]),
    })
    .strict(),
]);
export type CftTriageItemInput = z.infer<typeof CftTriageItemInputSchema>;

export const CftBranchExpectationSchema = z
  .object({
    allowedCommunications: z.array(CftCommunicationKindSchema).min(1).optional(),
    allowedSilenceReasons: z.array(CftSilenceReasonSchema).min(1).optional(),
    mustStaySilent: z.boolean().optional(),
    mustAct: z.boolean().optional(),
    expectDelegation: z.boolean().optional(),
    forbidDelegation: z.boolean().optional(),
    forbidFollowUp: z.boolean().optional(),
    expectFollowUpBasis: CftFollowUpBasisSchema.optional(),
    requiredFacts: z.array(z.string().min(1)).default([]),
    forbiddenClaims: z.array(z.string().min(1)).default([]),
  })
  .strict();
export type CftBranchExpectation = z.infer<typeof CftBranchExpectationSchema>;

export const CftTriageExpectedSchema = z
  .object({
    primary: CftBranchExpectationSchema.optional(),
    variant: CftBranchExpectationSchema.optional(),
    counterfactualMustFlip: z.boolean().optional(),
  })
  .strict();
export type CftTriageExpected = z.infer<typeof CftTriageExpectedSchema>;

export const CftTriageEvalItemSchema = z
  .object({
    id: ItemId,
    input: CftTriageItemInputSchema,
    expected: CftTriageExpectedSchema,
  })
  .strict();

export type CftTriageEvalItem = LoadedDatasetItem<typeof CftTriageEvalItemSchema>;

export function payloadItemId(payload: CftScenarioPayload): string {
  return payload.layer === "worker_participation"
    ? payload.worker.itemId
    : payload.native.itemId;
}

const TEMPLATE_URL_RE = /https?:\/\/[^\s|>]+/gu;
const TEMPLATE_INCIDENT_RE = /\b0\.[a-z0-9]{6,}\b/giu;
const TEMPLATE_ULID_RE = /\b01[a-z0-9]{20,}\b/giu;
const TEMPLATE_HEX_RE = /\b[0-9a-f]{7,}\b/giu;
const TEMPLATE_SLACK_REF_RE = /<[@#!][^>]+>/gu;
const TEMPLATE_NUM_RE = /\d+(?:[.:/-]\d+)*/gu;

export function normalizeTemplateSkeleton(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replaceAll(TEMPLATE_URL_RE, "<url>")
    .replaceAll(TEMPLATE_INCIDENT_RE, "<inc>")
    .replaceAll(TEMPLATE_ULID_RE, "<id>")
    .replaceAll(TEMPLATE_HEX_RE, "<hex>")
    .replaceAll(TEMPLATE_SLACK_REF_RE, "<ref>")
    .replaceAll(TEMPLATE_NUM_RE, "<n>")
    .replaceAll(/\s+/gu, " ")
    .trim()
    .slice(0, 140);
}

export function extractCftDiversityKeys(payload: CftScenarioPayload): {
  runKey: string;
  channelKey?: string;
  threadKey?: string;
  templateKey: string;
} {
  const itemId = payloadItemId(payload);
  const runKey = itemId.replace(/^(?:worker|native)_/iu, "").toLowerCase();

  if (payload.layer === "worker_participation") {
    const w = payload.worker;
    const targetMsg = w.messages[w.messages.length - 1]?.text ?? "";
    const skeleton = normalizeTemplateSkeleton(targetMsg);
    const templateHash = createHash("sha256")
      .update(`worker:${w.isRecheck ? "recheck" : "ambient"}:${skeleton}`)
      .digest("hex")
      .slice(0, 12);
    return {
      runKey,
      ...(w.channelId ? { channelKey: w.channelId } : {}),
      ...(w.channelId && w.threadTs
        ? { threadKey: `${w.channelId}/${w.threadTs}` }
        : {}),
      templateKey: `w:${w.isRecheck ? "rc" : "am"}:${templateHash}`,
    };
  }

  const n = payload.native;
  const skeleton = normalizeTemplateSkeleton(n.targetSummary);
  const templateHash = createHash("sha256")
    .update(`native:${n.lane}:${skeleton}`)
    .digest("hex")
    .slice(0, 12);
  return {
    runKey,
    channelKey: n.channelId ?? `native:${n.lane}`,
    templateKey: `n:${n.lane}:${templateHash}`,
  };
}

export async function loadCftTriageDataset(
  source: DatasetSource | undefined,
  params: { datasetName: string; datasetDigest: string }
): Promise<Dataset<CftTriageEvalItem>> {
  if (!source) {
    throw new Error(
      `dataset source is required to load ${params.datasetName}@${params.datasetDigest}`
    );
  }
  return source.load({
    name: params.datasetName,
    digest: params.datasetDigest,
    itemSchema: CftTriageEvalItemSchema,
  });
}
