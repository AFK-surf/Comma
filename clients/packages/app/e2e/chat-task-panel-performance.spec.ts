import { expect, test as baseTest } from "@playwright/test";
import {
  installReactRenderCounter,
  reactRenderWork,
} from "../../../e2e/helpers/render-work";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";
// Build the real chat surface in production mode, the React build users run.
const test = baseTest.extend<{}, { panelBaseURL: string }>({
  panelBaseURL: [
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

// A long-lived Home conversation keeps every task the agent ever announced
// until the reader acknowledges it, so the docked list has no natural ceiling.
const stressTaskCount = 700;
test(`Chat task panel stress ${stressTaskCount} tasks`, async ({
  page,
  panelBaseURL,
}, testInfo) => {
  await installReactRenderCounter(page, "data-message-id", "data-testid");
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  const panel = page.getByTestId("chat-task-panel");
  const rows = page.locator('[data-testid^="chat-task-item-"]');
  const paint = () =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
        )
    );
  const mount = await reactRenderWork(page, async () => {
    await page.evaluate(
      (count) => window.chatTaskPanelStress.load(count),
      stressTaskCount
    );
    await expect(panel).toBeVisible();
    // Canonical summaries land a batch at a time; let the list go quiet.
    await page.waitForTimeout(1_500);
  });
  // Each step may render the rows it mounts and the rows whose Task changed.
  // Rows that stay mounted and unchanged keep their elements.
  const step = async (action: () => Promise<unknown>) => {
    const before = new Set(
      await rows.evaluateAll((elements) =>
        elements.map((element) => element.dataset.testid!)
      )
    );
    const work = await reactRenderWork(page, action);
    return {
      elements: work.elements,
      transcriptRows: work.keys["data-message-id"],
      keptRowsRendered: work.keys["data-testid"]!.filter(
        (key) => key.startsWith("chat-task-item-") && before.has(key)
      ),
    };
  };

  await page.evaluate(() => {
    const viewport = document.querySelector(
      '.comma-chat-thread-zone [data-slot="scroll-area-viewport"]'
    )!;
    const heights: number[] = [];
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) heights.push(entry.contentRect.height);
    });
    observer.observe(viewport);
    Object.assign(window, { transcriptHeights: heights });
  });
  await paint();
  await page.evaluate(() => {
    (window as unknown as { transcriptHeights: number[] }).transcriptHeights.length = 0;
  });
  const toggle = page.getByTestId("chat-task-panel-toggle");
  const toggles = [];
  for (let index = 0; index < 12; index++) {
    toggles.push(
      await step(async () => {
        await toggle.evaluate((element) => (element as HTMLElement).click());
        await page.waitForTimeout(200);
      })
    );
  }
  const toggleResizes = await page.evaluate(
    () =>
      (window as unknown as { transcriptHeights: number[] }).transcriptHeights.length
  );

  const updates = [];
  for (let index = 0; index < 6; index++) {
    updates.push(
      await step(async () => {
        await page.evaluate(() => window.chatTaskPanelStress.update());
        await page.waitForTimeout(120);
      })
    );
  }

  const list = page.getByTestId("chat-task-panel-list");
  const scrolls = [];
  for (let index = 0; index < 20; index++) {
    scrolls.push(
      await step(async () => {
        await list.evaluate((element) => {
          element.scrollTop += 40;
        });
        await paint();
      })
    );
  }
  await list.evaluate((element) => {
    element.scrollTop = 0;
  });
  await paint();

  const dismissals = [];
  for (let index = 0; index < 8; index++) {
    dismissals.push(
      await step(async () => {
        await page
          .locator('[data-testid^="chat-task-dismiss-"]')
          .first()
          .evaluate((element) => (element as HTMLElement).click());
        await paint();
      })
    );
  }

  const result = {
    count: stressTaskCount,
    mountElements: mount.elements,
    toggles,
    toggleResizes,
    updates,
    scrolls,
    dismissals,
    panelNodes: await panel.evaluate((element) => element.querySelectorAll("*").length),
    rows: await rows.count(),
  };
  await testInfo.attach("metrics", {
    body: JSON.stringify(result, null, 2),
    contentType: "application/json",
  });
  // The transcript and the docked list mount the rows in view: fewer elements
  // than the transcript has messages.
  expect(result.mountElements).toBeLessThan(2 * stressTaskCount);
  // One fold is one transcript viewport height, never a tweened run of them.
  expect(result.toggleResizes).toBeLessThanOrEqual(12);
  for (const work of [...toggles, ...updates, ...scrolls, ...dismissals]) {
    // Folding, refreshing, scrolling or dismissing in the list never renders
    // the transcript, and rows that stay mounted render only for their Task.
    expect(work.transcriptRows).toEqual([]);
    expect(work.keptRowsRendered).toEqual(
      updates.includes(work) ? ["chat-task-item-task-0"] : []
    );
  }
  // Five rows show at a time, so the mounted rows must not follow the task count.
  expect(result.rows).toBeLessThanOrEqual(12);
  expect(result.panelNodes).toBeLessThan(250);
});

test("An owner read preserves unchanged Task chips and archive controls", async ({
  page,
  panelBaseURL,
}) => {
  await installReactRenderCounter(page, "data-testid");
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
    const work = await reactRenderWork(page, async () => {
      await act();
      await page.waitForTimeout(500);
    });
    return work.keys["data-testid"]!.filter((key) =>
      key.startsWith("chat-inline-task-")
    );
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

test("Right sidebar with a long transcript", async ({
  page,
  panelBaseURL,
}, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await installReactRenderCounter(page, "data-message-id");
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  await page.evaluate(() => window.chatTaskPanelStress.load(70));
  await expect(page.getByTestId("chat-task-panel")).toBeVisible();
  await page.waitForTimeout(1500);
  // The first opening mounts the rail; the measured toggles reuse it.
  await page.evaluate(() => window.chatTaskPanelStress.toggleSidebar());
  await page.waitForTimeout(250);
  const railRendered = () =>
    page
      .locator(".comma-chat-sidebar-surface")
      .evaluate((surface) =>
        [...surface.querySelectorAll("[data-message-id]")].some((row) =>
          row.checkVisibility()
        )
      );
  expect(await railRendered()).toBe(true);
  const toggles = [];
  for (let index = 0; index < 9; index++) {
    const work = await reactRenderWork(page, async () => {
      await page.evaluate(() => window.chatTaskPanelStress.toggleSidebar());
      await page.waitForTimeout(250);
    });
    toggles.push({
      open: index % 2 === 1,
      elements: work.elements,
      transcriptRows: work.keys["data-message-id"],
      railRendered: await railRendered(),
    });
  }
  await testInfo.attach("sidebar-work.json", {
    body: JSON.stringify(toggles, null, 2),
    contentType: "application/json",
  });
  for (const toggle of toggles) {
    // A toggle renders the sidebar frame, never either transcript.
    expect(toggle.transcriptRows).toEqual([]);
    expect(toggle.elements).toBeLessThan(100);
    // Once the exit finishes, the closed rail's content skips style and layout.
    expect(toggle.railRendered).toBe(toggle.open);
  }
  await expect(page.getByLabel("Details", { exact: true })).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("Streaming preserves completed rows and their geometry subscriptions", async ({
  page,
  panelBaseURL,
}) => {
  await page.goto(new URL("/chat-task-panel-performance.html", panelBaseURL).href);
  await page.waitForFunction(() => Boolean(window.chatTaskPanelStress));
  await page.evaluate(() => window.chatTaskPanelStress.stream(700));
  const draft = page.getByTestId("chat-assistant-draft");
  await expect(draft).toContainText("The result is");
  await page.waitForTimeout(500);
  const sample = await page.evaluate(async () => {
    const rows = [...document.querySelectorAll("article[data-message-id]")];
    for (let index = 0; index < 120; index++) {
      window.chatTaskPanelStress.chunk();
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
    return {
      retainedRows: rows.every((row) => row.isConnected),
      draftReplyTarget: document
        .querySelector('[data-reply-source="stream-draft"]')
        ?.getAttribute("data-reply-target"),
    };
  });
  expect(sample.retainedRows).toBe(true);
  // Streaming chunks subscribe no completed row to geometry again.
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
