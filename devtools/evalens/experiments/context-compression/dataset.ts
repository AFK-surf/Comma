import { z } from "zod";
import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";

const JsonObject = z.record(z.string(), z.json());
const StringOrNumber = z.union([z.string(), z.number()]);
const HistoryTurn = z
  .object({
    role: z.enum(["user", "assistant", "runtime", "summary", "tool"]),
    content: z.string(),
    label: z.string().optional(),
    metadata: JsonObject.optional(),
    summary: z.string().optional(),
    type: z.string().optional(),
    source: z.string().optional(),
    sourceRefs: JsonObject.optional(),
    sourceMessageId: z.string().optional(),
    dedupeKey: z.string().optional(),
    runtimeMessageId: z.string().optional(),
    createdAt: StringOrNumber.optional(),
    model: z.string().optional(),
    providerMeta: JsonObject.optional(),
    toolCalls: z
      .array(
        z
          .object({
            id: z.string(),
            name: z.string(),
            args: JsonObject.optional(),
          })
          .strict()
      )
      .optional(),
    toolCallId: z.string().optional(),
    toolUseId: z.string().optional(),
    toolName: z.string().optional(),
    status: z.string().optional(),
    durationMs: z.number().optional(),
    input: z.json().optional(),
    output: z.json().optional(),
    errorClass: z.string().optional(),
    errorMessage: z.string().optional(),
    startedAt: StringOrNumber.optional(),
    completedAt: StringOrNumber.optional(),
    inputTokens: z.number().optional(),
    outputTokens: z.number().optional(),
    cacheReadInputTokens: z.number().optional(),
    cacheWriteInputTokens: z.number().optional(),
    turnId: z.string().optional(),
    roundId: z.string().optional(),
    requestId: z.string().optional(),
    traceId: z.string().optional(),
  })
  .strict();

export const ContextCompressionItem = DatasetItem.extend({
  input: z
    .object({
      history: z.array(HistoryTurn),
      probe: z.object({ message: z.string() }).strict(),
      pressure: z
        .object({
          notes: z.string().optional(),
          minHistoryTurns: z.number().int().nonnegative().optional(),
        })
        .strict()
        .optional(),
    })
    .strict(),
  expected: z
    .object({
      retainedFacts: z.array(z.string()),
      forbiddenClaims: z.array(z.string()).optional(),
    })
    .strict(),
  schemaVersion: z.literal(1).optional(),
  kind: z.literal("willow.context_compression_dataset_item").optional(),
  provenance: JsonObject.optional(),
  source: JsonObject.optional(),
  generation: JsonObject.optional(),
});
export type ContextCompressionItem = LoadedDatasetItem<typeof ContextCompressionItem>;

export const loadContextCompressionDataset = defineDatasetLoader({
  name: "context-compression",
  digest: "8446b4f62c7bcbeea7bfd297b18778987cccc25ec537b9711da663165f68478c",
  itemSchema: ContextCompressionItem,
});
