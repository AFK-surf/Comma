import { expect, test } from "@playwright/test";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const metric = (result: { metrics: { name: string; value: number }[] }, name: string) =>
  result.metrics.find((entry) => entry.name === name)?.value ?? 0;

test("web routes and every Settings category open, scroll and can be revisited", async ({
  page,
}, testInfo) => {
  test.setTimeout(90_000);
  const stub = await startChatSmokeStub();
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "settings-pages@example.com",
      token: "comma_sess_settings_pages",
    });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    await page.goto("/");
    await expect(page.locator('[data-nav-id="home"] a')).toBeVisible();
    const routeObservations: unknown[] = [];
    for (let round = 0; round < 2; round++) {
      for (const id of ["home", "inbox", "tasks", "plugins"]) {
        const before = await cdp.send("Performance.getMetrics");
        const started = await page.evaluate(() => performance.now());
        await page.locator(`[data-nav-id="${id}"] a`).click();
        const observation = await page.evaluate(async () => {
          await new Promise<void>((done) =>
            requestAnimationFrame(() => requestAnimationFrame(() => done()))
          );
          const content = document.querySelector<HTMLElement>(".comma-content")!;
          const viewports = [
            ...content.querySelectorAll<HTMLElement>(
              '[data-slot="scroll-area-viewport"]'
            ),
          ].filter((viewport) => viewport.clientHeight > 0);
          for (const viewport of viewports) viewport.scrollTop = viewport.scrollHeight;
          return {
            at: performance.now(),
            hash: location.hash,
            text: content.innerText,
            visibleScrollRegions: viewports.length,
            domNodes: content.querySelectorAll("*").length,
            alerts: [...content.querySelectorAll<HTMLElement>('[role="alert"]')]
              .filter((alert) => alert.getClientRects().length > 0)
              .map((alert) => alert.innerText),
          };
        });
        const after = await cdp.send("Performance.getMetrics");
        routeObservations.push({
          route: id,
          round,
          ...observation,
          navigationWallMs: observation.at - started,
          scriptMs:
            (metric(after, "ScriptDuration") - metric(before, "ScriptDuration")) * 1000,
          taskMs:
            (metric(after, "TaskDuration") - metric(before, "TaskDuration")) * 1000,
        });
      }
    }
    await page.getByRole("button", { name: "Settings", exact: true }).click();
    const sidebar = page.locator('[data-slot="settings-sidebar-item"]');
    await expect(sidebar.first()).toBeVisible();
    const categories = await sidebar.allTextContents();
    const observations: unknown[] = [];
    for (let round = 0; round < 2; round++) {
      for (let index = 0; index < categories.length; index++) {
        const started = await page.evaluate(() => performance.now());
        await sidebar.nth(index).click();
        await expect(sidebar.nth(index)).toHaveAttribute("aria-current", "page");
        const observation = await page.evaluate(async () => {
          await new Promise<void>((done) =>
            requestAnimationFrame(() => requestAnimationFrame(() => done()))
          );
          const content = document.querySelector('[data-slot="settings-content"]')!;
          const viewport = content.querySelector('[data-slot="scroll-area-viewport"]');
          if (viewport) viewport.scrollTop = viewport.scrollHeight;
          return {
            at: performance.now(),
            heading: content.querySelector("h1,h2,h3")?.textContent,
            text: content.textContent?.trim(),
            rowCount: content.querySelectorAll("[data-setting-id]").length,
            domNodes: content.querySelectorAll("*").length,
            alerts: [...content.querySelectorAll('[role="alert"]')].map(
              (alert) => alert.textContent
            ),
          };
        });
        expect(observation.text?.length).toBeGreaterThan(0);
        observations.push({
          category: categories[index]?.trim(),
          round,
          navigationWallMs: observation.at - started,
          ...observation,
        });
      }
    }
    expect(errors).toEqual([]);
    const result = {
      scope:
        "Production web CommaApp; deterministic local session/chat stub with its two default conversations and one skill. The default stub does not implement the plugin catalog or most provider settings; those routes expose their normal error/empty states. Navigation wall times include Playwright actionability and driver overhead; they are coverage observations, not microbenchmarks. Categories that need unimplemented provider endpoints report their normal dependency error. Native-only permission and compute controls require Electron and are not exercised by this browser test.",
      routeObservations,
      categories,
      observations,
    };
    await testInfo.attach("settings-pages", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    if (process.env.COMMA_PAGES_PERFORMANCE_OUTPUT) {
      const directory = resolve(process.env.COMMA_PAGES_PERFORMANCE_OUTPUT);
      await mkdir(directory, { recursive: true });
      await writeFile(
        join(directory, "settings-pages.json"),
        JSON.stringify(result, null, 2)
      );
      await page.screenshot({ path: join(directory, "settings-pages.png") });
    }
  } finally {
    await stub.close();
  }
});
