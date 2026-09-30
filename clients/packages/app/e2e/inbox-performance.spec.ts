import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build, preview } from "vite";
import { fileURLToPath } from "node:url";
// Build the real Inbox UI in production mode; no network latency in list timings.
const test = baseTest.extend<{}, { inboxBaseURL: string }>({
  inboxBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-inbox-perf-"));
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
                new URL("./fixtures/inbox-performance.html", import.meta.url)
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

function paginationItem(id: string) {
  return {
    id,
    conversationId: id,
    workspaceId: "workspace",
    workspaceName: "Workspace",
    groupId: "group",
    kind: "agent_task",
    source: "salix.conversation",
    title: id,
    status: "completed",
    updatedAt: Date.now(),
  };
}

test("Inbox paginates in the background and retries failures without losing rows", async ({
  page,
  inboxBaseURL,
}, testInfo) => {
  const nextPage = Promise.withResolvers<void>();
  const requests: string[] = [];
  await page.route("**/test/inbox*", async (route) => {
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    if (!cursor) {
      await route.fulfill({
        json: {
          activeWorkspaceId: "workspace",
          items: Array.from({ length: 50 }, (_, index) =>
            paginationItem(`Notification ${index}`)
          ),
          source: "live-sync",
          hasMore: true,
          nextCursor: "page-2",
        },
      });
      return;
    }
    requests.push(cursor);
    if (requests.length === 1) {
      await nextPage.promise;
      await route.fulfill({
        json: {
          activeWorkspaceId: "workspace",
          items: [],
          source: "cache",
          errorCode: "network_unavailable",
        },
      });
    } else {
      await route.fulfill({
        json: {
          activeWorkspaceId: "workspace",
          items: [paginationItem("Older notification")],
          source: "live-sync",
          hasMore: false,
        },
      });
    }
  });
  await page.goto(new URL("/inbox-performance.html?pagination", inboxBaseURL).href);
  const viewport = page.locator('[data-slot="scroll-area-viewport"]');
  const rail = page.getByTestId("inbox-conversation-rail");
  await expect(
    rail.getByRole("link", { name: "Notification 0", exact: true })
  ).toBeVisible();
  expect(requests).toEqual([]);
  await viewport.evaluate((element) => {
    element.scrollTop = 400;
  });
  await expect(
    rail.getByRole("link", { name: "Notification 15", exact: true })
  ).toBeVisible();
  expect(requests).toEqual([]);
  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect.poll(() => requests.length).toBe(1);
  const loading = rail.getByRole("status");
  await expect(loading).toHaveCount(0);
  const first = rail.getByRole("link", { name: "Notification 49", exact: true });
  await expect(first).toBeVisible();
  await first.focus();
  await expect(first).toBeFocused();
  const before = await first.boundingBox();
  await testInfo.attach("pagination-pending", {
    body: await page.screenshot({
      path: testInfo.outputPath("pagination-pending.png"),
    }),
    contentType: "image/png",
  });
  nextPage.resolve();
  const retry = page.getByRole("button", { name: "Retry", exact: true });
  await expect(retry).toBeVisible();
  await expect(loading).toHaveCount(0);
  await expect(first).toBeVisible();
  expect(requests).toEqual(["page-2"]);
  await retry.click();
  await expect(page.getByRole("link", { name: /Older notification/ })).toHaveCount(1);
  await expect(retry).toHaveCount(0);
  await expect(loading).toHaveCount(0);
  await expect(page.getByTestId("inbox-load-more-error")).toHaveCount(0);
  expect(await first.boundingBox()).toEqual(before);
  expect(requests).toEqual(["page-2", "page-2"]);
  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(page.getByRole("link", { name: /Older notification/ })).toBeVisible();
});

for (const visibleTail of [false, true]) {
  test(`Inbox skips hidden pages in the background, visible tail: ${visibleTail}`, async ({
    page,
    inboxBaseURL,
  }) => {
    const hiddenPage = Promise.withResolvers<void>();
    const tailPage = Promise.withResolvers<void>();
    const requests: string[] = [];
    await page.route("**/test/inbox*", async (route) => {
      const cursor = new URL(route.request().url()).searchParams.get("cursor");
      if (cursor) requests.push(cursor);
      if (cursor === "page-2") await hiddenPage.promise;
      if (cursor === "page-3") await tailPage.promise;
      await route.fulfill({
        json: {
          activeWorkspaceId: "workspace",
          source: "live-sync",
          hasMore: cursor !== "page-3",
          nextCursor: cursor === "page-3" ? undefined : cursor ? "page-3" : "page-2",
          items: cursor
            ? [
                {
                  ...paginationItem(cursor),
                  status: cursor === "page-3" && visibleTail ? "completed" : "archived",
                },
              ]
            : [paginationItem("First notification")],
        },
      });
    });
    await page.goto(new URL("/inbox-performance.html?pagination", inboxBaseURL).href);
    const rail = page.getByTestId("inbox-conversation-rail");
    const first = rail.getByRole("link", { name: /First notification/ });
    await expect(first).toBeVisible();
    await expect.poll(() => requests).toEqual(["page-2"]);
    const before = await first.boundingBox();
    await expect(rail.getByRole("status")).toHaveCount(0);
    hiddenPage.resolve();
    await expect.poll(() => requests).toEqual(["page-2", "page-3"]);
    await expect(rail.getByTestId("inbox-item")).toHaveCount(1);
    await expect(rail.getByRole("status")).toHaveCount(0);
    expect(await first.boundingBox()).toEqual(before);
    tailPage.resolve();
    await expect(rail.locator('[data-slot="scroll-area-load-more"]')).toHaveCount(0);
    await expect(rail.getByTestId("inbox-item")).toHaveCount(visibleTail ? 2 : 1);
    if (visibleTail)
      await expect(rail.getByRole("link", { name: /page-3/ })).toBeVisible();
    expect(await first.boundingBox()).toEqual(before);
    expect(requests).toEqual(["page-2", "page-3"]);
  });
}

for (const count of [50, 500, 2000]) {
  test(`Inbox stress ${count} rows`, async ({ page, inboxBaseURL }, testInfo) => {
    test.setTimeout(180_000);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await page.goto(new URL("/inbox-performance.html", inboxBaseURL).href);
    await page.waitForFunction(() => Boolean(window.inboxStress));
    const result = await page.evaluate(async (sampleCount) => {
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
      const mount = await timed(() => window.inboxStress.load(sampleCount));
      if (!document.querySelector('[data-inbox-row-id="task-0"]'))
        throw new Error("Initial list has not committed");
      const selection: number[] = [],
        updates: number[] = [],
        read: number[] = [];
      for (let index = 0; index < 15; index++) {
        selection.push(
          await timed(() =>
            (
              document.querySelector(
                `[data-inbox-row-id="task-${index % 10}"] [data-testid="inbox-item"]`
              ) as HTMLElement
            ).click()
          )
        );
        if (
          !document.querySelector(
            `[data-inbox-row-id="task-${index % 10}"] [aria-current="page"]`
          )
        )
          throw new Error("Selection has not committed");
        read.push(await timed(() => window.inboxStress.read(index)));
        updates.push(await timed(() => window.inboxStress.update()));
      }
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const p95 = (values: number[]) =>
        values.toSorted((a, b) => a - b)[Math.floor(values.length * 0.95)]!;
      return {
        count: sampleCount,
        mount,
        selection: p95(selection),
        update: p95(updates),
        read: p95(read),
        nodes: document.querySelectorAll("*").length,
      };
    }, count);
    console.log(JSON.stringify(result));
    await testInfo.attach("metrics", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    // Report timings without making shared-runner scheduling a pass/fail gate.
    // DOM bounds and the actual interaction results remain required below.
    expect(result.nodes).toBeLessThan(1000);
    const rows = page.getByTestId("inbox-item");
    await page.locator('[data-inbox-row-id="task-0"] a').focus();
    for (let index = 1; index < 35; index++) {
      await page.keyboard.press("Tab");
      await expect(page.locator(`[data-inbox-row-id="task-${index}"] a`)).toBeFocused();
    }
    await page.keyboard.press("Shift+Tab");
    await expect(page.locator('[data-inbox-row-id="task-33"] a')).toBeFocused();
    const scrolling = await page.evaluate(async () => {
      const viewport = document.querySelector(
        '[data-slot="scroll-area-viewport"]'
      ) as HTMLElement;
      const frames: number[] = [];
      let previous = performance.now();
      for (let index = 0; index < 60; index++) {
        viewport.scrollTop += 100;
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const now = performance.now();
        frames.push(now - previous);
        previous = now;
      }
      viewport.scrollTop = viewport.scrollHeight;
      return frames.toSorted((a, b) => a - b)[Math.floor(frames.length * 0.95)]!;
    });
    console.log(JSON.stringify({ count, scrollFrameP95: scrolling }));
    await testInfo.attach("scroll-metrics", {
      body: JSON.stringify({ count, scrollFrameP95: scrolling }),
      contentType: "application/json",
    });
    // Reaching the end of the rail loads the next page with no button to press;
    // the list stays windowed however many pages it holds.
    const setSize = async () =>
      Number(
        await page.locator("[data-inbox-row-id]").first().getAttribute("aria-setsize")
      );
    await expect.poll(setSize).toBeGreaterThan(count);
    expect(await rows.count()).toBeLessThan(50);
    // A page lands below the reader: the rows in view keep their place.
    const viewport = page.locator('[data-slot="scroll-area-viewport"]');
    const loaded = await setSize();
    const bottom = await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
      return element.scrollTop;
    });
    await expect.poll(setSize).toBeGreaterThan(loaded);
    expect(await viewport.evaluate((element) => element.scrollTop)).toBeCloseTo(
      bottom,
      0
    );
    await expect(
      page.locator(`[data-inbox-row-id="task-${loaded - 1}"] a`)
    ).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.style.fontSize = "20px";
    });
    await expect
      .poll(async () => {
        const geometry = await page
          .locator("[data-inbox-row-id]")
          .evaluateAll((elements) =>
            elements
              .filter((element) => !element.querySelector("h2"))
              .map((element) => element.getBoundingClientRect())
              .filter((rect) => rect.top >= 0 && rect.bottom <= innerHeight)
          );
        if (geometry.length < 2) return false;
        return geometry.every(
          (rect, index) => index === 0 || rect.top >= geometry[index - 1]!.bottom - 1
        );
      })
      .toBe(true);
  });
}
