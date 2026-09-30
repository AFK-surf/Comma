import { describe, expect, it } from "vitest";
import {
  recommendationActionSchema,
  recommendationGeneratedCardSchema,
  recommendationInlineLinkSchema,
  recommendationInlineTaskSchema,
  recommendationLimits,
  mediaListCardSchema,
  recommendationSnapshotSchema,
  recommendationTemplateCatalog,
} from "../index";

describe("recommendation contract", () => {
  it("decodes one shared task into summary, hover and composer content without quoting the source in the composer", () => {
    const link = {
      href: "https://example.com/task",
      label: "Verify the fix",
      sourceId: "slack",
      promptId: "s1r1",
    };
    const snapshot = {
      protocolVersion: 1,
      templateCatalogVersion: 1,
      generation: 1,
      sourceRevision: 1,
      generatedAt: 1,
      warnings: [],
      prompts: {
        s1r1: {
          sourceId: "slack",
          objective: "Verify the fix",
          context: "Please test reconnect.",
          contextLabel: "Original context (quoted)",
        },
      },
      summary: [{ kind: "inline-link", link: { ...link, label: "Slack source" } }],
      cards: [
        {
          id: "slack",
          title: "Slack",
          fallbackText: "Slack",
          sourceIds: ["slack"],
          template: "text-list@1",
          items: [
            {
              id: "item-1",
              parts: [{ kind: "inline-link", link }],
              action: {
                type: "send_to_comma",
                label: "Use prompt",
                requiresConfirmation: true,
                promptId: "s1r1",
              },
            },
          ],
        },
      ],
    };
    const withUrl = {
      ...snapshot,
      prompts: { s1r1: { ...snapshot.prompts.s1r1, sourceUrl: link.href } },
    };
    const withUrlCard = recommendationGeneratedCardSchema.parse(
      recommendationSnapshotSchema.parse(withUrl).cards[0]
    );
    expect(withUrlCard.items[0]!.action).toMatchObject({
      prompt: "Verify the fix\n\nhttps://example.com/task",
    });
    expect(
      recommendationSnapshotSchema.safeParse({
        ...withUrl,
        prompts: {
          s1r1: { ...withUrl.prompts.s1r1, sourceUrl: "https://example.com/another" },
        },
      }).success
    ).toBe(false);
    const longUrl = "https://example.com/" + "x".repeat(1500);
    const longWire = JSON.parse(JSON.stringify(withUrl).replaceAll(link.href, longUrl));
    expect(
      recommendationGeneratedCardSchema.parse(
        recommendationSnapshotSchema.parse(longWire).cards[0]
      ).items[0]!.action
    ).toMatchObject({
      prompt: `Verify the fix\n\n${longUrl}`,
    });
    const decoded = recommendationSnapshotSchema.parse(snapshot);
    const card = recommendationGeneratedCardSchema.parse(decoded.cards[0]);
    const item = card.items[0]!;
    expect(item.action).toMatchObject({
      memberTask: true,
      prompt: "Verify the fix",
      requiresConfirmation: true,
    });
    expect(decoded.summary[0]).toMatchObject({
      link: {
        label: "Slack source",
        previewText: "Please test reconnect.",
        taskPrompt: "Verify the fix",
      },
    });
    expect(
      recommendationSnapshotSchema.safeParse({ ...snapshot, prompts: {} }).success
    ).toBe(false);
    expect(
      recommendationSnapshotSchema.safeParse({
        ...snapshot,
        prompts: {
          s1r1: {
            ...snapshot.prompts.s1r1,
            sourceId: "another-account",
          },
        },
      }).success
    ).toBe(false);
  });

  it("keeps the agent-facing catalog aligned with runtime limits", () => {
    expect(recommendationTemplateCatalog.templates).toHaveLength(2);
    expect(
      recommendationTemplateCatalog.templates.every(
        (template) => template.maxItems === recommendationLimits.itemsPerCard
      )
    ).toBe(true);
    expect(recommendationTemplateCatalog.limits.summaryTitleCharacters).toBe(
      recommendationLimits.summaryTitleCharacters
    );
    expect(recommendationTemplateCatalog.snapshot.fields.cards).toContain(
      "card ids must be unique"
    );
  });

  it("allows source-aware inline links without accepting renderer props", () => {
    const link = {
      href: "https://github.com/AFK-surf/Comma/pull/845",
      label: "PR #845",
      sourceId: "github-account",
    };

    expect(recommendationInlineLinkSchema.safeParse(link).success).toBe(true);
    expect(
      recommendationInlineLinkSchema.safeParse({
        ...link,
        iconUrl: "https://example.com/forged-icon.svg",
        presentation: "arbitrary-component",
      }).success
    ).toBe(false);
  });

  it("accepts bounded passive source excerpts without renderer props", () => {
    const link = {
      href: "https://example.com/task",
      label: "Follow up",
      previewText: "<script>plain source text</script>",
      taskPrompt: "Help verify this source request.",
    };
    expect(recommendationInlineLinkSchema.safeParse(link).success).toBe(true);
    expect(
      recommendationInlineLinkSchema.safeParse({
        ...link,
        previewText: "x".repeat(602),
      }).success
    ).toBe(false);
    expect(
      recommendationInlineLinkSchema.safeParse({
        ...link,
        taskPrompt: "x".repeat(recommendationLimits.payloadBytes + 1),
      }).success
    ).toBe(false);
    expect(
      recommendationInlineLinkSchema.safeParse({ ...link, previewHtml: "<img>" })
        .success
    ).toBe(false);
  });

  it("allows source-aware inline tasks without accepting renderer props", () => {
    const task = {
      conversationId: "comma-143",
      label: "COMMA-143",
      sourceId: "linear-account",
    };

    expect(recommendationInlineTaskSchema.safeParse(task).success).toBe(true);
    expect(
      recommendationInlineTaskSchema.safeParse({
        ...task,
        icon: "linear",
        presentation: "arbitrary-component",
      }).success
    ).toBe(false);
  });

  it("recursively rejects unknown fields in generated parts and actions", () => {
    const baseCard = {
      fallbackText: "Fallback",
      id: "card-1",
      sourceIds: ["source-1"],
      title: "Updates",
    };
    const action = {
      label: "Open",
      prompt: "Open it",
      requiresConfirmation: false,
      type: "open_task_form" as const,
    };

    const parts = [
      {
        kind: "markdown",
        rawProviderPayload: { private: "must-not-persist" },
        text: "Review",
      },
      {
        kind: "inline-link",
        link: {
          href: "https://linear.app/comma/issue/COMMA-143",
          label: "COMMA-143",
          sourceId: "source-1",
        },
        rendererProps: { component: "arbitrary" },
      },
      {
        kind: "inline-task",
        rendererProps: { component: "arbitrary" },
        task: { conversationId: "comma-143", label: "COMMA-143" },
      },
    ];

    for (const part of parts) {
      expect(
        recommendationGeneratedCardSchema.safeParse({
          ...baseCard,
          items: [{ action, id: "item-1", parts: [part] }],
          template: "text-list@1",
        }).success
      ).toBe(false);
    }

    const actions = [
      {
        href: "https://linear.app/comma/issue/COMMA-143",
        label: "Open",
        requiresConfirmation: false,
        type: "open_url",
      },
      action,
      {
        label: "Send to Comma",
        prompt: "Review it",
        requiresConfirmation: true,
        type: "send_to_comma",
      },
    ];

    for (const generatedAction of actions) {
      expect(
        recommendationGeneratedCardSchema.safeParse({
          ...baseCard,
          items: [
            {
              action: {
                ...generatedAction,
                rawProviderPayload: { private: "must-not-persist" },
              },
              id: "item-1",
              parts: [{ kind: "markdown", text: "Review" }],
            },
          ],
          template: "text-list@1",
        }).success
      ).toBe(false);
    }
  });

  it("keeps the client snapshot reader tolerant at compatibility-only boundaries", () => {
    const parsed = recommendationSnapshotSchema.parse({
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      rawServerMetadata: { revision: "legacy" },
      sourceRevision: 1,
      summary: [{ kind: "markdown", text: "Good morning." }],
      templateCatalogVersion: 1,
      warnings: [
        {
          code: "partial_sources",
          message: "A legacy source could not be read.",
          rawServerMetadata: { retry: true },
        },
      ],
    });

    expect(parsed).not.toHaveProperty("rawServerMetadata");
    expect(parsed.warnings[0]).not.toHaveProperty("rawServerMetadata");
  });

  it("keeps oversized legacy summary titles readable for client-side fallback", () => {
    const result = recommendationSnapshotSchema.safeParse({
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [
        {
          kind: "markdown",
          text: "GitHub: 3 unread notifications to review, including PR #884 for Comma Center recommendations.\n\nReview COMMA-143 before standup.",
        },
      ],
      templateCatalogVersion: 1,
      warnings: [],
    });

    expect(result.success).toBe(true);
  });

  it("keeps text cards rich and requires every rendered row to be actionable", () => {
    const base = {
      fallbackText: "Fallback",
      id: "card-1",
      sourceIds: ["source-1"],
      title: "Updates",
    };

    const textSnapshot = {
      cards: [
        {
          ...base,
          items: [
            {
              action: {
                label: "Open",
                prompt: "Open it",
                requiresConfirmation: false,
                type: "open_task_form",
              },
              id: "item-1",
              parts: [{ kind: "markdown", text: "Review " }],
            },
          ],
          template: "text-list@1",
        },
      ],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [{ kind: "markdown", text: "Good morning." }],
      templateCatalogVersion: 1,
      warnings: [],
    };

    expect(recommendationSnapshotSchema.safeParse(textSnapshot).success).toBe(true);
    const legacyCard = {
      ...base,
      items: [
        {
          id: "item-1",
          parts: [{ kind: "markdown", text: "Review " }],
        },
      ],
      template: "text-list@1",
    };

    expect(recommendationGeneratedCardSchema.safeParse(legacyCard).success).toBe(false);
    expect(
      recommendationSnapshotSchema.safeParse({
        ...textSnapshot,
        cards: [legacyCard],
      }).success
    ).toBe(true);

    expect(
      recommendationSnapshotSchema.safeParse({
        cards: [
          {
            ...base,
            items: [
              {
                description: "Description",
                id: "item-1",
                imageUrl: "https://example.com/image.png",
                title: "Article",
              },
            ],
            template: "media-list@1",
          },
        ],
        generatedAt: 1,
        generation: 1,
        protocolVersion: 1,
        sourceRevision: 1,
        summary: [{ kind: "markdown", text: "Good morning." }],
        templateCatalogVersion: 1,
        warnings: [],
      }).success
    ).toBe(false);
  });

  it("rejects side-effecting send actions without confirmation", () => {
    expect(
      recommendationActionSchema.safeParse({
        label: "Run it",
        prompt: "Update the report",
        requiresConfirmation: false,
        type: "send_to_comma",
      }).success
    ).toBe(false);
  });

  it("accepts only credential-free HTTPS image URLs for media cards", () => {
    const card = {
      fallbackText: "Release brief",
      id: "release-card",
      items: [
        {
          action: {
            label: "Open",
            prompt: "Open the release brief",
            requiresConfirmation: false,
            type: "open_task_form",
          },
          id: "release-item",
          imageUrl: "https://media.example/release.png",
          title: "Release",
        },
      ],
      sourceIds: ["source-1"],
      template: "media-list@1",
      title: "Releases",
    };

    expect(mediaListCardSchema.safeParse(card).success).toBe(true);
    expect(
      mediaListCardSchema.safeParse({
        ...card,
        items: [{ ...card.items[0], imageUrl: "HTTPS://media.example/release.png" }],
      }).success
    ).toBe(true);
    expect(
      mediaListCardSchema.safeParse({
        ...card,
        items: [{ ...card.items[0], imageUrl: "http://media.example/release.png" }],
      }).success
    ).toBe(false);
    expect(
      mediaListCardSchema.safeParse({
        ...card,
        items: [
          {
            ...card.items[0],
            imageUrl: "https://user:password@media.example/release.png",
          },
        ],
      }).success
    ).toBe(false);
  });

  it("rejects snapshots over the total item budget", () => {
    const cards = Array.from({ length: 5 }, (_, cardIndex) => ({
      fallbackText: "Fallback",
      id: `card-${cardIndex}`,
      items: Array.from({ length: 4 }, (_item, itemIndex) => ({
        action: {
          label: "Open",
          prompt: "Open it",
          requiresConfirmation: false as const,
          type: "open_task_form" as const,
        },
        id: `item-${cardIndex}-${itemIndex}`,
        parts: [{ kind: "markdown" as const, text: "Item" }],
      })),
      sourceIds: ["source-1"],
      template: "text-list@1" as const,
      title: "Document",
    }));

    expect(
      recommendationSnapshotSchema.safeParse({
        cards,
        generatedAt: 1,
        generation: 1,
        protocolVersion: 1,
        sourceRevision: 1,
        summary: [{ kind: "markdown", text: "Good morning." }],
        templateCatalogVersion: 1,
        warnings: [],
      }).success
    ).toBe(false);
  });

  it("rejects duplicate card ids before client ordering uses them", () => {
    const action = {
      label: "Open",
      prompt: "Open it",
      requiresConfirmation: false as const,
      type: "open_task_form" as const,
    };
    const card = (title: string) => ({
      fallbackText: title,
      id: "duplicate-card",
      items: [
        {
          action,
          id: `${title}-item`,
          parts: [{ kind: "markdown" as const, text: title }],
        },
      ],
      sourceIds: ["source-1"],
      template: "text-list@1" as const,
      title,
    });

    expect(
      recommendationSnapshotSchema.safeParse({
        cards: [card("First"), card("Second")],
        generatedAt: 1,
        generation: 1,
        protocolVersion: 1,
        sourceRevision: 1,
        summary: [{ kind: "markdown", text: "Good morning." }],
        templateCatalogVersion: 1,
        warnings: [],
      }).success
    ).toBe(false);
  });

  it("keeps an inert fallback for a card from a newer catalog", () => {
    const parsed = recommendationSnapshotSchema.parse({
      cards: [
        {
          fallbackText: "Three updates are available.",
          id: "future-card",
          sourceIds: ["source-1"],
          template: "timeline@2",
          title: "Updates",
        },
      ],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [{ kind: "markdown", text: "Good morning." }],
      templateCatalogVersion: 2,
      warnings: [],
    });

    expect(parsed.cards[0]?.fallbackText).toBe("Three updates are available.");
  });
});
