import { expect, test as baseTest } from "@playwright/test";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";

const test = baseTest.extend<{}, { pluginsBaseURL: string }>({
  pluginsBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const fixtures = await serveAppFixtures();
      try {
        await use(fixtures.url);
      } finally {
        await fixtures.close();
      }
    },
    { scope: "worker" },
  ],
});

// The tests share this file's production build, so one worker runs them all.
test.describe.configure({ mode: "default" });

const count = 2000;
test(`Skills search retains category and keyboard behavior at ${count} rows`, async ({
  page,
  pluginsBaseURL,
}) => {
  await page.goto(
    new URL(`/plugins-performance.html?count=${count}`, pluginsBaseURL).href
  );
  const search = page.getByRole("textbox", { name: "Search skills" });
  await expect(search).toBeVisible();
  await page.waitForFunction(() => window.pluginsMount !== undefined);
  await page.evaluate(async () => {
    const input = document.querySelector("input")!;
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )!.set!;
    for (const value of ["Skill", "S", "Sk", "Ski", "Skil", "Skill"]) {
      setter.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      await new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      );
      if (input.value !== value) throw new Error("Search did not commit");
    }
  });
  await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(count);
  // Offscreen rows remain reachable by native focus and scrolling.
  const distant = page.locator(`[data-plugin-id="skill-${count - 1}"] button`);
  await distant.focus();
  await expect(distant).toBeInViewport();
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("opened-skill")).toHaveText(
    `skill-${count - 1}:keyboard`
  );
  await search.fill(`Skill ${count - 1}`);
  await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(1);
  const last = page.locator(`[data-plugin-id="skill-${count - 1}"] button`);
  await last.focus();
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("opened-skill")).toHaveText(
    `skill-${count - 1}:keyboard`
  );
  await search.clear();
  await page.getByRole("button", { name: "System", exact: true }).click();
  await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(count / 2);
  await search.fill("Skill 1");
  await expect(page.locator('[data-plugin-id="skill-1"]')).toHaveCount(1);
  await search.clear();
  await expect(page.locator('[data-plugin-id="skill-1"]')).toHaveCount(0);
});
