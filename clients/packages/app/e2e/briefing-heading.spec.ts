import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The rail's focus treatment is a layout concern, pinned in a real browser
// against a fixed UTC clock. The greeting itself is covered by the
// RecommendationRail tests.
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
      summary: [{ kind: "markdown", text: "Good morning.\n\nA review is waiting." }],
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

test("the briefing scroll area takes keyboard focus without the browser's focus ring", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.clock.setFixedTime(new Date("2026-08-27T09:15:00Z"));
    await openBriefing(page, stub.baseUrl);

    const viewport = page.locator(
      ".comma-recommendations-scroll > .comma-scroll-area__viewport"
    );
    await expect(viewport).toBeVisible();

    // A key press first, so the focus that follows matches :focus-visible and
    // would draw the default ring around the whole rail.
    await page.keyboard.press("Shift");
    await viewport.focus();
    await expect(viewport).toBeFocused();
    await expect(viewport).toHaveCSS("outline-style", "none");
  } finally {
    await stub.close();
  }
});
