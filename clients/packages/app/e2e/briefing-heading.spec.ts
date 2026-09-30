import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The greeting and the paragraph gap are both wall-clock and layout concerns, so
// they are pinned in a real browser against a fixed UTC clock rather than in
// jsdom. The model's own opener must never reach the heading, and must not be
// left behind in the body either.
test.use({ timezoneId: "UTC" });

const sources = [
  {
    appId: "gmail",
    appName: "Gmail",
    connectionId: "local-gmail",
    enabled: true,
    kind: "composio",
    label: "Gmail",
  },
];

const modelOpener = "Here’s your clearest path through today";

function envelope() {
  return {
    settings: {
      autoEnableNewSources: true,
      schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
      sourceRevision: 1,
      sources,
      sourcesCheckedAt: "2026-08-27T00:00:00Z",
    },
    snapshot: {
      cards: [
        {
          fallbackText: "Review the waiting item.",
          id: "briefing-card",
          items: [
            {
              action: {
                label: "Review the waiting item",
                prompt: "Review the waiting item",
                requiresConfirmation: false,
                type: "open_task_form",
              },
              id: "briefing-item",
              parts: [{ kind: "markdown", text: "Review the waiting item" }],
            },
          ],
          sourceIds: [sources[0]!.connectionId],
          template: "text-list@1",
          title: "Waiting on you",
        },
      ],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      templateCatalogVersion: 1,
      summary: [
        // An authored title line, then two blocks. Paragraph breaks are blank
        // lines inside the markdown text — the catalog's authoring contract.
        { kind: "markdown", text: `${modelOpener}\n\nA review is waiting today.` },
        { kind: "markdown", text: "\n\nThere are also two follow-ups." },
      ],
      warnings: [],
    },
    state: "fresh",
  };
}

async function openBriefing(page: import("@playwright/test").Page, baseUrl: string) {
  await installBrowserTestSession(page, {
    apiBaseUrl: baseUrl,
    email: "briefing-heading@comma.local",
    token: "comma_sess_briefing_heading",
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
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
}

test("the briefing heading greets by time of day and drops the model's opener", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.clock.setFixedTime(new Date("2026-08-27T09:15:00Z"));
    await openBriefing(page, stub.baseUrl);

    const heading = page.getByRole("heading", {
      name: "Good morning, briefing-heading.",
    });
    await expect(heading).toBeVisible();

    // The opener is neither promoted to the heading nor left in the body.
    const summary = page.locator(".comma-recommendations-summary");
    await expect(summary).not.toContainText(modelOpener);
    await expect(summary).toContainText("A review is waiting today.");
  } finally {
    await stub.close();
  }
});

test("the briefing heading follows the clock into the afternoon", async ({ page }) => {
  const stub = await startChatSmokeStub();

  try {
    await page.clock.setFixedTime(new Date("2026-08-27T15:30:00Z"));
    await openBriefing(page, stub.baseUrl);

    await expect(
      page.getByRole("heading", { name: "Good afternoon, briefing-heading." })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("adjacent briefing paragraphs render as separated blocks", async ({ page }) => {
  const stub = await startChatSmokeStub();

  try {
    await page.clock.setFixedTime(new Date("2026-08-27T09:15:00Z"));
    await openBriefing(page, stub.baseUrl);

    const body = page.locator(".comma-recommendations-summary-body");
    await expect(body).toBeVisible();

    // Two authored blocks, not one run-together paragraph.
    // Assert per paragraph: a container-level text check concatenates them and
    // would pass either way.
    const paragraphs = body.locator(".markdown-stream p");
    await expect(paragraphs).toHaveCount(2);
    await expect(paragraphs.nth(0)).toHaveText("A review is waiting today.");
    await expect(paragraphs.nth(1)).toHaveText("There are also two follow-ups.");

    // The gap lives on the block wrapper, and the first block stays flush to
    // the title.
    const slots = body.locator(".markdown-stream .node-slot");
    await expect(slots.first()).toHaveCSS("margin-top", "0px");
    await expect(slots.nth(1)).toHaveCSS("margin-top", "8px");
    await expect(body).toHaveCSS("text-wrap", "pretty");
  } finally {
    await stub.close();
  }
});
