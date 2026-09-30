import { expect, test, type Locator } from "@playwright/test";
import { installSharedWorkerClock } from "../../../e2e/helpers/shared-worker-clock";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test.use({ viewport: { width: 1600, height: 1000 } });

/** What a status icon paints: its glyph paths and resolved color. */
const glyph = (icon: Locator) =>
  icon.evaluate((svg) => ({
    color: getComputedStyle(svg).color,
    paths: svg.innerHTML,
  }));

test("task details show the bound Worker without enabling Session history", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  const worker = {
    participant_id: "ptc_bound_worker",
    actor_id: "actor_bound_worker",
    actor_role: "worker" as const,
    name: "Research Worker",
    state: "stopped" as const,
    status: "idle",
    updated_at: 1,
  };
  // A structured wait hides activity, but not the bound Worker identity.
  stub.setTaskParticipants([], worker);
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-worker@comma.local",
      token: "comma_sess_task_worker",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    const workerSection = page.locator('[data-testid="task-panel-worker"]:visible');
    await expect(workerSection).toContainText("Research Worker");
    await expect(workerSection).not.toContainText("Router");
    await expect(page.getByTestId("session-history-participant")).toHaveCount(0);
    await page.setViewportSize({ width: 900, height: 800 });
    await page.getByTestId("task-panel-toggle").click();
    await expect(
      page.getByTestId("task-panel-popover").getByTestId("task-panel-worker")
    ).toContainText("Research Worker");
    stub.setTaskParticipants([{ ...worker, name: "Updated Worker", updated_at: 2 }]);
    await expect(
      page.getByTestId("task-panel-popover").getByTestId("task-panel-worker")
    ).toContainText("Updated Worker");
    const narrowWorker = page
      .getByTestId("task-panel-popover")
      .getByTestId("task-panel-worker");
    stub.setTaskParticipants([], { ...worker, name: "Waiting Worker" });
    await expect(narrowWorker).toContainText("Waiting Worker");
    stub.disconnectTaskStatusStreams();
    stub.setTaskParticipants([], { ...worker, name: "Reconnected Worker" });
    await expect(narrowWorker).toContainText("Reconnected Worker");
    await page.reload();
    await page.getByTestId("task-panel-toggle").click();
    await expect(narrowWorker).toContainText("Reconnected Worker");
    stub.setTaskParticipants([], null);
    await expect(narrowWorker).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("an Agent-only task mounts recent messages and expands upward without moving the reading anchor", async ({
  page,
}) => {
  const replies = Array.from(
    { length: 96 },
    (_, index) => `Task update ${index}: ${"A detailed progress report. ".repeat(30)}`
  );
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: replies,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-history@comma.local",
      token: "comma_sess_task_history",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    const viewport = page.getByRole("log", {
      name: "Conversation thread",
      exact: true,
    });
    const thread = viewport.locator(".comma-chat-thread");
    const rows = thread.locator("article[data-message-id]");
    await expect(rows.filter({ hasText: "Task update 95:" })).toHaveCount(1);
    await expect
      .poll(() =>
        viewport.evaluate(
          (node) => node.scrollHeight - node.clientHeight - node.scrollTop
        )
      )
      .toBeLessThanOrEqual(1);
    expect(await rows.count()).toBeLessThanOrEqual(24);
    await expect(rows.filter({ hasText: "Task update 0:" })).toHaveCount(0);
    // First position above the load threshold, then cross it with reader input.
    await viewport.evaluate((node) => {
      node.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }));
      node.scrollTop = 300;
    });
    await expect.poll(() => viewport.evaluate((node) => node.scrollTop)).toBe(300);
    const anchor = await viewport.evaluate((node) => {
      const first = node.querySelector<HTMLElement>("article[data-message-id]")!;
      node.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }));
      node.scrollTop = 100;
      return { id: first.dataset.messageId!, top: first.getBoundingClientRect().top };
    });
    await expect.poll(() => rows.count()).toBeGreaterThan(24);
    expect(await rows.count()).toBeLessThanOrEqual(56);
    await expect
      .poll(async () =>
        Math.abs(
          (await thread.locator(`[data-message-id="${anchor.id}"]`).boundingBox())!.y -
            anchor.top
        )
      )
      .toBeLessThan(2);
    await expect(rows.filter({ hasText: "Task update 95:" })).toHaveCount(1);
  } finally {
    await stub.close();
  }
});

test("a failed preparation leaves known properties usable while history loads", async ({
  page,
}) => {
  const history = "The task history has now loaded.";
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskPreparationUnavailable: true,
    taskStatus: "ready_for_review",
    taskAssistantMessages: [history],
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-card-loading@comma.local",
      token: "comma_sess_task_card_loading",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    const card = page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({
        hasText: chatSmokeTaskConversation.title,
      });
    await expect(card).toBeVisible();
    expect(stub.taskDetailRequestCount).toBe(0);
    stub.holdNextTaskDetail();
    await card.click();
    await stub.waitForDelayedTaskDetail();

    await expect(
      page.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect(page.getByRole("heading", { name: "Connecting…" })).toHaveCount(0);
    const properties = page.getByTestId("task-panel-properties");
    await expect(
      properties.getByText(
        "The Task changed before it could be accepted. Review it again."
      )
    ).toHaveCount(0);
    await expect(properties.getByTestId("task-conversation-status")).toHaveText(
      "Needs Review"
    );
    await expect(
      properties.getByRole("button", { name: "Done", exact: true })
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Add label", exact: true })
    ).toHaveCount(0);
    await expect(
      page.getByRole("status", { name: "Loading task history…" })
    ).toBeVisible();
    expect(stub.taskDetailRequestCount).toBe(1);

    stub.releaseDelayedTaskDetail();
    await expect(page.getByText(history, { exact: true })).toBeVisible();
    await expect(
      properties.getByRole("button", { name: "Done", exact: true })
    ).toBeVisible();
    await expect(
      page.getByRole("status", { name: "Loading task history…" })
    ).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("Properties keeps the Inbox status when a stale task detail arrives later", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "in_progress",
    taskDetailStatus: "in_progress",
    taskSchedule: null,
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-properties@comma.local",
      token: "comma_sess_task_properties",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();
    const row = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await expect(row).toBeVisible();

    // Capture the old detail response while the Inbox can continue syncing.
    stub.holdNextTaskDetail();
    await row.click();
    await stub.waitForDelayedTaskDetail();
    const previousListReads = stub.conversationListRequestCount;
    stub.publishTaskReviewUpdate({
      assistantMessages: ["The task is ready for review."],
      title: chatSmokeTaskConversation.title,
      updatedAt: chatSmokeTaskConversation.updated_at + 1,
    });
    await expect
      .poll(() => stub.conversationListRequestCount)
      .toBeGreaterThan(previousListReads);
    await expect(row.locator('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "visible"
    );

    stub.releaseDelayedTaskDetail();
    const properties = page.getByTestId("task-panel-properties");
    await expect(properties).toBeVisible();
    // Check the first rendered detail, not a later conversation poll.
    expect(
      await properties
        .getByTestId("task-conversation-status")
        .getAttribute("data-status")
    ).toBe("needs_review");
    await expect(properties.getByTestId("task-conversation-status")).toHaveText(
      "Needs Review"
    );
  } finally {
    await stub.close();
  }
});

test("the Inbox row draws the same status glyph as Properties", async ({ page }) => {
  // `active` is a raw server status that both surfaces show as In progress.
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "active",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-status-glyph@comma.local",
      token: "comma_sess_task_status_glyph",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();
    const row = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await row.click();
    const status = page
      .getByTestId("task-panel-properties")
      .getByTestId("task-conversation-status");
    const rowIcon = row.locator(
      '[data-slot="task-list-item-icon"] > :not([data-motion="exit"]) svg'
    );
    const statusIcon = status.locator(
      ".comma-status-swap-layer:not([data-leaving]) svg"
    );

    await expect(status).toHaveText("In progress");
    await expect.poll(() => glyph(rowIcon)).toEqual(await glyph(statusIcon));

    stub.publishTaskReviewUpdate({
      assistantMessages: ["The task is ready for review."],
      title: chatSmokeTaskConversation.title,
      updatedAt: chatSmokeTaskConversation.updated_at + 1,
    });
    await expect(status).toHaveText("Needs Review");
    await expect.poll(() => glyph(rowIcon)).toEqual(await glyph(statusIcon));
  } finally {
    await stub.close();
  }
});

test("Done uses the accepted task while the next detail read is held", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "ready_for_review",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-done@comma.local",
      token: "comma_sess_task_done",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();
    await page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    const properties = page.getByTestId("task-panel-properties");
    const done = properties.getByRole("button", { name: "Done", exact: true });
    await expect(done).toBeVisible();
    stub.holdNextTaskDetail();
    await done.click();
    await expect(properties.getByTestId("task-conversation-status")).toHaveText("Done");
    await expect(properties.locator(".comma-task-panel-done")).toHaveCount(0);
  } finally {
    stub.releaseDelayedTaskDetail();
    await stub.close();
  }
});

test("revisiting a released task paints its history before the fresh detail arrives", async ({
  page,
}) => {
  const history = "Previously read task history remains available.";
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: [history],
    taskSchedule: null,
  });
  let clock: Awaited<ReturnType<typeof installSharedWorkerClock>> | undefined;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-revisit@comma.local",
      token: "comma_sess_task_revisit",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();
    const row = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await row.click();
    await expect(page.getByText(history, { exact: true })).toBeVisible();
    await page.clock.install();
    clock = await installSharedWorkerClock(page);
    await page.getByRole("link", { name: "Home", exact: true }).click();
    await page.clock.fastForward(31_000);
    await clock.advance(31_000);
    await page.getByRole("link", { name: "Inbox" }).click();
    stub.holdNextTaskDetail();
    await row.click();
    await stub.waitForDelayedTaskDetail();
    await expect(page.getByText(history, { exact: true })).toBeVisible();
  } finally {
    stub.releaseDelayedTaskDetail();
    await clock?.dispose();
    await stub.close();
  }
});

test("a prepared task shows recent content immediately while the runtime detail is held", async ({
  page,
}) => {
  const history = Array.from({ length: 96 }, (_, i) => `Prepared task update ${i + 1}`);
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: history,
    taskStatus: "ready_for_review",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "prepared-task@comma.local",
      token: "comma_sess_prepared_task",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    const card = page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title });
    await expect.poll(() => stub.taskPreparationRequestCount).toBe(1);
    // Let the preparation response cross the existing session cache boundary.
    await page.waitForTimeout(150);
    expect(
      await page.evaluate((id) => {
        const raw = localStorage.getItem("comma.taskReviewSeen");
        return raw ? (JSON.parse(raw)[id] ?? null) : null;
      }, chatSmokeTaskConversation.id)
    ).toBeNull();
    expect(stub.taskDetailRequestCount).toBe(0);
    stub.holdNextTaskDetail();
    const clickedAt = Date.now();
    await card.click();
    await stub.waitForDelayedTaskDetail();
    await expect(
      page.getByText("Prepared task update 96", { exact: true })
    ).toBeVisible({ timeout: 500 });
    const clickToContentMs = Date.now() - clickedAt;
    expect(clickToContentMs).toBeLessThan(500);
    await test.info().attach("click-to-content", {
      body: JSON.stringify({ clickToContentMs, detailResponseHeld: true }),
      contentType: "application/json",
    });
    await expect(
      page.getByRole("status", { name: "Loading task history…" })
    ).toHaveCount(0);
    await expect(page.getByText("Prepared task update 1", { exact: true })).toHaveCount(
      0
    );
    stub.releaseDelayedTaskDetail();
    await expect(
      page.getByText("Prepared task update 96", { exact: true })
    ).toBeVisible();
    expect(stub.taskPreparationRequestCount).toBe(1);
  } finally {
    await stub.close();
  }
});

test("leaving a task during edge transitions releases its detached transcript", async ({
  page,
  browserName,
}) => {
  test.skip(browserName !== "chromium", "Requires Chromium's explicit GC boundary");
  await page.setViewportSize({ width: 1280, height: 900 });
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskInboxSummaryOnly: true,
    taskStatus: "ready_for_review",
    taskSchedule: null,
    taskAssistantMessages: Array.from(
      { length: 1000 },
      (_, index) =>
        `### Memory check ${index}\n\n${"Checked **output**, verified results and recorded the next action. ".repeat(15)}`
    ),
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-memory@comma.local",
      token: "comma_sess_task_memory",
    });
    await page.route(
      `${stub.baseUrl}/v1/comma/groups/*/conversations/*`,
      async (route) => {
        if (
          route.request().method() === "GET" &&
          !new URL(route.request().url()).pathname.endsWith("events")
        )
          await new Promise((resolve) => setTimeout(resolve, 20));
        await route.continue();
      }
    );
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page.evaluate(() => {
      Object.assign(window, { taskMemoryProbes: [] });
    });
    const card = page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title });
    const viewport = page.getByRole("log", {
      name: "Conversation thread",
      exact: true,
    });
    for (let index = 0; index < 6; index++) {
      await page.waitForTimeout(50);
      await card.click();
      await viewport.waitFor();
      await page.waitForTimeout(80);
      await viewport.evaluate((node) => {
        const probes = (
          window as unknown as {
            taskMemoryProbes: WeakRef<Element>[];
          }
        ).taskMemoryProbes;
        probes.push(new WeakRef(node));
      });
      // Leave while the native edge-mask transitions are active, as with a
      // quick back navigation. The probe itself never owns the element.
      await page.getByRole("link", { name: "Tasks", exact: true }).click();
      await expect(card).toBeVisible();
    }
    await page.waitForTimeout(500);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("HeapProfiler.collectGarbage");
    await page.waitForTimeout(50);
    await cdp.send("HeapProfiler.collectGarbage");
    const retained = await page.evaluate(
      () =>
        (
          window as unknown as { taskMemoryProbes: WeakRef<Element>[] }
        ).taskMemoryProbes.filter((probe) => probe.deref() !== undefined).length
    );
    expect(retained, "unmounted chat viewports must be collectible").toBe(0);
    await cdp.detach();
  } finally {
    await stub.close();
  }
});
