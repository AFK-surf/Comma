import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("Home rail collapse and expansion preserve the chat floor throughout transitions", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  try {
    await page.setViewportSize({ width: 1680, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-resize@comma.local",
      token: "comma_sess_home_resize",
    });
    await page.route("**/recommendations**", async (route) => {
      await route.fulfill({
        json: {
          state: "fresh",
          settings: {
            autoEnableNewSources: true,
            schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
            sourceRevision: 1,
            sourcesCheckedAt: "2026-09-14T00:00:00Z",
            sources: [],
          },
          snapshot: {
            cards: [],
            generatedAt: Date.now(),
            generation: 1,
            protocolVersion: 1,
            sourceRevision: 1,
            summary: [
              {
                kind: "markdown",
                text: "Good morning.\n\nYour workspace is ready. Review today's tasks and make room for focused work.",
              },
            ],
            templateCatalogVersion: 1,
            warnings: [],
          },
        },
      });
    });
    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: /^Good (morning|afternoon|evening)/ })
    ).toBeVisible();
    await page.setViewportSize({ width: 1107, height: 960 });
    await expect(page.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    await expect
      .poll(() =>
        page
          .locator(".comma-home-chat")
          .evaluate((el) => Math.round(el.getBoundingClientRect().width))
      )
      .toBe(393);
    for (const [name, folded] of [
      ["greet", true],
      ["greet", false],
      ["tasks", true],
      ["tasks", false],
    ] as const) {
      const widths = await page.evaluate(async (railName) => {
        const chat = document.querySelector<HTMLElement>(".comma-home-chat")!;
        const handle = document.querySelector<HTMLButtonElement>(
          `[data-testid="home-${railName}-rail-handle"]`
        )!;
        const samples = [chat.getBoundingClientRect().width];
        // Capture the initial transition frame as well as subsequent paints.
        const sample = () => samples.push(chat.getBoundingClientRect().width);
        document.addEventListener("transitionrun", sample);
        handle.click();
        await new Promise<void>((resolve) => {
          const start = performance.now();
          const frame = () => {
            sample();
            if (performance.now() - start < 650) requestAnimationFrame(frame);
            else resolve();
          };
          requestAnimationFrame(frame);
        });
        document.removeEventListener("transitionrun", sample);
        return samples;
      }, name);
      expect(Math.min(...widths)).toBeGreaterThanOrEqual(392.9);
      if (folded) {
        // Shutting a rail frees room for the chat, which keeps its width while
        // the rail folds and takes the new one once at rest: the thread wraps
        // its text once rather than on every frame of the fold.
        expect(
          new Set(widths.map((width) => Math.round(width))).size
        ).toBeLessThanOrEqual(2);
      }
      await expect(page.getByTestId(`home-${name}-rail`)).toHaveAttribute(
        "data-folded",
        String(folded)
      );
    }
  } finally {
    await stub.close();
  }
});
