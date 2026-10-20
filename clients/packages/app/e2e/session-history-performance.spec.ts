import { expect, test as baseTest } from "@playwright/test";
import {
  installReactRenderCounter,
  reactRenderWork,
} from "../../../e2e/helpers/render-work";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";

const test = baseTest.extend<{}, { historyBaseURL: string }>({
  historyBaseURL: [
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

for (const count of [100, 5000]) {
  test(`Session live clock preserves history and pauses at ${count} loaded records`, async ({
    page,
    historyBaseURL,
  }, testInfo) => {
    await installReactRenderCounter(page);
    await page.goto(
      new URL(`/session-history-performance.html?count=${count}`, historyBaseURL).href
    );
    const history = page.getByTestId("session-history-page");
    await expect(history.locator("article")).toHaveCount(count + 1);
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
    // A hidden history keeps its live clock stopped: nothing renders.
    const hiddenWork = await reactRenderWork(page, () => page.waitForTimeout(2000));
    const hiddenDuration = await duration.textContent();
    await testInfo.attach("hidden-history-work", {
      body: JSON.stringify(hiddenWork),
      contentType: "application/json",
    });
    expect(hiddenWork.commits).toBe(0);
    await page.evaluate(() => window.sessionHistoryStress.setVisible(true));
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
    await page.evaluate(async (rowCount) => {
      for (const index of [0, Math.floor(rowCount / 2), rowCount - 1]) {
        document
          .querySelector<HTMLElement>(
            `.comma-session-overview-span[data-record-target="tool:tool-${index}"]`
          )!
          .click();
        await new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        );
        const row = document.querySelector<HTMLElement>(
          `article[data-record-id="tool:tool-${index}"]`
        )!;
        if (row.dataset.selected !== "true")
          throw new Error("Selection did not commit");
      }
    }, count);
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
        // The page lays out at the new width a while later on a loaded machine. Until it does, a bar's box is the old
        // layout's: a hover lands there, and the resize then slides another bar under the pointer.
        await expect.poll(() => page.evaluate(() => window.innerWidth)).toBe(width);
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

test("Zoomed history keeps lane alignment when offscreen live work overlaps a future observation", async ({
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

test("Cloned history snapshots re-render only changed records", async ({
  page,
  historyBaseURL,
}, testInfo) => {
  // The idle staging Router session that burned CPU held 750 loaded records.
  const count = 750;
  await installReactRenderCounter(page, "data-record-id");
  await page.goto(
    new URL(`/session-history-performance.html?count=${count}`, historyBaseURL).href
  );
  const history = page.getByTestId("session-history-page");
  await expect(history.locator("article")).toHaveCount(count + 1);
  await page.evaluate(() => window.sessionHistoryStress.complete());
  await expect(history.locator('[data-record-id="tool:live"]')).toContainText(
    "Finished live read"
  );
  const measure = (action: "heartbeat" | "append") =>
    reactRenderWork(page, () =>
      page.evaluate(async (name) => {
        for (let beat = 0; beat < 5; beat++) {
          window.sessionHistoryStress[name]();
          await new Promise<void>((done) =>
            requestAnimationFrame(() => requestAnimationFrame(() => done()))
          );
        }
      }, action)
    );
  const heartbeat = await measure("heartbeat");
  const append = await measure("append");
  await testInfo.attach("session-history-clone-work", {
    body: JSON.stringify({ rows: count, heartbeat, append }, null, 2),
    contentType: "application/json",
  });
  await expect(history.locator("article")).toHaveCount(count + 6);
  await expect(history.locator("article").last()).toContainText("Read appended file");
  // Re-rendering every loaded row took over 600 ms for five snapshots of either
  // kind. Unchanged records keep their rows and timeline bars; an append
  // renders only its row.
  expect(heartbeat.keys["data-record-id"]).toEqual([]);
  expect(append.keys["data-record-id"]).toEqual(
    Array.from({ length: 5 }, (_, index) => `tool:appended-${count + 2 + index}`)
  );
  expect(heartbeat.elements).toBeLessThan(count);
  expect(append.elements).toBeLessThan(count);
});

test("Session renders 5003 records at once", async ({
  page,
  historyBaseURL,
}, testInfo) => {
  // Every page already read (the core's paging is its own test): the whole history renders at once.
  await page.goto(
    new URL("/session-history-performance.html?stress=5003", historyBaseURL).href
  );
  const history = page.getByTestId("session-history-page");
  const viewport = history.getByRole("region", { name: "Execution records" });
  await expect(history.getByText("5003 loaded records", { exact: true })).toBeVisible(
    {}
  );
  await expect(history.locator("article")).toHaveCount(4005);
  const ids = await history
    .locator("article")
    .evaluateAll((elements) =>
      elements.map((element) => element.getAttribute("data-record-id"))
    );
  expect(new Set(ids).size).toBe(4005);
  await expect(history.getByTestId("session-json")).toHaveCount(0);
  await expect(
    history.getByText("Beginning of session", { exact: true })
  ).toBeVisible();
  const track = history.getByTestId("session-timeline-track");
  const bounds = (await track.boundingBox())!;
  // At this density, zoom separates minimum-width bars that share a real-time row.
  await page.mouse.move(bounds.x, bounds.y + 10);
  await page.mouse.wheel(0, -1500);
  await expect
    .poll(async () => Number(await track.getAttribute("data-axis-to")))
    .toBeLessThan(0.1);
  const tool = history.locator('[data-span-id="tool:stress-0-a"]');
  await tool.click();
  await expect(history.locator('[data-record-id="tool:stress-0-a"]')).toHaveAttribute(
    "data-selected",
    "true"
  );
  await history.getByRole("button", { name: "Show all", exact: true }).click();
  await page.mouse.move(bounds.x + bounds.width * 0.5, bounds.y + 10);
  await page.mouse.wheel(0, -1500);
  await expect
    .poll(async () => Number(await track.getAttribute("data-axis-from")))
    .toBeGreaterThan(0.4);
  await history.locator('[data-span-id="tool:stress-250-a"]').click();
  const centered = history.locator('[data-record-id="tool:stress-250-a"]');
  await expect(centered).toHaveAttribute("data-selected", "true");
  await expect
    .poll(async () => {
      const row = (await centered.boundingBox())!;
      const visible = (await viewport.boundingBox())!;
      return Math.abs(row.y + row.height / 2 - visible.y - visible.height / 2);
    })
    .toBeLessThan(2);
  await page.screenshot({ path: testInfo.outputPath("session-5003-records.png") });
});
