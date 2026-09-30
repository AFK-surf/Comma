import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build, preview } from "vite";
import { fileURLToPath } from "node:url";
// Build the real chat surface in production mode; timings carry no network.
const test = baseTest.extend<{}, { panelBaseURL: string }>({
  panelBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-chat-task-panel-perf-"));
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
                new URL("./fixtures/chat-task-panel-performance.html", import.meta.url)
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

// A long-lived Home conversation keeps every task the agent ever announced
// until the reader acknowledges it, so the docked list has no natural ceiling.
for (const count of [7, 70, 700]) {
  test(`Chat task panel stress ${count} tasks`, async ({
    page,
    panelBaseURL,
  }, testInfo) => {
    test.setTimeout(180_000);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
    await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
    const result = await page.evaluate(async (taskCount) => {
      // Browser-evaluated helpers must remain inside the serialized callback.
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const paint = () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
        );
      const timed = async (action: () => void) => {
        const start = performance.now();
        action();
        await paint();
        return performance.now() - start;
      };
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const settle = (ms: number) =>
        new Promise<void>((resolve) => setTimeout(resolve, ms));
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const p95 = (values: number[]) =>
        values.toSorted((a, b) => a - b)[Math.floor(values.length * 0.95)]!;

      const mount = await timed(() => window.chatTaskPanelStress.load(taskCount));
      const panelSelector = '[data-testid="chat-task-panel"]';
      for (let attempt = 0; !document.querySelector(panelSelector); attempt++) {
        if (attempt > 200) throw new Error("The task panel has not docked");
        await settle(25);
      }
      // Canonical summaries land a batch at a time; let the list go quiet.
      await settle(1_500);

      const viewport = document.querySelector<HTMLElement>(
        '.comma-chat-thread-zone [data-slot="scroll-area-viewport"]'
      )!;
      const viewportHeights: number[] = [];
      const observer = new ResizeObserver((entries) => {
        for (const entry of entries) viewportHeights.push(entry.contentRect.height);
      });
      observer.observe(viewport);
      await paint();
      viewportHeights.length = 0;

      const toggle = document.querySelector<HTMLElement>(
        '[data-testid="chat-task-panel-toggle"]'
      )!;
      const toggles: number[] = [];
      for (let index = 0; index < 12; index++) {
        toggles.push(await timed(() => toggle.click()));
        await settle(200);
      }
      const toggleResizes = viewportHeights.length;
      observer.disconnect();

      const updates: number[] = [];
      for (let index = 0; index < 12; index++) {
        updates.push(await timed(() => window.chatTaskPanelStress.update()));
        await settle(120);
      }

      const list = document.querySelector<HTMLElement>(
        '[data-testid="chat-task-panel-list"]'
      )!;
      const frames: number[] = [];
      let previous = performance.now();
      for (let index = 0; index < 60; index++) {
        list.scrollTop += 40;
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const now = performance.now();
        frames.push(now - previous);
        previous = now;
      }
      list.scrollTop = 0;
      await paint();

      const dismissals: number[] = [];
      for (let index = 0; index < 8; index++) {
        const dismiss = document.querySelector<HTMLElement>(
          '[data-testid^="chat-task-dismiss-"]'
        );
        if (!dismiss) break;
        dismissals.push(await timed(() => dismiss.click()));
      }

      return {
        count: taskCount,
        mount,
        toggle: p95(toggles),
        toggleResizes,
        update: p95(updates),
        dismiss: dismissals.length > 0 ? p95(dismissals) : 0,
        scrollFrame: p95(frames),
        panelNodes: document.querySelectorAll(`${panelSelector} *`).length,
        rows: document.querySelectorAll(".comma-chat-task-item").length,
      };
    }, count);
    console.log(JSON.stringify(result));
    await testInfo.attach("metrics", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    // One fold is one transcript viewport height, never a tweened run of them.
    expect(result.toggleResizes).toBeLessThanOrEqual(12);
    expect(result.toggle).toBeLessThan(100);
    expect(result.update).toBeLessThan(100);
    expect(result.dismiss).toBeLessThan(100);
    expect(result.scrollFrame).toBeLessThan(50);
    expect(result.mount).toBeLessThan(1_500);
    // Five rows show at a time, so the mounted rows must not follow the count.
    expect(result.rows).toBeLessThanOrEqual(Math.min(count, 12));
    expect(result.panelNodes).toBeLessThan(250);
  });
}

/**
 * Counts, per inline Task chip, the commits in which it rendered with new
 * props, through the hook React reports every commit to (production builds
 * included). Installed before the page loads; slows commits, so no timings.
 */
function countInlineTaskRenders() {
  type Fiber = {
    child: Fiber | null;
    memoizedProps: { dataTestId?: unknown } | null;
    sibling: Fiber | null;
    type: unknown;
  };
  const seen = new WeakSet<object>();
  const renders = new Map<string, number>();
  const count = (root: Fiber) => {
    const stack: Fiber[] = [root];
    while (stack.length > 0) {
      const fiber = stack.pop()!;
      const props = fiber.memoizedProps;
      if (
        typeof fiber.type === "function" &&
        props &&
        typeof props.dataTestId === "string" &&
        props.dataTestId.startsWith("chat-inline-task-") &&
        !seen.has(props)
      ) {
        seen.add(props);
        renders.set(props.dataTestId, (renders.get(props.dataTestId) ?? 0) + 1);
      }
      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
    }
  };
  Object.assign(window, {
    __REACT_DEVTOOLS_GLOBAL_HOOK__: {
      checkDCE: () => undefined,
      inject: () => 1,
      isDisabled: false,
      onCommitFiberRoot: (_: number, root: { current: Fiber }) => count(root.current),
      onCommitFiberUnmount: () => undefined,
      onPostCommitFiberRoot: () => undefined,
      renderers: new Map(),
      supportsFiber: true,
    },
    inlineTaskRenders: renders,
  });
}

test("An owner read preserves unchanged Task chips and archive controls", async ({
  page,
  panelBaseURL,
}) => {
  await page.addInitScript(countInlineTaskRenders);
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  // Six announcing turns and nothing after them: every chip is in view.
  await page.evaluate(() => window.chatTaskPanelStress.load(6, 0));
  await expect(page.locator('[data-testid^="chat-inline-task-"]')).toHaveCount(6);
  // Canonical summaries land a batch at a time; let the transcript go quiet.
  await page.waitForTimeout(1_500);

  const archive = page
    .getByTestId("chat-task-item-task-2")
    .getByRole("button", { name: "Archive task", exact: true });
  await expect(archive).toBeAttached();
  await archive.focus();
  const originalArchive = await archive.elementHandle();

  const rendered = async (act: () => Promise<unknown>) => {
    await page.evaluate(() =>
      (
        window as unknown as { inlineTaskRenders: Map<string, number> }
      ).inlineTaskRenders.clear()
    );
    await act();
    await page.waitForTimeout(500);
    return page.evaluate(() => [
      ...(
        window as unknown as { inlineTaskRenders: Map<string, number> }
      ).inlineTaskRenders.keys(),
    ]);
  };
  // A running Task's own change, the usual reason the owner reads again: only
  // that Task's chip has anything new to show.
  expect(
    await rendered(() => page.evaluate(() => window.chatTaskPanelStress.update()))
  ).toEqual(["chat-inline-task-task-0"]);
  // A reread that changes nothing.
  expect(
    await rendered(() => page.evaluate(() => window.chatTaskPanelStress.reread()))
  ).toEqual([]);
  // Refreshing one Task must not remove another Task's focused menu control.
  expect(await originalArchive!.evaluate((element) => element.isConnected)).toBe(true);
  await expect(archive).toBeFocused();
});

test("Right sidebar with a long transcript @frame-budget", async ({
  page,
  panelBaseURL,
}, testInfo) => {
  test.setTimeout(180_000);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await cdp.send("Performance.enable");
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  await page.evaluate(() => window.chatTaskPanelStress.load(70));
  await expect(page.getByTestId("chat-task-panel")).toBeVisible();
  await page.waitForTimeout(1500);
  const before = await cdp.send("Performance.getMetrics");
  const frames = await page.evaluate(async () => {
    const cold: number[] = [];
    const warm: number[] = [];
    for (let index = 0; index < 10; index++) {
      window.chatTaskPanelStress.toggleSidebar();
      let previous = performance.now();
      const until = previous + 250;
      while (previous < until) {
        const now = await new Promise<number>((resolve) =>
          requestAnimationFrame(resolve)
        );
        (index === 0 ? cold : warm).push(now - previous);
        previous = now;
      }
    }
    return { cold, warm };
  });
  const after = await cdp.send("Performance.getMetrics");
  const delta = (name: string) =>
    (after.metrics.find((m) => m.name === name)?.value ?? 0) -
    (before.metrics.find((m) => m.name === name)?.value ?? 0);
  const result = {
    layoutMs: delta("LayoutDuration") * 1000,
    styleMs: delta("RecalcStyleDuration") * 1000,
    p95FrameMs: frames.warm.toSorted((a, b) => a - b)[
      Math.floor(frames.warm.length * 0.95)
    ],
    coldMaxFrameMs: Math.max(...frames.cold),
    warmMaxFrameMs: Math.max(...frames.warm),
  };
  console.log("Sidebar performance", result);
  await testInfo.attach("sidebar-performance.json", {
    body: JSON.stringify(result, null, 2),
    contentType: "application/json",
  });
  await expect(page.getByLabel("Details", { exact: true })).toHaveCount(0);
  expect(errors).toEqual([]);
  expect(result.p95FrameMs).toBeLessThan(50);
});

test("Streaming preserves completed rows and their geometry subscriptions @frame-budget", async ({
  page,
  panelBaseURL,
}, testInfo) => {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await cdp.send("Performance.enable");
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  await page.evaluate(() => window.chatTaskPanelStress.stream(700));
  const draft = page.getByTestId("chat-assistant-draft");
  await expect(draft).toContainText("The result is");
  await page.waitForTimeout(500);
  const before = await cdp.send("Performance.getMetrics");
  const sample = await page.evaluate(async () => {
    const rows = [...document.querySelectorAll("article[data-message-id]")];
    const frames: number[] = [];
    let previous = performance.now();
    for (let index = 0; index < 120; index++) {
      window.chatTaskPanelStress.chunk();
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      const now = performance.now();
      frames.push(now - previous);
      previous = now;
    }
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
    return {
      frames,
      retainedRows: rows.every((row) => row.isConnected),
      rows: rows.length,
      draftReplyTarget: document
        .querySelector('[data-reply-source="stream-draft"]')
        ?.getAttribute("data-reply-target"),
    };
  });
  const after = await cdp.send("Performance.getMetrics");
  const delta = (name: string) =>
    ((after.metrics.find((metric) => metric.name === name)?.value ?? 0) -
      (before.metrics.find((metric) => metric.name === name)?.value ?? 0)) *
    1000;
  await testInfo.attach("streaming-performance.json", {
    body: JSON.stringify({
      ...sample,
      scriptMs: delta("ScriptDuration"),
      layoutMs: delta("LayoutDuration"),
      taskMs: delta("TaskDuration"),
    }),
    contentType: "application/json",
  });
  expect(sample.retainedRows).toBe(true);
  // Count subscription churn separately so probes cannot change CPU timings.
  const observedRows = await page.evaluate(async () => {
    let count = 0;
    const observe = ResizeObserver.prototype.observe;
    ResizeObserver.prototype.observe = function (element, ...args) {
      if (element.matches("article[data-message-id]")) count += 1;
      return observe.call(this, element, ...args);
    };
    try {
      for (let index = 0; index < 4; index++) {
        window.chatTaskPanelStress.chunk();
        await new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
        );
      }
      return count;
    } finally {
      ResizeObserver.prototype.observe = observe;
    }
  });
  expect(observedRows).toBe(0);
  expect(sample.draftReplyTarget).toBe("stream-prompt");
  await expect(draft).toContainText("a useful detail");
  // A new response binding can reuse the transport draft id and parent. Its
  // replacement row still needs reply geometry subscriptions.
  const replacement = await page.evaluate(async () => {
    const previous = document.querySelector('[data-testid="chat-assistant-draft"]');
    const observed = new Set<Element>();
    const observe = ResizeObserver.prototype.observe;
    ResizeObserver.prototype.observe = function (element, ...args) {
      observed.add(element);
      return observe.call(this, element, ...args);
    };
    try {
      window.chatTaskPanelStress.restart();
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      );
      const current = document.querySelector('[data-testid="chat-assistant-draft"]');
      return {
        replaced: previous !== current,
        observed: current !== null && observed.has(current),
      };
    } finally {
      ResizeObserver.prototype.observe = observe;
    }
  });
  expect(replacement).toEqual({ replaced: true, observed: true });
  await expect(draft).toContainText("New response body");
  await page.evaluate(() => window.chatTaskPanelStress.complete());
  await expect(draft).toHaveCount(0);
  const completed = page.locator('[data-message-id="stream-completed"]');
  await expect(completed).toContainText("New response body");
  await expect(page.locator('[data-reply-source="stream-completed"]')).toHaveAttribute(
    "data-reply-target",
    "stream-prompt"
  );
});
