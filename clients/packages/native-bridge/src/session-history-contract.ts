import { z } from "zod";
import {
  sessionProductLeaseSchema,
  sessionBoundStateEnvelopeSchema,
} from "@comma/session-contract";

export const sessionHistoryTargetSchema = z.strictObject({
  groupId: z.string().min(1),
  conversationId: z.string().min(1),
  participantId: z.string().min(1),
});
export const sessionHistoryInputSchema = sessionHistoryTargetSchema.extend({
  session: sessionProductLeaseSchema,
});
export const sessionHistoryDemandSchema = sessionHistoryInputSchema.extend({
  consumerId: z.string().min(1).max(200),
});
export type SessionHistoryDemand = z.output<typeof sessionHistoryDemandSchema>;
export const sessionHistoryLoadSchema = sessionHistoryInputSchema.extend({
  mode: z.enum(["preview", "latest", "older"]),
});
export const sessionHistoryRecordSchema = z
  .object({
    id: z.string().min(1),
    kind: z.string(),
    content: z.json(),
    input_text: z.string().optional(),
    input_source: z
      .object({
        provider: z
          .enum([
            "internal",
            "telegram",
            "slack",
            "feishu",
            "wechat",
            "imessage",
            "voice",
            "signal",
          ])
          .optional(),
        actor_type: z.enum(["user", "agent", "system"]).optional(),
        conversation_kind: z.enum(["user_chat", "agent_task"]).optional(),
        chat_type: z.enum(["private", "group", "supergroup", "channel"]).optional(),
      })
      .strip()
      .optional(),
    created_at: z.union([z.number(), z.string()]).nullish(),
    timestamp_ms: z.number().nullish(),
    execution: z
      .object({
        id: z.string(),
        lane: z.enum(["model", "tool"]),
        started_at_ms: z.number(),
        first_token_at_ms: z.number().nullish(),
        observed_at_ms: z.number(),
        completed_at_ms: z.number().nullable(),
        duration_ms: z.number().nonnegative(),
        live: z.boolean().optional(),
      })
      .nullish(),
  })
  .strip();
export const sessionHistoryPageSchema = z
  .object({
    conversation_id: z.string(),
    participant_id: z.string(),
    records: z.array(sessionHistoryRecordSchema).max(50),
    has_more: z.boolean(),
    next_before: z.string().nullish(),
  })
  .strip();
export const sessionHistorySnapshotSchema = sessionHistoryTargetSchema.extend({
  records: z.array(sessionHistoryRecordSchema),
  recentRecords: z.array(sessionHistoryRecordSchema).default([]),
  liveRecords: z.array(sessionHistoryRecordSchema).default([]),
  clockOffsetMs: z.number().default(0),
  streamStatus: z
    .enum(["connecting", "live", "reconnecting", "closed"])
    .default("closed"),
  hasMore: z.boolean(),
  nextBefore: z.string().nullable(),
  status: z.enum(["idle", "loading", "ready", "error"]),
  loaded: z.enum(["none", "preview", "detail"]),
  error: z.enum(["unavailable", "forbidden"]).nullable(),
  revision: z.number().int().nonnegative(),
});
export const sessionHistoryStreamFrameSchema = z.object({
  conversation_id: z.string(),
  participant_id: z.string(),
  records: z.array(sessionHistoryRecordSchema).max(50),
  live_records: z.array(sessionHistoryRecordSchema),
  server_time_ms: z.number(),
  phase: z.enum(["recent", "update", "checkpoint"]),
  checkpoint: z.string().nullable(),
});
export type SessionHistoryStreamFrame = z.output<
  typeof sessionHistoryStreamFrameSchema
>;
export const sessionHistoryEnvelopeSchema = sessionBoundStateEnvelopeSchema(
  sessionHistorySnapshotSchema
);
export type SessionHistoryInput = z.output<typeof sessionHistoryInputSchema>;
export type SessionHistoryLoad = z.output<typeof sessionHistoryLoadSchema>;
export type SessionHistoryEnvelope = z.output<typeof sessionHistoryEnvelopeSchema>;
export type SessionHistorySnapshot = z.output<typeof sessionHistorySnapshotSchema>;
export type SessionHistoryRecord = z.output<typeof sessionHistoryRecordSchema>;
