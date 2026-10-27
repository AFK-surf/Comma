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
  // The latest read failed for a reason only the member can fix by
  // reconnecting the source, such as a missing scope or a revoked grant.
  needsReconnect: z.boolean().optional(),
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

// One run of a quote line: words, a Slack mention or channel, or a link. A
// run has an href only where it may open: an http(s) URL without credentials,
// or a Slack ID in the link's own Slack workspace. A link whose label is a
// shortened URL keeps the full address as its title.
export const recommendationQuoteRunSchema = z
  .object({
    href: z.url().optional(),
    kind: z.enum(["text", "mention", "channel", "link"]),
    text: z.string().max(601),
    title: z.string().optional(),
  })
  .strict();

export const recommendationQuoteLineSchema = z
  .object({
    listItem: z.literal(true).optional(),
    runs: z.array(recommendationQuoteRunSchema).max(601),
  })
  .strict();

export const recommendationInlineLinkSchema = z
  .object({
    href: z.url(),
    previewText: z.string().max(601).optional(),
    // Expanded prompts carry the objective and the intact source URL. The
    // bounded excerpt stays in previewText.
    taskPrompt: z.string().max(recommendationLimits.payloadBytes).optional(),
    // Expanded prompts also carry the objective alone, which leads a member
    // task's Routine card.
    objective: z.string().min(1).max(100).optional(),
    // previewText as read for display (recommendationSourceQuote). It is
    // derived on every read, so a decoded link reads back as it is.
    quote: z.array(recommendationQuoteLineSchema).max(601).optional(),
    label: z.string().min(1).max(120),
    sourceId: z.string().min(1).max(128).optional(),
  })
  .strict()
  .transform(
    ({
      quote: _quote,
      ...link
    }): typeof link & { quote?: RecommendationQuoteLine[] } =>
      link.previewText
        ? { ...link, quote: recommendationSourceQuote(link.previewText, link.href) }
        : link
  );

export type RecommendationQuoteRun = z.infer<typeof recommendationQuoteRunSchema>;
export type RecommendationQuoteLine = z.infer<typeof recommendationQuoteLineSchema>;

// The server renders every product's quote in one markup
// (CommaWeb.RecommendationSourceQuote): one line per source line, "• " before
// a list item, <https://…|label> links, Slack <@U…|name> and <#C…|name>
// mentions, and &lt; &gt; &amp; for literal characters. Only these tokens and
// bare http(s) URLs are read; everything else stays text. Every client shows
// these lines as they are, so the markup is read here once.
export function recommendationSourceQuote(
  text: string,
  sourceHref: string
): RecommendationQuoteLine[] {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "")
    .map((line) =>
      line.startsWith("• ")
        ? { listItem: true as const, runs: quoteRuns(line.slice(2), sourceHref) }
        : { runs: quoteRuns(line, sourceHref) }
    );
}

const quoteTokens =
  /<[@#][A-Z0-9]+(?:\|[^<>]+)?>|<https?:\/\/[^<>]+>|https?:\/\/(?:(?!&[lg]t;)[^\s<>"'])+/g;

// Tokens are read before entities are decoded, so escaped text stays text.
const decodeQuote = (text: string) =>
  text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

function quoteRuns(text: string, sourceHref: string): RecommendationQuoteRun[] {
  const runs: RecommendationQuoteRun[] = [];
  const words = (value: string) => {
    if (value) runs.push({ kind: "text", text: decodeQuote(value) });
  };
  let cursor = 0;
  for (const match of text.matchAll(quoteTokens)) {
    words(text.slice(cursor, match.index));
    const raw = match[0];
    let trailing = "";
    if (/^<[@#]/.test(raw)) {
      const [id, name] = raw.slice(2, -1).split("|");
      const source = safeHttpUrl(sourceHref);
      const mention = raw[1] === "@";
      runs.push({
        kind: mention ? "mention" : "channel",
        text: raw[1] + decodeQuote(name || id!),
        // A Slack user/channel ID is meaningful only in its source workspace.
        ...(source && source.hostname.endsWith(".slack.com") && id
          ? {
              href: new URL(mention ? `/team/${id}` : `/archives/${id}`, source.origin)
                .href,
            }
          : {}),
      });
    } else if (raw.startsWith("<")) {
      const [url, ...name] = raw.slice(1, -1).split("|");
      const target = safeHttpUrl(decodeQuote(url!));
      runs.push({
        kind: "link",
        ...(name.length
          ? { text: decodeQuote(name.join("|")) }
          : target
            ? { text: quoteUrlLabel(target), title: target.href }
            : { text: decodeQuote(url!) }),
        ...(target ? { href: target.href } : {}),
      });
    } else {
      // A bare URL leaves its closing punctuation, and a bracket it did not
      // open, to the words after it.
      let url = raw.replace(/[.,;!?。，；！？]+$/, "");
      for (const [open, close] of [
        ["(", ")"],
        ["[", "]"],
        ["{", "}"],
      ] as const) {
        while (
          url.endsWith(close) &&
          url.split(close).length > url.split(open).length
        ) {
          url = url.slice(0, -1);
        }
      }
      trailing = raw.slice(url.length);
      const target = safeHttpUrl(decodeQuote(url));
      runs.push(
        target
          ? {
              kind: "link",
              text: quoteUrlLabel(target),
              title: target.href,
              href: target.href,
            }
          : { kind: "link", text: decodeQuote(url) }
      );
    }
    words(trailing);
    cursor = match.index + raw.length;
  }
  words(text.slice(cursor));
  return runs;
}

// A link without a label names its host and path. A long path keeps only its
// last segment, so an image or tracking URL does not fill the preview.
function quoteUrlLabel(url: URL) {
  const path = url.pathname.replace(/\/$/, "");
  const segments = path.split("/").filter(Boolean);
  return `${url.host}${path}`.length > 40 && segments.length > 1
    ? `${url.host}/…/${segments.at(-1)}`
    : `${url.host}${path}`;
}

function safeHttpUrl(value: string): URL | undefined {
  try {
    const url = new URL(value);
    if (["https:", "http:"].includes(url.protocol) && !url.username && !url.password)
      return url;
  } catch {
    // Invalid URLs remain inert source text.
  }
  return undefined;
}

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
      // Decoded with memberTask: the source of the member's task, such as a
      // Linear issue or a Gmail message. The prompt names the URL as text;
      // these fields let the client show the source's mark and open the item.
      sourceId: z.string().min(1).max(128).optional(),
      sourceUrl: z.url().optional(),
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
        return {
          ...rest,
          prompt: prompt.text,
          memberTask: true,
          sourceId: prompt.sourceId,
          ...(prompt.sourceUrl ? { sourceUrl: prompt.sourceUrl } : {}),
        };
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
      return {
        ...rest,
        objective: prompt.objective,
        previewText: prompt.context,
        taskPrompt: prompt.text,
      };
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
  "insufficient_credits",
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
