import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";

const test = baseTest.extend<{}, { historyBaseURL: string }>({
  historyBaseURL: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const artifactDir = process.env.COMMA_PERF_ARTIFACT_DIR;
      const cacheDir = artifactDir
        ? resolve(artifactDir, "session-history-build")
        : await mkdtemp(join(tmpdir(), "comma-history-perf-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof preview>>;
      try {
        process.chdir(root);
        const configFile = join(root, "vite.config.ts");
        if (process.env.COMMA_PERF_REUSE_BUILD !== "1")
          await build({
            root: fileURLToPath(new URL("./fixtures/", import.meta.url)),
            configFile,
            logLevel: "error",
            build: {
              outDir: cacheDir,
              emptyOutDir: true,
              rollupOptions: {
                input: fileURLToPath(
                  new URL(
                    "./fixtures/session-history-performance.html",
                    import.meta.url
                  )
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
        await new Promise<void>((done) => server.httpServer.close(() => done()));
        if (!artifactDir) await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

const metric = (result: { metrics: { name: string; value: number }[] }, name: string) =>
  result.metrics.find((entry) => entry.name === name)?.value ?? 0;

for (const count of [100, 500, 5000]) {
  test(`Session live clock preserves history and pauses at ${count} loaded records @performance`, async ({
    page,
    historyBaseURL,
  }, testInfo) => {
    test.fail(
      process.env.COMMA_PERF_RECORD_BASELINE === "1" && count === 100,
      "The original hidden page keeps its presentation clock running."
    );
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    await page.goto(
      new URL(`/session-history-performance.html?count=${count}`, historyBaseURL).href
    );
    const history = page.getByTestId("session-history-page");
    await expect(history.locator("article")).toHaveCount(count + 1, {
      timeout: 30_000,
    });
    const viewport = history
      .locator('.comma-session-scroll [data-slot="scroll-area-viewport"]')
      .first();
    await expect
      .poll(() =>
        viewport.evaluate((element) => ({
          bounded: element.clientHeight > 0 && element.clientHeight < innerHeight,
          overflowing: element.scrollHeight > element.clientHeight,
          tail: element.scrollHeight - element.clientHeight - element.scrollTop <= 4,
        }))
      )
      .toEqual({ bounded: true, overflowing: true, tail: true });
    const live = history.locator('[data-record-id="tool:live"]');
    const duration = live.locator(".comma-session-duration");
    await expect(duration).toBeVisible();
    const started = await duration.textContent();
    await expect.poll(() => duration.textContent()).not.toBe(started);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    const cpuProfile = process.env.COMMA_PERF_CPU_PROFILE === "1";
    if (cpuProfile) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.start");
    }
    const tracing = process.env.COMMA_PERF_TRACE === "1";
    const traceReady = tracing
      ? new Promise<string>((done) =>
          cdp.once("Tracing.tracingComplete", (event) => done(event.stream!))
        )
      : undefined;
    if (tracing)
      await cdp.send("Tracing.start", {
        categories: "devtools.timeline",
        transferMode: "ReturnAsStream",
      });
    const before = await cdp.send("Performance.getMetrics");
    const observed = await page.evaluate(async () => {
      const start = performance.now();
      const frames: number[] = [];
      let last: number | undefined;
      await new Promise<void>((done) => {
        const frame = (now: number) => {
          if (last !== undefined) frames.push(now - last);
          last = now;
          if (now - start >= 2000) done();
          else requestAnimationFrame(frame);
        };
        requestAnimationFrame(frame);
      });
      return {
        frames,
        elapsedMs: performance.now() - start,
        domNodes: document.querySelectorAll("*").length,
      };
    });
    const after = await cdp.send("Performance.getMetrics");
    const profile = cpuProfile ? await cdp.send("Profiler.stop") : undefined;
    let trace = "";
    if (tracing) {
      await cdp.send("Tracing.end");
      const stream = await traceReady!;
      for (;;) {
        const chunk = await cdp.send("IO.read", { handle: stream });
        trace += chunk.data;
        if (chunk.eof) break;
      }
      await cdp.send("IO.close", { handle: stream });
    }
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight / 2;
    });
    await page.evaluate(
      () =>
        new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        )
    );
    const anchor = await viewport.evaluate((element) => {
      const rows = element.querySelectorAll<HTMLElement>("article[data-record-id]");
      const top = element.getBoundingClientRect().top;
      let from = 0,
        to = rows.length;
      while (from < to) {
        const middle = Math.floor((from + to) / 2);
        if (rows[middle]!.getBoundingClientRect().bottom <= top) from = middle + 1;
        else to = middle;
      }
      const row = rows[from]!;
      return { id: row.dataset.recordId!, top: row.getBoundingClientRect().top - top };
    });
    const visibleDuration = await duration.textContent();
    await page.evaluate(() => window.sessionHistoryStress.setVisible(false));
    await expect(history).toBeHidden();
    await page.waitForTimeout(300);
    const closedDuration = await duration.textContent();
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    const hiddenBefore = await cdp.send("Performance.getMetrics");
    await page.waitForTimeout(2000);
    const hiddenAfter = await cdp.send("Performance.getMetrics");
    const hiddenDuration = await duration.textContent();
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    const restorePaintMs = await page.evaluate(async () => {
      const start = performance.now();
      window.sessionHistoryStress.setVisible(true);
      await new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      );
      return performance.now() - start;
    });
    await expect(history).toBeVisible();
    await expect
      .poll(() =>
        viewport.evaluate((element, savedAnchor) => {
          const row = element.querySelector<HTMLElement>(
            `[data-record-id="${CSS.escape(savedAnchor.id)}"]`
          )!;
          return Math.abs(
            row.getBoundingClientRect().top -
              element.getBoundingClientRect().top -
              savedAnchor.top
          );
        }, anchor)
      )
      .toBeLessThan(2);
    await expect.poll(() => duration.textContent()).not.toBe(visibleDuration);
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
    });
    const hidden = {
      visibleDuration,
      closedDuration,
      hiddenDuration,
      metricElapsedMs:
        (metric(hiddenAfter, "Timestamp") - metric(hiddenBefore, "Timestamp")) * 1000,
      scriptMs:
        (metric(hiddenAfter, "ScriptDuration") -
          metric(hiddenBefore, "ScriptDuration")) *
        1000,
      taskMs:
        (metric(hiddenAfter, "TaskDuration") - metric(hiddenBefore, "TaskDuration")) *
        1000,
      restorePaintMs,
      anchor,
    };
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    const selectionSamples = await page.evaluate(async (rowCount) => {
      const samples: number[] = [];
      for (const index of [0, Math.floor(rowCount / 2), rowCount - 1]) {
        const bar = document.querySelector<HTMLElement>(
          `.comma-session-overview-span[data-record-target="tool:tool-${index}"]`
        )!;
        const start = performance.now();
        bar.click();
        await new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        );
        const row = document.querySelector<HTMLElement>(
          `article[data-record-id="tool:tool-${index}"]`
        )!;
        if (row.dataset.selected !== "true")
          throw new Error("Selection did not commit");
        samples.push(performance.now() - start);
      }
      return samples;
    }, count);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    const sorted = observed.frames.toSorted((a, b) => a - b);
    const result = {
      rows: count,
      selectionSamples,
      hidden,
      cpuThrottle: 4,
      metricElapsedMs:
        (metric(after, "Timestamp") - metric(before, "Timestamp")) * 1000,
      cpuProfile,
      tracing,
      ...observed,
      p95FrameMs: sorted[Math.floor(sorted.length * 0.95)],
      scriptMs:
        (metric(after, "ScriptDuration") - metric(before, "ScriptDuration")) * 1000,
      taskMs: (metric(after, "TaskDuration") - metric(before, "TaskDuration")) * 1000,
      layoutMs:
        (metric(after, "LayoutDuration") - metric(before, "LayoutDuration")) * 1000,
      styleMs:
        (metric(after, "RecalcStyleDuration") - metric(before, "RecalcStyleDuration")) *
        1000,
    };
    await testInfo.attach("session-history-timing", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    const artifactDir = process.env.COMMA_PAGES_PERFORMANCE_OUTPUT;
    if (artifactDir) {
      await mkdir(resolve(artifactDir), { recursive: true });
      await writeFile(
        join(resolve(artifactDir), `history-${count}.json`),
        JSON.stringify(result, null, 2)
      );
      if (profile)
        await writeFile(
          join(resolve(artifactDir), `history-${count}.cpuprofile`),
          JSON.stringify(profile.profile)
        );
      if (trace)
        await writeFile(
          join(resolve(artifactDir), `history-${count}.trace.json`),
          trace
        );
      await page.screenshot({
        path: join(resolve(artifactDir), `history-${count}.png`),
      });
    }
    if (count === 100) {
      const geometry = await page.evaluate(async () => {
        const track = document.querySelector<HTMLElement>(
          '[data-testid="session-timeline-track"]'
        )!;
        const bars = [
          ...track.querySelectorAll<HTMLElement>(".comma-session-overview-span"),
        ];
        const samples = [bars[1]!, bars[Math.floor(bars.length / 2)]!, bars.at(-2)!];
        const initial = samples.map((bar) => bar.offsetLeft);
        let maxError = 0;
        const geometryStart = performance.now();
        await new Promise<void>((done) => {
          const frame = () => {
            const from = Number(track.dataset.startMs),
              to = Number(track.dataset.endMs);
            for (const bar of samples) {
              const left =
                Math.max(0, (Number(bar.dataset.startMs) - from) / (to - from)) *
                track.clientWidth;
              const right =
                Math.min(1, (Number(bar.dataset.endMs) - from) / (to - from)) *
                track.clientWidth;
              const width = Math.min(track.clientWidth, Math.max(4, right - left));
              const expectedLeft = Math.min(left, track.clientWidth - width);
              maxError = Math.max(
                maxError,
                Math.abs(bar.offsetLeft - expectedLeft),
                Math.abs(bar.offsetLeft + bar.offsetWidth - expectedLeft - width)
              );
            }
            if (performance.now() - geometryStart >= 800) done();
            else requestAnimationFrame(frame);
          };
          requestAnimationFrame(frame);
        });
        return {
          maxError,
          moved: samples.some((bar, index) => bar.offsetLeft !== initial[index]),
        };
      });
      expect(geometry.maxError).toBeLessThan(1.01);
      expect(geometry.moved).toBe(true);
    }
    await page.evaluate(() => window.sessionHistoryStress.pause());
    await expect(duration).toHaveText("1s");
    const paused = await duration.textContent();
    await page.waitForTimeout(300);
    expect(await duration.textContent()).toBe(paused);
    await page.evaluate(() => window.sessionHistoryStress.resume());
    await expect.poll(() => duration.textContent()).not.toBe(paused);
    await page.evaluate(() => window.sessionHistoryStress.complete());
    await expect(live).toContainText("Finished live read");
    const completed = await duration.textContent();
    await page.waitForTimeout(300);
    expect(await duration.textContent()).toBe(completed);
    if (count === 100) {
      const bar = history.locator(
        '.comma-session-overview-span[data-record-target="tool:live"]'
      );
      const timeline = history.getByTestId("session-timeline-track");
      for (const width of [720, 1280]) {
        await page.setViewportSize({ width, height: 800 });
        await expect
          .poll(() =>
            bar.evaluate((element) => {
              const rect = element.getBoundingClientRect();
              const track = element.parentElement!.getBoundingClientRect();
              return rect.left >= track.left - 1 && rect.right <= track.right + 1;
            })
          )
          .toBe(true);
        await history.getByRole("button", { name: "Zoom in", exact: true }).click();
        await expect(timeline).not.toHaveAttribute("data-axis-from", "0");
        await bar.hover();
        await expect(page.getByTestId("session-timeline-inspector")).toContainText(
          "Finished live read"
        );
        await bar.click();
        await expect(live).toHaveAttribute("data-selected", "true");
        await expect(live).toBeInViewport();
        await history.getByRole("button", { name: "Show all", exact: true }).click();
        await expect(timeline).toHaveAttribute("data-axis-from", "0");
      }
    }
    const firstRow = history.locator('[data-record-id="tool:tool-0"]');
    await firstRow.locator("summary").first().focus();
    await expect(firstRow).toBeInViewport();
    await page.keyboard.press("Enter");
    await expect(firstRow.getByTestId("session-json")).toBeVisible();
    await page.keyboard.press("Enter");
    await expect(firstRow.getByTestId("session-json")).toHaveCount(0);
    await live.locator("summary").first().click();
    await expect(live.getByTestId("session-json")).toBeVisible();
    await expect(history.locator("article")).toHaveCount(count + 1);
    // Expanded debug content must survive leaving and reentering the viewport.
    await firstRow.locator("summary").first().focus();
    await page.evaluate(
      () =>
        new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        )
    );
    await live.locator("summary").first().focus();
    await expect(live.getByTestId("session-json")).toBeVisible();
    await expect(live.locator("details").first()).toHaveAttribute("open", "");
    if (count === 100) {
      await page.evaluate(() => window.sessionHistoryStress.startModel());
      await expect(
        history.locator('[data-record-id="live-model"] .comma-session-duration')
      ).toBeVisible();
      // A model proposing a tool does not measure the tool execution itself.
      const proposed = history.locator('[data-record-id="tool:pending-tool"]');
      await expect(proposed).toHaveCount(1);
      await expect(proposed.locator(".comma-session-duration")).toHaveCount(0);
      expect(closedDuration).not.toBe("1s");
      expect(hiddenDuration).toBe(closedDuration);
    }
  });
}

test("Zoomed history keeps lane alignment when offscreen live work overlaps a future observation @performance", async ({
  page,
  historyBaseURL,
}) => {
  await page.clock.setFixedTime(new Date("2026-09-26T08:00:00Z"));
  await page.goto(
    new URL("/session-history-performance.html?count=100", historyBaseURL).href
  );
  const history = page.getByTestId("session-history-page");
  await expect(history.locator("article")).toHaveCount(101);
  const epoch = await page.evaluate(() =>
    window.sessionHistoryStress.startFutureOverlap()
  );
  await expect(history.locator("article")).toHaveCount(102);
  const track = history.getByTestId("session-timeline-track");
  const bounds = await track.boundingBox();
  if (!bounds) throw new Error("Missing timeline bounds");
  await page.mouse.move(bounds.x + bounds.width * 0.1, bounds.y + 2);
  await page.mouse.down();
  await page.mouse.move(bounds.x + bounds.width * 0.2, bounds.y + 2);
  await page.mouse.up();
  await history.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect(track.locator('[data-lane="1"]')).toHaveCount(0);
  const tool = track.locator('.comma-session-overview-span[data-lane="2"]').first();
  await expect(tool).toBeVisible();
  const initialTop = await tool.evaluate(
    (element) => (element as HTMLElement).offsetTop
  );
  await page.clock.setFixedTime(new Date(epoch + 20000));
  await expect
    .poll(() => tool.evaluate((element) => (element as HTMLElement).offsetTop))
    .toBe(initialTop + 24);
  const background = track.locator('[data-lane-background="2"]');
  expect(await tool.evaluate((element) => (element as HTMLElement).offsetTop)).toBe(
    (await background.evaluate((element) => (element as HTMLElement).offsetTop)) + 4
  );
});

test("Mixed history projects thousands of idle folds within the coordinate budget @performance", async ({
  page,
  historyBaseURL,
}, testInfo) => {
  await page.goto(
    new URL("/session-history-performance.html?count=100", historyBaseURL).href
  );
  await expect(page.getByTestId("session-history-page")).toBeVisible();
  await page.evaluate(() => window.sessionHistoryStress.setVisible(false));
  await expect(page.getByTestId("session-history-page")).toBeHidden();
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  const result = await page.evaluate(() =>
    window.sessionHistoryStress.measureFoldedProjection()
  );
  await testInfo.attach("folded-axis-coordinate-timing", {
    body: JSON.stringify(result, null, 2),
    contentType: "application/json",
  });
  expect(result.folds).toBe(2499);
  expect(result.bars).toBe(5000);
  expect(result.samples).toHaveLength(20);
  expect(Number.isFinite(result.checksum)).toBe(true);
  expect(result.totalMs).toBeLessThan(300);
});

test("Cloned history snapshots re-render only changed records @performance", async ({
  page,
  historyBaseURL,
}, testInfo) => {
  // The idle staging Router session that burned CPU held 750 loaded records.
  const count = 750;
  await page.goto(
    new URL(`/session-history-performance.html?count=${count}`, historyBaseURL).href
  );
  const history = page.getByTestId("session-history-page");
  await expect(history.locator("article")).toHaveCount(count + 1, { timeout: 30_000 });
  await page.evaluate(() => window.sessionHistoryStress.complete());
  await expect(history.locator('[data-record-id="tool:live"]')).toContainText(
    "Finished live read"
  );
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable");
  const measure = async (action: "heartbeat" | "append") => {
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    const before = await cdp.send("Performance.getMetrics");
    await page.evaluate(async (name) => {
      for (let beat = 0; beat < 5; beat++) {
        window.sessionHistoryStress[name]();
        await new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        );
      }
    }, action);
    const after = await cdp.send("Performance.getMetrics");
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    return {
      scriptMs:
        (metric(after, "ScriptDuration") - metric(before, "ScriptDuration")) * 1000,
      taskMs: (metric(after, "TaskDuration") - metric(before, "TaskDuration")) * 1000,
    };
  };
  const heartbeat = await measure("heartbeat");
  const append = await measure("append");
  await testInfo.attach("session-history-clone-timing", {
    body: JSON.stringify({ rows: count, cpuThrottle: 4, heartbeat, append }, null, 2),
    contentType: "application/json",
  });
  await expect(history.locator("article")).toHaveCount(count + 6);
  await expect(history.locator("article").last()).toContainText("Read appended file");
  // Re-rendering every loaded row took over 600 ms for five snapshots of either
  // kind. Unchanged records must keep their rows. An append renders only its row.
  expect(heartbeat.scriptMs).toBeLessThan(150);
  expect(append.scriptMs).toBeLessThan(300);
});
