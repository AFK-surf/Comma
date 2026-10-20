import { expect, test, type Locator } from "@playwright/test";
import { installCoreWorkerClock } from "../../../e2e/helpers/core-worker-clock";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeTaskLoop,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import {
  chooseTaskStatus,
  expectManualDoneChoice,
} from "../../../e2e/helpers/task-panel";

// The stub's Loop runs in Asia/Shanghai. On a UTC page, its rule always names
// that zone as an offset, whatever zone the machine uses.
test.use({ timezoneId: "UTC", viewport: { width: 1600, height: 1000 } });

/** What a status icon paints: its glyph paths and resolved color. */
const glyph = (icon: Locator) =>
  icon.evaluate((svg) => ({
    color: getComputedStyle(svg).color,
    paths: svg.innerHTML,
  }));

test("task details show where the Task runs and its model, not its Worker", async ({
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
  stub.setTaskParticipants([], worker);
  stub.setTaskRun({
    place: { kind: "station", device_id: "dev_studio", name: "Mac Studio" },
    model: { kind: "catalog", name: "Claude Sonnet" },
  });
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
    const run = page.locator('[data-testid="task-panel-run"]:visible');
    await expect(run).toHaveText("on Mac Studio · Claude Sonnet");
    await expect(page.getByText("Research Worker")).toHaveCount(0);
    await expect(page.getByTestId("session-history-participant")).toHaveCount(0);
    await page.setViewportSize({ width: 900, height: 800 });
    await page.getByTestId("task-panel-toggle").click();
    const narrowRun = page
      .getByTestId("task-panel-popover")
      .getByTestId("task-panel-run");
    await expect(narrowRun).toHaveText("on Mac Studio · Claude Sonnet");
    stub.disconnectTaskStatusStreams();
    stub.setTaskRun({ place: { kind: "cloud_vm" }, model: { kind: "platform" } });
    await expect(narrowRun).toHaveText("on Cloud VM · official model");
    await page.reload();
    await page.getByTestId("task-panel-toggle").click();
    await expect(narrowRun).toHaveText("on Cloud VM · official model");
    // A server before the Task's place and model sends neither: nothing shows.
    stub.setTaskRun(null);
    await expect(narrowRun).toHaveCount(0);
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
    await expect(properties.getByRole("alert")).toHaveCount(0);
    await expect(properties.getByTestId("task-conversation-status")).toHaveText(
      "Needs Review"
    );
    // A summary alone cannot end the Task: the version comes from the detail.
    await expectManualDoneChoice(properties, false);
    await expect(
      page.getByRole("button", { name: "Add label", exact: true })
    ).toHaveCount(0);
    await expect(
      page.getByRole("status", { name: "Loading task history…" })
    ).toBeVisible();
    expect(stub.taskDetailRequestCount).toBe(1);

    stub.releaseDelayedTaskDetail();
    await expect(page.getByText(history, { exact: true })).toBeVisible();
    await expectManualDoneChoice(properties, true);
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
    const statusIcon = status.locator("svg");

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

test("Done from the status menu uses the ended task while the next detail read is held", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "ready_for_review",
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
    await expectManualDoneChoice(properties, true);
    stub.holdNextTaskDetail();
    await chooseTaskStatus(properties, "Done");
    // The detail read after the change is held: the ended Task shows meanwhile.
    await stub.waitForDelayedTaskDetail();
    await expect(properties.getByTestId("task-conversation-status")).toHaveText("Done");
    expect(stub.taskStatusRequestCount).toBe(1);
  } finally {
    stub.releaseDelayedTaskDetail();
    await stub.close();
  }
});

test("a Loop Task's Properties state its schedule, and Done ends the Loop with it", async ({
  page,
}) => {
  // The stub's Loop: every day at 09:00 in Shanghai, 3 of 10 runs made.
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskLoop: chatSmokeTaskLoop,
    taskStatus: "active",
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-loop@comma.local",
      token: "comma_sess_task_loop",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();
    await page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    const properties = page.getByTestId("task-panel-properties");
    const schedule = page.getByTestId("task-panel-schedule");
    await expect(schedule.getByRole("heading")).toHaveText("Scheduled");
    await expect(schedule.getByRole("listitem")).toHaveText([
      "Every day at 9:00 AM · GMT+8",
    ]);
    // The hover text names the zone in full.
    await expect(schedule.locator("[title]")).toHaveAttribute(
      "title",
      "Every day at 9:00 AM · China Standard Time"
    );
    // The schedule follows the labels; no cron reaches the header.
    await expect(
      page.locator(
        '[data-testid="task-panel-labels"] ~ [data-testid="task-panel-schedule"]'
      )
    ).toBeVisible();
    await expect(page.getByText("0 9 * * *")).toHaveCount(0);

    // A Loop Task is ended by hand like any Task; the server ends its Loop too.
    await expectManualDoneChoice(properties, true);
    await chooseTaskStatus(properties, "Done");
    await expect(properties.getByTestId("task-conversation-status")).toHaveText("Done");
    await expect(schedule.getByTestId("task-panel-schedule-next")).toHaveText("Ended");
    // The ended Loop keeps its type. No text, hover text or control keeps its rule.
    await expect(schedule).toHaveText("ScheduledEnded");
    await expect(schedule.locator("[title]")).toHaveCount(0);
    await expect(schedule.getByRole("button")).toHaveCount(0);
    expect(stub.taskStatusRequestCount).toBe(1);
  } finally {
    await stub.close();
  }
});

test("a Loop Task opened from a link, in no list the app read, states its schedule once its summary is read", async ({
  page,
}) => {
  // No list has the Task: its schedule comes only with its own summary.
  const stub = await startChatSmokeStub({
    taskLoop: chatSmokeTaskLoop,
    taskStatus: "active",
  });
  stub.holdNextTaskSummary();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-loop-link@comma.local",
      token: "comma_sess_task_loop_link",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await stub.waitForDelayedTaskSummary();
    await expect(page.getByTestId("task-panel-properties")).toBeVisible();
    await expect(page.getByTestId("task-panel-schedule")).toHaveCount(0);

    stub.releaseDelayedTaskSummary();
    const schedule = page.getByTestId("task-panel-schedule");
    await expect(schedule.getByRole("heading")).toHaveText("Scheduled");
    await expect(schedule.getByRole("listitem")).toHaveText([
      "Every day at 9:00 AM · GMT+8",
    ]);
  } finally {
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
  });
  let clock: Awaited<ReturnType<typeof installCoreWorkerClock>> | undefined;
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
    clock = await installCoreWorkerClock(page);
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
    // Preparing the Task is not viewing it: it still needs review in the Inbox.
    await expect(
      page
        .getByRole("complementary", { name: "App sidebar" })
        .getByRole("link", { name: "Inbox" })
        .locator('[data-slot="left-rail-item-badge"]')
    ).toBeVisible();
    expect(stub.taskDetailRequestCount).toBe(0);
    stub.holdNextTaskDetail();
    const clickedAt = Date.now();
    await card.click();
    await stub.waitForDelayedTaskDetail();
    await expect(
      page.getByText("Prepared task update 96", { exact: true })
    ).toBeVisible();
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
