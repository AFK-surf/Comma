import { z } from "zod";
import recommendationTemplateCatalogJson from "../catalog/recommendation-template-catalog.v1.json" with { type: "json" };

export const recommendationProtocolVersion = 1 as const;
export const recommendationTemplateCatalogVersion = 1 as const;

export const recommendationLimits = {
  cards: 6,
  itemsPerCard: 4,
  payloadBytes: 64 * 1024,
  sources: 12,
  summaryCharacters: 1_200,
  summaryTitleCharacters: 48,
  summaryParts: 24,
  totalItems: 18,
} as const;

export const recommendationSourceKindSchema = z.enum([
  "native_mcp_oauth",
  "managed_oauth",
  "composio",
  "im_connect",
]);

export const recommendationSourceSchema = z.object({
  appId: z.string().min(1).max(128),
  appName: z.string().min(1).max(80),
  connectionId: z.string().min(1).max(256),
  enabled: z.boolean(),
  iconUrl: z.url().optional(),
  kind: recommendationSourceKindSchema,
  label: z.string().min(1).max(120),
});

export const recommendationScheduleSchema = z.object({
  enabled: z.boolean(),
  hour: z.number().int().min(0).max(23),
  minute: z.number().int().min(0).max(59),
  timezone: z.string().min(1).max(64),
});

export const recommendationSettingsSchema = z.object({
  relevanceMode: z.enum(["generic", "member"]).optional(),
  autoEnableNewSources: z.boolean(),
  schedule: recommendationScheduleSchema,
  sourcesCheckedAt: z.iso.datetime().nullable(),
  sourceRevision: z.number().int().nonnegative(),
  sources: z.array(recommendationSourceSchema).max(recommendationLimits.sources),
});

export const recommendationInlineLinkSchema = z
  .object({
    href: z.url(),
    previewText: z.string().max(601).optional(),
    // Expanded prompts carry the objective and the intact source URL. The
    // bounded excerpt stays in previewText.
    taskPrompt: z.string().max(recommendationLimits.payloadBytes).optional(),
    label: z.string().min(1).max(120),
    sourceId: z.string().min(1).max(128).optional(),
  })
  .strict();

export const recommendationInlineTaskSchema = z
  .object({
    conversationId: z.string().min(1),
    label: z.string().min(1).max(120),
    sourceId: z.string().min(1).max(128).optional(),
    status: z.string().max(64).optional(),
  })
  .strict();

export const recommendationDocumentPartSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("markdown"), text: z.string().max(1_200) }).strict(),
  z
    .object({ kind: z.literal("inline-link"), link: recommendationInlineLinkSchema })
    .strict(),
  z
    .object({ kind: z.literal("inline-task"), task: recommendationInlineTaskSchema })
    .strict(),
]);

export const recommendationDocumentSchema = z
  .array(recommendationDocumentPartSchema)
  .min(1)
  .max(recommendationLimits.summaryParts);

export const recommendationActionSchema = z.discriminatedUnion("type", [
  z
    .object({
      href: z.url(),
      label: z.string().min(1).max(80),
      requiresConfirmation: z.literal(false),
      type: z.literal("open_url"),
    })
    .strict(),
  z
    .object({
      label: z.string().min(1).max(80),
      prompt: z.string().min(1).max(1_200),
      requiresConfirmation: z.boolean(),
      type: z.literal("open_task_form"),
    })
    .strict(),
  z
    .object({
      label: z.string().min(1).max(80),
      // Set when the prompt is decoded from a Snapshot prompt: it is the
      // member's own task title, then its source URL. The composer asks Comma for
      // help with that task instead of handing the task to Comma.
      memberTask: z.literal(true).optional(),
      prompt: z.string().min(1).max(recommendationLimits.payloadBytes),
      requiresConfirmation: z.literal(true),
      type: z.literal("send_to_comma"),
    })
    .strict(),
]);

const cardBaseSchema = z.object({
  fallbackText: z.string().min(1).max(1_200),
  id: z.string().min(1).max(128),
  sourceIds: z
    .array(z.string().min(1).max(256))
    .min(1)
    .max(recommendationLimits.sources),
  title: z.string().min(1).max(80),
});

const textListItemSchema = z
  .object({
    action: recommendationActionSchema,
    id: z.string().min(1).max(128),
    parts: recommendationDocumentSchema,
  })
  .strict();

const mediaListItemSchema = z
  .object({
    action: recommendationActionSchema,
    description: z.string().max(240).optional(),
    id: z.string().min(1).max(128),
    imageUrl: z.url().refine((value) => {
      if (!/^https:\/\//i.test(value)) return false;
      const authority = value.slice("https://".length).split(/[/?#]/, 1)[0] ?? "";
      return authority.length > 0 && !authority.includes("@");
    }, "Media images must use credential-free HTTPS."),
    title: z.string().min(1).max(160),
  })
  .strict();

export const textListCardSchema = cardBaseSchema
  .extend({
    footerAction: recommendationActionSchema.optional(),
    items: z.array(textListItemSchema).min(1).max(recommendationLimits.itemsPerCard),
    template: z.literal("text-list@1"),
  })
  .strict();

export const mediaListCardSchema = cardBaseSchema
  .extend({
    items: z.array(mediaListItemSchema).min(1).max(recommendationLimits.itemsPerCard),
    template: z.literal("media-list@1"),
  })
  .strict();

export const recommendationGeneratedCardSchema = z.discriminatedUnion("template", [
  textListCardSchema,
  mediaListCardSchema,
]);

const legacyTextListCardSchema = cardBaseSchema
  .extend({
    footerAction: recommendationActionSchema.optional(),
    items: z
      .array(
        z
          .object({
            id: z.string().min(1).max(128),
            parts: recommendationDocumentSchema,
          })
          .strict()
      )
      .min(1)
      .max(recommendationLimits.itemsPerCard),
    template: z.literal("text-list@1"),
  })
  .strict();

const recommendationFallbackCardSchema = cardBaseSchema.extend({
  items: z.array(z.unknown()).max(recommendationLimits.itemsPerCard).optional(),
  template: z
    .string()
    .min(1)
    .refine(
      (template) => !["text-list@1", "media-list@1"].includes(template),
      "Known templates must use their strict schema"
    ),
});

export const recommendationCardSchema = z.union([
  recommendationGeneratedCardSchema,
  legacyTextListCardSchema,
  recommendationFallbackCardSchema,
]);

export const recommendationWarningSchema = z.object({
  code: z.enum(["partial_sources", "stale", "source_changed", "generation_failed"]),
  message: z.string().min(1).max(240),
  sourceIds: z
    .array(z.string().min(1).max(256))
    .max(recommendationLimits.sources)
    .optional(),
});

// This is the read-side compatibility schema: root and warning objects stay
// tolerant so newer server metadata can be stripped by older clients. The
// server publication validator remains recursively closed, and executable
// generated cards/parts/actions above are strict before rendering.
const recommendationPromptSchema = z
  .object({
    sourceId: z.string().min(1).max(128),
    sourceUrl: z.url().optional(),
    objective: z.string().min(1).max(100),
    context: z.string().max(601),
    contextLabel: z.string().min(1).max(80),
  })
  .strict();

const recommendationPromptsSchema = z
  .record(z.string().min(1).max(128), recommendationPromptSchema)
  .refine((prompts) => Object.keys(prompts).length <= recommendationLimits.totalItems);

// Storage and transport keep each task's content once. Decode it at the API
// boundary into the existing view shape, so hover and composer actions read
// the same server-owned content without another request or render effect.
// The composer gets the objective and source URL. The quoted context is only
// hover content: it is evidence for the member, not text they send.
function expandRecommendationPrompts(
  input: unknown,
  context: z.RefinementCtx
): unknown {
  if (!input || typeof input !== "object" || !("prompts" in input)) return input;
  const parsed = recommendationPromptsSchema.safeParse(input.prompts);
  if (!parsed.success) {
    context.addIssue({ code: "custom", message: "Invalid recommendation prompts" });
    return z.NEVER;
  }
  const prompts = parsed.data;
  const used = new Set<string>();
  const expanded = new Map(
    Object.entries(prompts).map(([id, prompt]) => [
      id,
      {
        ...prompt,
        text: `${prompt.objective}${prompt.sourceUrl ? `\n\n${prompt.sourceUrl}` : ""}`,
      },
    ])
  );
  const expand = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(expand);
    if (!value || typeof value !== "object") return value;
    const object = value as Record<string, unknown>;
    if ("promptId" in object) {
      const { promptId, ...rest } = object;
      const prompt = typeof promptId === "string" ? expanded.get(promptId) : undefined;
      if (!prompt) {
        context.addIssue({ code: "custom", message: "Unknown recommendation prompt" });
        return z.NEVER;
      }
      used.add(promptId as string);
      if (object.type === "send_to_comma")
        return { ...rest, prompt: prompt.text, memberTask: true };
      if (
        object.sourceId !== prompt.sourceId ||
        (prompt.sourceUrl !== undefined && object.href !== prompt.sourceUrl)
      ) {
        context.addIssue({
          code: "custom",
          message: "Recommendation prompt source mismatch",
        });
        return z.NEVER;
      }
      return { ...rest, previewText: prompt.context, taskPrompt: prompt.text };
    }
    return Object.fromEntries(
      Object.entries(object).map(([key, child]) => [key, expand(child)])
    );
  };
  const { prompts: _prompts, ...snapshot } = input as Record<string, unknown>;
  const result = expand(snapshot);
  if (used.size !== Object.keys(prompts).length) {
    context.addIssue({ code: "custom", message: "Unreferenced recommendation prompt" });
  }
  return result;
}

const recommendationSnapshotViewSchema = z
  .object({
    cards: z.array(recommendationCardSchema).max(recommendationLimits.cards),
    generatedAt: z.number().int().nonnegative(),
    generation: z.number().int().positive(),
    protocolVersion: z.literal(recommendationProtocolVersion),
    sourceRevision: z.number().int().nonnegative(),
    summary: recommendationDocumentSchema,
    templateCatalogVersion: z.number().int().positive(),
    warnings: z.array(recommendationWarningSchema).max(recommendationLimits.sources),
  })
  .superRefine((snapshot, context) => {
    const seenCardIds = new Set<string>();
    snapshot.cards.forEach((card, index) => {
      if (seenCardIds.has(card.id)) {
        context.addIssue({
          code: "custom",
          message: "Recommendation card IDs must be unique",
          path: ["cards", index, "id"],
        });
      }
      seenCardIds.add(card.id);
    });

    const itemCount = snapshot.cards.reduce(
      (sum, card) => sum + (card.items?.length ?? 0),
      0
    );
    if (itemCount > recommendationLimits.totalItems) {
      context.addIssue({
        code: "custom",
        message: `Snapshot exceeds ${recommendationLimits.totalItems} total items`,
        path: ["cards"],
      });
    }
    const summaryCharacters = snapshot.summary.reduce(
      (sum, part) =>
        sum +
        (part.kind === "markdown"
          ? part.text.length
          : part.kind === "inline-link"
            ? part.link.label.length
            : part.task.label.length),
      0
    );
    if (summaryCharacters > recommendationLimits.summaryCharacters) {
      context.addIssue({
        code: "custom",
        message: `Summary exceeds ${recommendationLimits.summaryCharacters} characters`,
        path: ["summary"],
      });
    }
  });

export const recommendationSnapshotSchema = z.preprocess(
  expandRecommendationPrompts,
  recommendationSnapshotViewSchema
);

// Why the last generation failed, as a bounded class. Present with the
// `error` and `stale` states; the stored failure text never crosses the API.
export const recommendationLastErrorSchema = z.enum([
  "invalid_projection",
  "renderer_declined",
  "source_collection_failed",
  "member_identity_required",
  "member_source_configuration_required",
  "delivery_failed",
  "timed_out",
  "failed",
]);

export const recommendationEnvelopeSchema = z.object({
  lastError: recommendationLastErrorSchema.nullable().optional(),
  settings: recommendationSettingsSchema,
  snapshot: recommendationSnapshotSchema.nullable(),
  state: z.enum(["empty", "fresh", "refreshing", "stale", "error"]),
});

export const recommendationTemplateCatalog = recommendationTemplateCatalogJson;

export type RecommendationAction = z.infer<typeof recommendationActionSchema>;
export type RecommendationCard = z.infer<typeof recommendationCardSchema>;
export type RecommendationDocumentPart = z.infer<
  typeof recommendationDocumentPartSchema
>;
export type RecommendationEnvelope = z.infer<typeof recommendationEnvelopeSchema>;
export type RecommendationGeneratedCard = z.infer<
  typeof recommendationGeneratedCardSchema
>;
export type RecommendationLastError = z.infer<typeof recommendationLastErrorSchema>;
export type RecommendationSettings = z.infer<typeof recommendationSettingsSchema>;
export type RecommendationSnapshot = z.infer<typeof recommendationSnapshotSchema>;
export type RecommendationSource = z.infer<typeof recommendationSourceSchema>;
