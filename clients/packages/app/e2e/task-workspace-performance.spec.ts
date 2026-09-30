import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build, preview } from "vite";
import { fileURLToPath } from "node:url";
// Build the real task workspace in production mode without network latency.
const test = baseTest.extend<{}, { taskBaseURL: string }>({
  taskBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-task-workspace-perf-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof preview>> | undefined;
      try {
        // The web app config resolves workspace source aliases from its own cwd.
        process.chdir(root);
        const configFile = join(root, "vite.config.ts");
        await build({
          root: fileURLToPath(new URL("./fixtures/", import.meta.url)),
          configFile,
          logLevel: "error",
          build: {
            outDir: cacheDir,
            emptyOutDir: true,
            rollupOptions: {
              input: fileURLToPath(
                new URL("./fixtures/task-workspace-performance.html", import.meta.url)
              ),
            },
          },
        });
        server = await preview({
          root,
          configFile,
          build: { outDir: cacheDir },
          preview: { host: "127.0.0.1", port: 0, strictPort: false },
        });
      } finally {
        process.chdir(previousCwd);
      }
      try {
        await use(server.resolvedUrls!.local[0]!);
      } finally {
        await new Promise<void>((resolve) => server.httpServer.close(() => resolve()));
        await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

for (const view of ["board", "list"] as const) {
  test(`Task ${view} selection with 500 tasks @frame-budget`, async ({
    page,
    taskBaseURL,
  }, testInfo) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Performance.enable");
    await page.goto(
      new URL(`/task-workspace-performance.html?${view}`, taskBaseURL).href
    );
    await page.waitForFunction(() => Boolean(window.taskWorkspaceStress));
    await page.evaluate(() => window.taskWorkspaceStress.load(500));
    const first = page.locator('[data-task-navigation-id="task-0"]');
    await expect(first).toBeVisible();
    await page.waitForTimeout(300);
    const before = await cdp.send("Performance.getMetrics");
    const actions = await page.evaluate(async () => {
      const timings: number[] = [];
      for (let index = 0; index < 20; index++) {
        const row = document.querySelector(
          `[data-task-navigation-id="task-${(index % 4) * 4}"]`
        )!;
        const start = performance.now();
        row.dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, shiftKey: true })
        );
        await new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
        );
        timings.push(performance.now() - start);
      }
      return timings;
    });
    const after = await cdp.send("Performance.getMetrics");
    const delta = (name: string) =>
      ((after.metrics.find((metric) => metric.name === name)?.value ?? 0) -
        (before.metrics.find((metric) => metric.name === name)?.value ?? 0)) *
      1000;
    await testInfo.attach("task-selection-performance.json", {
      body: JSON.stringify({
        view,
        actions,
        scriptMs: delta("ScriptDuration"),
        taskMs: delta("TaskDuration"),
        layoutMs: delta("LayoutDuration"),
      }),
      contentType: "application/json",
    });
    if (view === "list") {
      // 500 loaded tasks must still leave room for input within 100 ms at 4x CPU.
      const p95 = actions.toSorted((a, b) => a - b)[Math.floor(actions.length * 0.95)]!;
      expect(p95).toBeLessThan(100);
    }
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

test("Task view switching defers offscreen layout and preserves navigation @frame-budget", async ({
  page,
  taskBaseURL,
}, testInfo) => {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await cdp.send("Performance.enable");
  await page.goto(new URL("/task-workspace-performance.html?board", taskBaseURL).href);
  await page.waitForFunction(() => Boolean(window.taskWorkspaceStress));
  await page.evaluate(() => window.taskWorkspaceStress.load(500));
  const first = page.locator('[data-task-navigation-id="task-0"]');
  await expect(first).toBeVisible();
  const samples: { elapsedMs: number; scriptMs: number; styleMs: number }[] = [];
  for (let round = 0; round < 3; round++) {
    await page.getByRole("button", { name: "List view", exact: true }).click();
    const option = page.getByRole("menuitemradio", { name: "List", exact: true });
    await expect(option).toBeVisible();
    const before = await cdp.send("Performance.getMetrics");
    const elapsedMs = await option.evaluate(async (element) => {
      const start = performance.now();
      (element as HTMLElement).click();
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      );
      return performance.now() - start;
    });
    const after = await cdp.send("Performance.getMetrics");
    const delta = (name: string) =>
      ((after.metrics.find((metric) => metric.name === name)?.value ?? 0) -
        (before.metrics.find((metric) => metric.name === name)?.value ?? 0)) *
      1000;
    samples.push({
      elapsedMs,
      scriptMs: delta("ScriptDuration"),
      styleMs: delta("RecalcStyleDuration"),
    });
    await expect(page.getByTestId("tasks-list")).toBeVisible();
    if (round < 2) {
      await page.getByRole("button", { name: "Board view", exact: true }).click();
      await page.getByRole("menuitemradio", { name: "Board", exact: true }).click();
      await expect(page.getByTestId("tasks-list")).toHaveCount(0);
    }
    await page.waitForTimeout(300);
  }
  await testInfo.attach("task-view-switch-performance.json", {
    body: JSON.stringify(samples),
    contentType: "application/json",
  });
  expect(Math.max(...samples.map((sample) => sample.styleMs))).toBeLessThan(150);
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
