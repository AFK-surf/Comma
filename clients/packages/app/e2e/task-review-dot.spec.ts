import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const dotIn = (row: Locator) => row.locator('[data-slot="task-list-item-dot"]');
const inboxTabBadge = (page: Page) =>
  page
    .getByRole("complementary", { name: "App sidebar" })
    .getByRole("link", { name: "Inbox" })
    .locator('[data-slot="left-rail-item-badge"]');
const taskProjectionUpdatedAt = chatSmokeTaskConversation.updated_at * 1_000;

const taskSeenRevision = (page: Page) =>
  page.evaluate((conversationId) => {
    const raw = window.localStorage.getItem("comma.taskReviewSeen");
    if (raw === null) return null;
    return (JSON.parse(raw) as Record<string, number>)[conversationId] ?? null;
  }, chatSmokeTaskConversation.id);

/**
 * The needs-review attention dot across surfaces: an unviewed needs-review task
 * carries a dot in the Inbox rail and in the Chat Sidebar's task panel, and
 * opening the loaded conversation fades it out and translates the title. Only the viewed task clears — siblings keep their dots — and
 * non-review statuses never show one. The Inbox tab shows a circular badge
 * while any visible Inbox item is unread.
 */
test("viewing a needs-review task clears its dot in the inbox", async ({ page }) => {
  const stub = await startChatSmokeStub({
    extraInlineTasks: [
      { id: "cnv_task_att_1", status: "needs_review", title: "翻译产品发布公告" },
      { id: "cnv_task_att_2", status: "in_progress", title: "整理季度 OKR 草稿" },
    ],
    includeTaskInInbox: true,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-review-dot@comma.local",
      token: "comma_sess_task_review_dot",
    });
    await page.goto("/");
    await expect(inboxTabBadge(page)).toBeVisible();
    await page.getByRole("link", { name: "Inbox" }).click();
    const inboxItems = page.getByTestId("inbox-item");
    const mainRow = inboxItems.filter({ hasText: chatSmokeTaskConversation.title });
    const reviewRow = inboxItems.filter({ hasText: "翻译产品发布公告" });
    const runningRow = inboxItems.filter({ hasText: "整理季度 OKR 草稿" });
    await expect(dotIn(mainRow)).toHaveAttribute("data-state", "visible");
    await expect(dotIn(reviewRow)).toHaveAttribute("data-state", "visible");
    await expect(dotIn(runningRow)).toHaveAttribute("data-state", "hidden");

    const title = mainRow.locator('[data-slot="task-list-item-title"]');
    const dot = dotIn(mainRow);
    const before = await title.boundingBox();
    await mainRow.evaluate((row) => {
      row.addEventListener("transitionrun", (event) => {
        const target = event.target as HTMLElement;
        if (
          target.matches(
            '[data-slot="task-list-item-title"], .task-list-item-dot-inner, .task-list-item-dot-track'
          )
        ) {
          const names = row.getAttribute("data-motion-properties") ?? "";
          row.setAttribute(
            "data-motion-properties",
            `${names} ${(event as TransitionEvent).propertyName}`
          );
        }
      });
    });
    await mainRow.click();

    // Viewing clears the viewed task everywhere; the sibling keeps its dot.
    await expect(dotIn(mainRow)).toHaveAttribute("data-state", "hidden");
    await expect(dotIn(reviewRow)).toHaveAttribute("data-state", "visible");
    await expect(mainRow).toHaveAttribute("data-motion-properties", /transform/);
    expect(await mainRow.getAttribute("data-motion-properties")).not.toMatch(
      /width|margin|padding/
    );
    await expect
      .poll(async () => (await title.boundingBox())!.x)
      .toBeCloseTo(before!.x - 16, 0);
    expect(await dot.evaluate((element) => element.getBoundingClientRect().width)).toBe(
      0
    );
    await expect(inboxTabBadge(page)).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("viewing a needs-review task in Chat Sidebar clears its attention", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我已经处理了",
    inlineTaskReference: true,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-review-sidebar@comma.local",
      token: "comma_sess_task_review_sidebar",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("完成任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const panelDot = content
      .getByTestId(`chat-task-item-${chatSmokeTaskConversation.id}`)
      .locator(".comma-chat-task-item-dot");
    await expect(panelDot).toHaveAttribute("data-state", "visible");

    const inlineTask = content
      .locator('[data-message-id="msg-assistant-smoke"]')
      .getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`);
    await inlineTask.click();

    await expect(
      content.getByTestId(`chat-sidebar-conversation-${chatSmokeTaskConversation.id}`)
    ).toBeVisible();
    await expect.poll(() => taskSeenRevision(page)).toBe(taskProjectionUpdatedAt);
    await expect(panelDot).toHaveAttribute("data-state", "hidden");
  } finally {
    await stub.close();
  }
});

test("does not clear task attention before its detail is loaded", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-review-pending@comma.local",
      token: "comma_sess_task_review_pending",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();

    const mainRow = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await expect(dotIn(mainRow)).toHaveAttribute("data-state", "visible");

    stub.holdNextTaskDetail();
    await mainRow.click();
    await stub.waitForDelayedTaskDetail();

    expect(await taskSeenRevision(page)).toBeNull();

    stub.releaseDelayedTaskDetail();
    await expect(
      page.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect.poll(() => taskSeenRevision(page)).toBe(taskProjectionUpdatedAt);
  } finally {
    await stub.close();
  }
});

test("keeps refreshed task attention until the newer detail is rendered", async ({
  page,
}) => {
  const initialReply = "Initial review detail.";
  const updatedReply = "Updated review detail.";
  const updatedTitle = "冒烟任务（已更新）";
  const updatedAt = chatSmokeTaskConversation.updated_at + 10;
  const updatedProjectionRevision = updatedAt * 1_000;
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: [initialReply],
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-review-refresh@comma.local",
      token: "comma_sess_task_review_refresh",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Inbox" }).click();

    const initialRow = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await initialRow.click();
    await expect(
      page.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect(page.getByText(initialReply)).toBeVisible();
    await expect.poll(() => taskSeenRevision(page)).toBe(taskProjectionUpdatedAt);
    await expect.poll(() => stub.activeTaskListEventStreams).toBeGreaterThan(0);

    stub.holdNextTaskDetail();
    stub.publishTaskReviewUpdate({
      assistantMessages: [updatedReply],
      title: updatedTitle,
      updatedAt,
    });
    await stub.waitForDelayedTaskDetail();

    // ProductInbox already exposes revision N while the Task view still renders
    // N-1. The dot must re-arm, and the seen mark must stay at N-1 until the
    // matching detail response reaches the screen.
    const updatedRow = page.getByTestId("inbox-item").filter({ hasText: updatedTitle });
    await expect(updatedRow).toBeVisible();
    await expect(
      page.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect(page.getByText(initialReply)).toBeVisible();
    await expect(page.getByText(updatedReply)).toHaveCount(0);
    expect(await taskSeenRevision(page)).toBe(taskProjectionUpdatedAt);
    await expect(dotIn(updatedRow)).toHaveAttribute("data-state", "visible");

    stub.releaseDelayedTaskDetail();
    await expect(page.getByRole("heading", { name: updatedTitle })).toBeVisible();
    await expect(page.getByText(updatedReply)).toBeVisible();
    await expect.poll(() => taskSeenRevision(page)).toBe(updatedProjectionRevision);
    await expect(dotIn(updatedRow)).toHaveAttribute("data-state", "hidden");
  } finally {
    await stub.close();
  }
});

test("clears the Inbox tab badge when no unread items remain", async ({ page }) => {
  const stub = await startChatSmokeStub({
    extraInlineTasks: [
      { id: "cnv_task_att_running", status: "in_progress", title: "整理季度 OKR 草稿" },
    ],
    includeTaskInInbox: true,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-review-inbox-tab@comma.local",
      token: "comma_sess_task_review_inbox_tab",
    });
    await page.goto("/");
    await expect(inboxTabBadge(page)).toBeVisible();
    await page.getByRole("link", { name: "Inbox" }).click();

    const mainRow = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await expect(dotIn(mainRow)).toHaveAttribute("data-state", "visible");
    await mainRow.click();
    await expect(dotIn(mainRow)).toHaveAttribute("data-state", "hidden");
    await expect(inboxTabBadge(page)).toHaveCount(0);
  } finally {
    await stub.close();
  }
});
