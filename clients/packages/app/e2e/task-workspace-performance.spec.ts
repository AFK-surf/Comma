import { expect, test as baseTest } from "@playwright/test";
import {
  installReactRenderCounter,
  reactRenderWork,
  type ReactRenderWork,
} from "../../../e2e/helpers/render-work";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";
// Build the real task workspace in production mode without network latency.
const test = baseTest.extend<{}, { taskBaseURL: string }>({
  taskBaseURL: [
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

for (const view of ["board", "list"] as const) {
  test(`Task ${view} selection with 500 tasks`, async ({
    page,
    taskBaseURL,
  }, testInfo) => {
    await installReactRenderCounter(page, "data-task-navigation-id");
    await page.goto(
      new URL(`/task-workspace-performance.html?${view}`, taskBaseURL).href
    );
    await page.waitForFunction(() => Boolean(window.taskWorkspaceStress));
    await page.evaluate(() => window.taskWorkspaceStress.load(500));
    const first = page.locator('[data-task-navigation-id="task-0"]');
    await expect(first).toBeVisible();
    await page.waitForTimeout(300);
    const clicks = [];
    for (let index = 0; index < 12; index++) {
      clicks.push(
        await reactRenderWork(page, () =>
          page.evaluate(
            async (task) => {
              document
                .querySelector(`[data-task-navigation-id="${task}"]`)!
                .dispatchEvent(
                  new MouseEvent("click", {
                    bubbles: true,
                    cancelable: true,
                    shiftKey: true,
                  })
                );
              await new Promise<void>((resolve) =>
                requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
              );
            },
            `task-${(index % 4) * 4}`
          )
        )
      );
    }
    await testInfo.attach("task-selection-work.json", {
      body: JSON.stringify(clicks),
      contentType: "application/json",
    });
    // A selection change renders the row it changes, not the 500 loaded rows.
    clicks.forEach((click, index) => {
      expect(click.keys["data-task-navigation-id"]).toEqual([
        `task-${(index % 4) * 4}`,
      ]);
      expect(click.elements).toBeLessThan(500);
    });
    await page.getByTestId("tasks-ask-comma").click();
    expect(await page.evaluate(() => window.taskWorkspaceStress.selected)).toEqual([
      "task-0",
      "task-4",
      "task-8",
      "task-12",
    ]);
    await expect(page.getByTestId("tasks-selection-bar")).toHaveCount(0);
    // A projection change must still replace the visible row content.
    await page.evaluate(() => window.taskWorkspaceStress.update());
    await expect(first).toHaveAttribute(
      "aria-label",
      "Task 0 — review the implementation and the release notes."
    );
    await first.click({ modifiers: ["Shift"] });
    await page.getByTestId("tasks-ask-comma").click();
    expect(await page.evaluate(() => window.taskWorkspaceStress.selected)).toEqual([
      "task-0",
    ]);
  });
}

test("Task view switching defers offscreen layout and preserves navigation", async ({
  page,
  taskBaseURL,
}, testInfo) => {
  await installReactRenderCounter(page, "data-task-navigation-id");
  await page.goto(new URL("/task-workspace-performance.html?board", taskBaseURL).href);
  await page.waitForFunction(() => Boolean(window.taskWorkspaceStress));
  await page.evaluate(() => window.taskWorkspaceStress.load(500));
  const first = page.locator('[data-task-navigation-id="task-0"]');
  await expect(first).toBeVisible();
  const samples = [];
  for (let round = 0; round < 3; round++) {
    await page.getByRole("button", { name: "List view", exact: true }).click();
    const option = page.getByRole("menuitemradio", { name: "List", exact: true });
    await expect(option).toBeVisible();
    let inputResponse: ReactRenderWork | undefined;
    await reactRenderWork(page, async () => {
      inputResponse = await option.evaluate(async (element) => {
        (element as HTMLElement).click();
        // React commits the click's own updates in a microtask of this task.
        // A transition renders in a later task.
        for (let index = 0; index < 5; index++) await Promise.resolve();
        return window.commaRenderWork!.peek();
      });
      await expect(page.getByTestId("tasks-list")).toBeVisible();
    });
    await expect(page.locator("[data-task-navigation-id]")).toHaveCount(500);
    // Rows whose content the browser styles and lays out; offscreen rows skip it.
    const renderedRows = await page
      .locator("[data-task-navigation-id]")
      .evaluateAll(
        (rows) =>
          rows.filter((row) =>
            [...row.children].some((child) =>
              child.checkVisibility({ contentVisibilityAuto: true })
            )
          ).length
      );
    samples.push({ inputResponseElements: inputResponse!.elements, renderedRows });
    if (round < 2) {
      await page.getByRole("button", { name: "Board view", exact: true }).click();
      await page.getByRole("menuitemradio", { name: "Board", exact: true }).click();
      await expect(page.getByTestId("tasks-list")).toHaveCount(0);
    }
    await page.waitForTimeout(300);
  }
  await testInfo.attach("task-view-switch-work.json", {
    body: JSON.stringify(samples),
    contentType: "application/json",
  });
  for (const sample of samples) {
    // The click closes the menu; the list of every loaded Task mounts after it.
    expect(sample.inputResponseElements).toBeLessThan(500);
    // Offscreen rows skip style and layout until they are scrolled to.
    expect(sample.renderedRows).toBeLessThan(60);
  }
  await expect(page.locator("[data-task-navigation-id]")).toHaveCount(500);

  // Native focus must reveal a row that has not yet entered the viewport.
  const last = page.locator('[data-task-navigation-id="task-499"]');
  await last.focus();
  await expect(last).toBeInViewport();
  await last.press("Shift+Enter");
  await expect(last).toHaveAttribute("data-checked", "true");
  await first.focus();
  await expect(first).toBeInViewport();
  await first.press("Enter");
  await page.getByTestId("tasks-ask-comma").click();
  expect(await page.evaluate(() => window.taskWorkspaceStress.selected)).toEqual([
    "task-0",
    "task-499",
  ]);
  const done = page
    .locator('[data-slot="task-list-group-header"]')
    .filter({ hasText: "Done" });
  await done.scrollIntoViewIfNeeded();
  await done.click();
  await expect(last).toBeHidden();
  await done.click();
  await last.scrollIntoViewIfNeeded();
  await expect(last).toBeVisible();
});
