import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// A routine row is a pre-task: a Task-style line with its entity chip inside.
// When the rail is too narrow it truncates the way a title does, from the
// end - the prose after the chip yields first, the opening verb and the chip
// stay legible. That order is a layout fact, so it is pinned in a real
// browser.
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

const tail = " on the weekend report handoff before the collection window closes again";

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
                { kind: "markdown", text: tail },
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

test("a pre-task row truncates from the end, keeping its verb and chip", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "routine-rows@comma.local",
      token: "comma_sess_routine_rows",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({ contentType: "application/json", json: envelope() });
          return;
        }
        await route.continue();
      }
    );
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/");

    const content = page.locator(".comma-recommendation-text-item-content").first();
    await expect(content).toContainText("Reply to");

    const geometry = await content.evaluate((element) => {
      const spans = Array.from(element.querySelectorAll("p > span"));
      const chip = element.querySelector(".comma-recommendation-inline")!;
      const [lead, rest] = spans as [HTMLElement, HTMLElement];
      const chipLabel = chip.querySelector("span")!;
      return {
        rowOverflows:
          spans.reduce((width, span) => width + span.scrollWidth, 0) +
            chip.getBoundingClientRect().width >
          element.clientWidth,
        leadIntact: lead.scrollWidth <= lead.clientWidth + 1,
        leadText: lead.textContent,
        chipIntact: chipLabel.scrollWidth <= chipLabel.clientWidth + 1,
        tailTruncates:
          rest.scrollWidth > rest.clientWidth &&
          getComputedStyle(rest).textOverflow === "ellipsis",
        order:
          lead.getBoundingClientRect().right <= chip.getBoundingClientRect().left &&
          chip.getBoundingClientRect().right <= rest.getBoundingClientRect().left + 1,
      };
    });
    expect(geometry).toEqual({
      rowOverflows: true,
      leadIntact: true,
      leadText: "Reply to ",
      chipIntact: true,
      tailTruncates: true,
      order: true,
    });
  } finally {
    await stub.close();
  }
});

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
      await expect(page.getByRole("heading", { name: "Mail follow-up" })).toBeVisible();
      const row = page
        .getByRole("button", { name: "Follow up on contract", exact: true })
        .first();
      if (status === "active") {
        await expect(row).toBeVisible();
        // The Task chip has its own action. Press the row's own target, under
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
