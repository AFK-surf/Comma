import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// A linked mail row stands for an existing Task: its card opens that Task and
// leaves once the Task ends.
test.use({ timezoneId: "UTC" });

const sources = [
  {
    appId: "slack",
    appName: "Slack",
    connectionId: "local-slack",
    enabled: true,
    kind: "composio",
    label: "Slack",
  },
];

function envelope() {
  return {
    settings: {
      autoEnableNewSources: true,
      schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
      sourceRevision: 1,
      sources,
      sourcesCheckedAt: "2026-09-04T00:00:00Z",
    },
    snapshot: {
      cards: [
        {
          fallbackText: "Reply to lin.chen",
          id: "slack",
          items: [
            {
              action: {
                label: "Reply to Lin",
                prompt: "Lin asked you to own the handoff. Draft a reply.",
                requiresConfirmation: false,
                type: "open_task_form",
              },
              id: "reply-lin",
              parts: [
                { kind: "markdown", text: "Reply to " },
                {
                  kind: "inline-link",
                  link: {
                    href: "https://comma.slack.com/archives/C0A1/p1",
                    label: "lin.chen",
                    sourceId: "local-slack",
                  },
                },
              ],
            },
          ],
          sourceIds: ["local-slack"],
          template: "text-list@1",
          title: "Slack",
        },
      ],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [{ kind: "markdown", text: "Good morning.\n\nOne reply is waiting." }],
      templateCatalogVersion: 1,
      warnings: [],
    },
    state: "fresh",
  };
}

const linkedTaskPart = {
  kind: "inline-task",
  task: {
    conversationId: "cnv_public_task_smoke",
    label: "Follow up on contract",
    sourceId: "local-slack",
  },
} as const;

// The Task chip is the whole row, or it sits inside a sentence.
const linkedRowParts = {
  chip: [linkedTaskPart],
  sentence: [
    { kind: "markdown", text: "Reply on " },
    linkedTaskPart,
    { kind: "markdown", text: " before Friday" },
  ],
} as const;

for (const [layout, status] of [
  ["chip", "active"],
  ["chip", "completed"],
  ["sentence", "active"],
  ["sentence", "completed"],
] as const) {
  test(`linked mail ${layout} row uses the existing Task and respects ${status} status`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub({
      includeTaskInInbox: true,
      taskStatus: status,
    });
    try {
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "mail-task@comma.local",
        token: "comma_sess_mail_task",
      });
      await page.route(
        `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
        async (route) => {
          const data = envelope();
          const card = data.snapshot.cards[0]!;
          await route.fulfill({
            contentType: "application/json",
            json: {
              ...data,
              snapshot: {
                ...data.snapshot,
                cards: [
                  {
                    ...card,
                    title: "Mail follow-up",
                    items: [
                      {
                        id: "linked-mail",
                        action: {
                          type: "open_url",
                          label: "Open mail",
                          href: "https://mail.google.com/mail/#inbox/m1",
                          requiresConfirmation: false,
                        },
                        parts: linkedRowParts[layout],
                      },
                    ],
                  },
                ],
              },
            },
          });
        }
      );
      await page.goto("/");
      const cards = page.locator(
        '.comma-recommendation-card[aria-label="Mail follow-up"]'
      );
      await expect(cards).toBeAttached();
      const row = page
        .getByRole("button", { name: "Follow up on contract", exact: true })
        .first();
      if (status === "active") {
        await expect(cards).toBeVisible();
        await expect(row).toBeVisible();
        // The Task chip has its own action. Press the card's own target, under
        // its padding, to exercise the row action.
        const rowAction = page
          .locator(".comma-recommendation-text-item-action")
          .first();
        await expect(rowAction).toHaveAccessibleName("Follow up on contract");
        await rowAction.click({ position: { x: 4, y: 4 } });
        const sidebar = page.getByRole("complementary", { name: "Chat sidebar" });
        await expect(sidebar).toBeVisible();
        await sidebar.getByRole("button", { name: "Open task", exact: true }).click();
        await expect(page).toHaveURL(/cnv_public_task_smoke$/);
      } else {
        // The source's only row left with its Task, so the source takes no place.
        await expect(cards).toBeHidden();
        await expect(row).toHaveCount(0);
        await expect(
          page.getByRole("button", { name: "Open mail", exact: true })
        ).toHaveCount(0);
      }
    } finally {
      await stub.close();
    }
  });
}
