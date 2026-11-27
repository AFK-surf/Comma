import {
  type Dataset,
  type DatasetSource,
  type LoadedDatasetItem,
  ItemId,
} from "@evalens/core";
import { z } from "zod";

export const ProactiveDecisionSchema = z.enum([
  "interrupt",
  "ask",
  "signal",
  "briefing",
  "resolved",
  "unclear",
]);
export type ProactiveDecision = z.infer<typeof ProactiveDecisionSchema>;

export const ProactiveOutcomeSchema = z.enum(["routed", "quiet", "deferred"]);
export type ProactiveOutcome = z.infer<typeof ProactiveOutcomeSchema>;

export const ProactiveSourceItemSchema = z
  .object({
    itemId: z.string().min(1),
    toolkit: z.string().min(1),
    relationship: z.string().min(1),
    title: z.string(),
    excerpt: z.string().default(""),
    contextText: z.string().optional(),
    url: z.string().min(1),
    app: z.string().optional(),
    recipient: z.string().optional(),
    firstSeenAt: z.string().datetime({ offset: true }),
    screenedAt: z.string().datetime({ offset: true }).optional(),
    facts: z.record(z.string(), z.json()).optional(),
    providerIds: z.record(z.string(), z.json()).optional(),
  })
  .strict();
export type ProactiveSourceItem = z.infer<typeof ProactiveSourceItemSchema>;

export const ProactiveContextSnapshotSchema = z
  .object({
    locale: z.string().min(1).default("en"),
    timezone: z.string().min(1).default("UTC"),
    portraitStatements: z.array(z.string()).default([]),
    notebook: z.string().optional(),
    home: z
      .array(
        z
          .object({
            from: z.string().min(1),
            text: z.string(),
            createdAtMs: z.number().int().optional(),
          })
          .strict()
      )
      .default([]),
    knownMatters: z.array(z.record(z.string(), z.json())).default([]),
    poolItems: z.array(ProactiveSourceItemSchema).default([]),
  })
  .strict();
export type ProactiveContextSnapshot = z.infer<typeof ProactiveContextSnapshotSchema>;

export const ProactiveScenarioInputSchema = z
  .object({
    context: ProactiveContextSnapshotSchema,
    items: z.array(ProactiveSourceItemSchema).min(1),
  })
  .strict();
export type ProactiveScenarioInput = z.infer<typeof ProactiveScenarioInputSchema>;

export const ProactiveItemInputSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("triage"),
      scenario: ProactiveScenarioInputSchema,
    })
    .strict(),
  z
    .object({
      kind: z.literal("counterfactual_pair"),
      base: ProactiveScenarioInputSchema,
      variant: ProactiveScenarioInputSchema,
      mutationNote: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("day_stream"),
      windowHours: z.number().positive(),
      scenario: ProactiveScenarioInputSchema,
    })
    .strict(),
  z
    .object({
      kind: z.literal("shadow_diff"),
      scenario: ProactiveScenarioInputSchema,
      tags: z.array(z.string()).default([]),
    })
    .strict(),
]);
export type ProactiveItemInput = z.infer<typeof ProactiveItemInputSchema>;

export const ProactiveBranchExpectationSchema = z
  .object({
    allowedOutcomes: z.array(ProactiveOutcomeSchema).min(1).optional(),
    allowedDecisions: z.array(ProactiveDecisionSchema).min(1).optional(),
    mustNotInterrupt: z.boolean().optional(),
    mustSurface: z.boolean().optional(),
    requiredFacts: z.array(z.string().min(1)).default([]),
    forbiddenClaims: z.array(z.string().min(1)).default([]),
    expectResearch: z.boolean().optional(),
  })
  .strict();
export type ProactiveBranchExpectation = z.infer<
  typeof ProactiveBranchExpectationSchema
>;

export const ProactiveExpectedSchema = z
  .object({
    primary: ProactiveBranchExpectationSchema.optional(),
    variant: ProactiveBranchExpectationSchema.optional(),
    counterfactualMustFlip: z.boolean().optional(),
    maxDailyInterrupts: z.number().int().nonnegative().optional(),
    maxDailySignals: z.number().int().nonnegative().optional(),
    maxDuplicateAlerts: z.number().int().nonnegative().optional(),
  })
  .strict();
export type ProactiveExpected = z.infer<typeof ProactiveExpectedSchema>;

export const ProactiveEvalItemSchema = z
  .object({
    id: ItemId,
    input: ProactiveItemInputSchema,
    expected: ProactiveExpectedSchema,
  })
  .strict();

export type ProactiveEvalItem = LoadedDatasetItem<typeof ProactiveEvalItemSchema>;

export async function loadProactiveDataset(
  source: DatasetSource | undefined,
  params: { datasetName: string; datasetDigest: string }
): Promise<Dataset<ProactiveEvalItem>> {
  if (!source) {
    throw new Error(
      `dataset source is required to load ${params.datasetName}@${params.datasetDigest}`
    );
  }
  return source.load({
    name: params.datasetName,
    digest: params.datasetDigest,
    itemSchema: ProactiveEvalItemSchema,
  });
}
