import { expect, test as baseTest } from "@playwright/test";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";
// Build the real Inbox UI in production mode, the React build users run.
const test = baseTest.extend<{}, { inboxBaseURL: string }>({
  inboxBaseURL: [
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

const count = 2000;
test(`Inbox stress ${count} rows`, async ({ page, inboxBaseURL }) => {
  await page.goto(new URL("/inbox-performance.html", inboxBaseURL).href);
  await page.waitForFunction(() => Boolean(window.inboxStress));
  const nodes = await page.evaluate(async (sampleCount) => {
    // Browser-evaluated helpers must remain inside the serialized callback.
    // eslint-disable-next-line unicorn/consistent-function-scoping
    const paint = () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      );
    window.inboxStress.load(sampleCount);
    await paint();
    if (!document.querySelector('[data-inbox-row-id="task-0"]'))
      throw new Error("Initial list has not committed");
    for (let index = 0; index < 15; index++) {
      (
        document.querySelector(
          `[data-inbox-row-id="task-${index % 10}"] [data-testid="inbox-item"]`
        ) as HTMLElement
      ).click();
      await paint();
      if (
        !document.querySelector(
          `[data-inbox-row-id="task-${index % 10}"] [aria-current="page"]`
        )
      )
        throw new Error("Selection has not committed");
      window.inboxStress.read(index);
      await paint();
      window.inboxStress.update();
      await paint();
    }
    return document.querySelectorAll("*").length;
  }, count);
  // The list stays windowed: DOM size does not follow the row count.
  expect(nodes).toBeLessThan(1000);
  const rows = page.getByTestId("inbox-item");
  await page.locator('[data-inbox-row-id="task-0"] a').focus();
  for (let index = 1; index < 35; index++) {
    await page.keyboard.press("Tab");
    await expect(page.locator(`[data-inbox-row-id="task-${index}"] a`)).toBeFocused();
  }
  await page.keyboard.press("Shift+Tab");
  await expect(page.locator('[data-inbox-row-id="task-33"] a')).toBeFocused();
  await page.evaluate(async () => {
    const viewport = document.querySelector(
      '[data-slot="scroll-area-viewport"]'
    ) as HTMLElement;
    for (let index = 0; index < 60; index++) {
      viewport.scrollTop += 100;
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
    viewport.scrollTop = viewport.scrollHeight;
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
  // Row count can commit before the observer sees the new page move the
  // pagination trigger out of reach. Wait for that departure before returning
  // to the end, so the second scroll is a distinct pagination arrival.
  await viewport.evaluate(
    (element) =>
      new Promise<void>((resolve) => {
        const sentinel = element.querySelector('[data-slot="scroll-area-load-more"]');
        if (!sentinel) throw new Error("Missing pagination trigger");
        const observer = new IntersectionObserver(
          ([entry]) => {
            if (!entry || entry.isIntersecting) return;
            observer.disconnect();
            resolve();
          },
          { root: element, rootMargin: "0px 0px 100% 0px" }
        );
        observer.observe(sentinel);
      })
  );
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
