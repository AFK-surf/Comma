// The recommendations a Routine briefing shows in the specs of
// e2e/app-shell/recommendations.chromium.test.ts: data of the test and of the
// stub's recommendations API (./recommendations.ts) alike.

export const source = {
  appId: "linear",
  appName: "Linear",
  connectionId: "local-linear",
  enabled: true,
  kind: "composio",
  label: "Linear",
};

export const customProviderSource = {
  appId: "custom-crm",
  appName: "Custom CRM",
  connectionId: "local-custom-crm",
  enabled: true,
  iconUrl: "https://assets.comma.test/custom-crm.svg",
  kind: "composio",
  label: "Custom CRM",
};

export const settings = {
  autoEnableNewSources: true,
  schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
  sourcesCheckedAt: "2026-08-17T00:00:00Z",
  sourceRevision: 1,
  sources: [source],
};

export const additionalMockCardTitles = [
  "Team follow-ups",
  "Release checks",
  "Customer signals",
  "Weekly cleanup",
];

const additionalMockCards = additionalMockCardTitles.map((title, index) => ({
  fallbackText: title,
  id: `additional-mock-card-${index + 1}`,
  items: [
    {
      action: {
        label: title,
        prompt: title,
        requiresConfirmation: false,
        type: "open_task_form",
      },
      id: `additional-mock-item-${index + 1}`,
      parts: [{ kind: "markdown", text: title }],
    },
  ],
  sourceIds: [source.connectionId],
  template: "text-list@1",
  title,
}));

export const oldMockEnvelope = {
  settings,
  snapshot: {
    cards: [
      {
        fallbackText: "Review the old mock issue.",
        id: "old-mock-card",
        items: [
          {
            action: {
              label: "Review old mock issue",
              prompt: "Review COMMA-MOCK",
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "old-mock-item",
            parts: [
              {
                kind: "markdown",
                text: "Prevent socket exhaustion recurrence and review ",
              },
              {
                kind: "inline-link",
                link: {
                  href: "https://linear.app/comma/issue/COMMA-143",
                  label: "COMMA-143",
                  sourceId: source.connectionId,
                },
              },
              { kind: "markdown", text: " and " },
              {
                kind: "inline-task",
                task: {
                  conversationId: "cnv_mock_follow_up",
                  label: "COMMA-144",
                },
              },
            ],
          },
        ],
        sourceIds: [source.connectionId],
        template: "text-list@1",
        title: "Old mock card",
      },
      {
        fallbackText: "Review the next mock issue.",
        id: "next-mock-card",
        items: [
          {
            action: {
              label: "Review next mock issue",
              prompt: "Review COMMA-NEXT",
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "next-mock-item",
            parts: [{ kind: "markdown", text: "Review the next mock issue" }],
          },
        ],
        sourceIds: [source.connectionId],
        template: "text-list@1",
        title: "Next mock card",
      },
      ...additionalMockCards,
    ],
    generatedAt: 1,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary: [{ kind: "markdown", text: "Good morning.\n\nOld mock briefing." }],
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
};
