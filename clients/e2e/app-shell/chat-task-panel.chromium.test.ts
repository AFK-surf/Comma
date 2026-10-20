import { expect, test, type Locator } from "./support/page";
import { waitForSettledMotion } from "./support/motion";
import type { WebAppStubOptions } from "./fixtures/web-app/stub";
import {
  stepUntil,
  stepUntilAnimationsFinish,
  testClock,
} from "./support/virtual-time";
import { useWebApp } from "./support/web-app";

// The Tasks panel and inline Tasks, on the web app as one world
// (./support/web-app): the app, its client core's worker and the chat stub
// server move on the test's time. Each test starts the stub with its own
// options.

// The chat stub's task (e2e/p0/chat-stub.ts, chatSmokeTaskConversation): the
// stub itself runs in its own process, not in this page.
const smokeTaskId = "cnv_public_task_smoke";
const taskTitle = "冒烟任务";

const taskFleet = [
  { id: "cnv_task_fleet_1", status: "in_progress", title: "整理季度 OKR 草稿" },
  { id: "cnv_task_fleet_2", status: "needs_review", title: "翻译产品发布公告" },
  {
    id: "cnv_task_fleet_3",
    status: "in_progress",
    title: "汇总本周用户反馈并归类到对应模块，标注优先级和负责人，输出跟进清单",
  },
  { id: "cnv_task_fleet_4", status: "completed", title: "生成周报摘要" },
  { id: "cnv_task_fleet_5", status: "in_progress", title: "排查构建缓存问题" },
] as const;

// The second task of "inline tasks reuse independent sidebar tabs…".
const secondTask = {
  id: "cnv_second_task",
  status: "needs_review",
  title: "Second task",
};

// Quick Chat reaches Home as the person's words. A later Router reply can
// name a Task, just as it can after a typed request.
const quickChatWords = "Book a table for four tonight";
const quickChatMessage = {
  actor_type: "user",
  content: [{ type: "text", text: quickChatWords }],
  created_at: 1_720_000_001,
  kind: "message",
  message_id: "msg-quick-chat",
  metadata: { source: "group_router", message_type: "quick_chat" },
} as const;
const quickChatRouterReply = {
  actor_type: "agent",
  content: [
    { type: "text", text: "I created a task to book the table." },
    {
      type: "conversation_ref",
      conversation_id: smokeTaskId,
      kind: "agent_task",
      presentation: "inline",
    },
  ],
  created_at: 1_720_000_002,
  kind: "message",
  message_id: "msg-quick-chat-router",
} as const;

const stubs: Record<string, WebAppStubOptions["stub"]> = {
  "Quick Chat shows the person's words before a Router reply creates a Task card": {
    taskStatus: "in_progress",
    workspaceTranscript: [],
  },
  "a stored Quick Chat message still opens the Task it names": {
    taskStatus: "in_progress",
    workspaceTranscript: [
      {
        ...quickChatMessage,
        content: [quickChatMessage.content[0], quickChatRouterReply.content[1]],
      },
    ],
  },
  "agent-created task docks above the composer, reveals its turn, and opens its chat": {
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    taskStatus: "in_progress",
  },
  "archive sits with a settled task's reveal actions": {
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    taskStatus: "completed",
  },
  "a revealed task turn releases the bounded window after handoff": {
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    laterChatTurns: 8,
    taskStatus: "in_progress",
  },
  "six tasks keep creation order and scroll inside the panel": {
    assistantReply: "我已经创建了任务",
    extraInlineTasks: taskFleet,
    inlineTaskReference: true,
    taskStatus: "in_progress",
  },
  "a revealed turn holds while the run keeps working": {
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    keepThinkingAfterReply: true,
    laterChatTurns: 60,
    taskStatus: "in_progress",
  },
  "Home task row stays mounted and does not reveal again across Inbox refresh: settled":
    {
      includeTaskInInbox: true,
      inlineTaskReference: true,
      taskStatus: "completed",
    },
  "Home task row stays mounted and does not reveal again across Inbox refresh: in-flight":
    {
      includeTaskInInbox: true,
      inlineTaskReference: true,
      taskStatus: "completed",
    },
  "Home task row stays mounted and does not reveal again across Inbox refresh: reduced-motion":
    {
      includeTaskInInbox: true,
      inlineTaskReference: true,
      taskStatus: "completed",
    },
  "archived inline tasks remain visible and inert, and task previews stay outside the browser sidebar":
    {
      assistantReply: "[Open docs](https://example.com/docs)",
      inlineTaskReference: true,
      includeTaskInInbox: true,
      taskConversationExtras: { labels: ["lbl_work"], origin: "comma" },
      taskLabels: [{ id: "lbl_work", name: "Work", color: "blue" }],
      taskStatus: "completed",
    },
  "inline tasks reuse independent sidebar tabs and route explicit opens to task details":
    {
      inlineTaskReference: true,
      extraInlineTasks: [secondTask],
      additionalTaskRefs: [
        {
          ...secondTask,
          browserLink: { label: "Docs", url: "https://example.com/docs" },
        },
      ],
      taskStatus: "completed",
      taskTranscript: [
        {
          message_id: "task-sidebar-reply",
          actor_type: "agent",
          agent_id: "actor_worker",
          role_label: "worker",
          kind: "message",
          created_at: 1720000010,
          content: [{ type: "text", text: "The task result is ready." }],
        },
      ],
    },
};

/**
 * Moves page time a frame at a time until `check` passes on what `read` gives
 * (as Playwright's `expect.poll` waits), then checks it once more so a
 * failure reports the value.
 */
async function eventually<T>(read: () => T | Promise<T>, check: (value: T) => void) {
  await stepUntil(async () => {
    try {
      check(await read());
      return true;
    } catch {
      return false;
    }
  });
  check(await read());
}

const app = useWebApp(
  (name) => {
    const stub = stubs[name];
    if (!stub) throw new Error(`No chat stub for "${name}"`);
    return stub;
  },
  { records: true }
);

test("inline tasks reuse independent sidebar tabs and route explicit opens to task details", async ({
  page,
}) => {
  await app.open(page);
  const main = page.locator('.comma-chat-route[data-variant="home"]');
  await main.getByRole("textbox", { name: "AI prompt" }).fill("Create tasks");
  await main.getByRole("button", { name: "Send", exact: true }).click();
  const first = main.getByTestId(`chat-inline-task-${smokeTaskId}`);
  const second = main.getByTestId(`chat-inline-task-${secondTask.id}`);
  const routerGroup = main.locator('[data-actor-role="router"]');
  await expect(routerGroup).toHaveCount(2);
  // Home replies omit the redundant Router label and avatar.
  await expect(routerGroup.first()).toHaveAttribute(
    "data-router-identity-hidden",
    "true"
  );
  await expect(routerGroup.last()).toHaveAttribute(
    "data-router-identity-hidden",
    "true"
  );
  await expect(routerGroup.locator(".comma-chat-assistant-source-label")).toHaveCount(
    0
  );
  await expect(routerGroup.locator(".comma-chat-assistant-router-mark")).toHaveCount(0);
  await first.click();
  const sidebar = page.getByTestId("chat-sidebar");
  await expect(sidebar.getByRole("tab", { name: taskTitle })).toBeVisible();
  await expect(sidebar.locator(".markdown-stream-bubble").first()).toBeVisible();
  await eventually(
    async () => {
      const bubble = await sidebar
        .locator(".markdown-stream-bubble")
        .first()
        .boundingBox();
      const input = await sidebar.locator(".comma-chat-composer").boundingBox();
      return Math.abs(bubble!.x - input!.x);
    },
    (value) => expect(value).toBeLessThanOrEqual(1)
  );
  // The sidebar is still opening: the thread narrows under the pointer.
  await stepUntilAnimationsFinish();
  await second.click();
  await expect(sidebar.getByRole("tab", { name: secondTask.title })).toBeVisible();
  await expect(sidebar.getByRole("tab", { name: taskTitle })).toBeVisible();
  await first.click();
  await expect(sidebar.getByRole("tab", { name: taskTitle })).toHaveAttribute(
    "aria-selected",
    "true"
  );
  await expect(sidebar.getByRole("tab", { name: taskTitle })).toHaveCount(1);
  await expect(
    sidebar
      .getByRole("tab", { name: taskTitle })
      .locator('[data-task-status="completed"]')
  ).toBeVisible();
  await sidebar.getByRole("tab", { name: secondTask.title }).hover();
  await sidebar.getByRole("button", { name: "Close Second task" }).click();
  await expect(sidebar.getByRole("tab", { name: secondTask.title })).toHaveCount(0);

  await first.click({ button: "right" });
  await expect(
    page.getByRole("menuitem", { name: "Open in sidebar", exact: true })
  ).toBeVisible();
  await page.getByRole("menuitem", { name: "Open task", exact: true }).click();
  const taskPath = `/tasks/${"ws-smoke"}/${"grp-smoke"}/${smokeTaskId}`;
  await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
  await page.goBack();
  await first.click({ modifiers: ["Meta"] });
  await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
  await page.goBack();
  await first.click();
  await sidebar.getByRole("button", { name: "Open task", exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
});

test("archived inline tasks remain visible and inert, and task previews stay outside the browser sidebar", async ({
  page,
}) => {
  await app.open(page);
  const main = page.locator('.comma-chat-route[data-variant="home"]');
  await main
    .getByRole("textbox", { name: "AI prompt" })
    .fill(`Check [${taskTitle}](comma:task/${smokeTaskId})`);
  await main.getByRole("button", { name: "Send", exact: true }).click();
  await main.getByRole("link", { name: "Open docs" }).click();
  const sidebar = page.getByTestId("chat-sidebar");
  await expect(sidebar).toBeVisible();
  const external = sidebar
    .getByRole("form", { name: "Browser navigation" })
    .getByRole("button", { name: "Open in default browser", exact: true });
  await external.hover();
  await expect(
    page.getByRole("tooltip", { name: "Open in default browser" })
  ).toBeVisible();
  const popupPromise = page.waitForEvent("popup");
  await external.click();
  const popup = await popupPromise;
  await expect(popup).toHaveURL("https://example.com/docs");
  await popup.close();

  const userTask = main
    .locator('[data-slot="chat-user-output"]')
    .getByTestId(`chat-inline-task-${smokeTaskId}`);
  // The card draws its chips from the Task record while its preview fails.
  await app.stub().call("setTaskPreviewsFailing", true);
  await userTask.hover();
  const card = page.locator('[data-slot="hover-card"]');
  await expect(card).toBeVisible();
  await expect(card.getByTestId("task-card-label")).toHaveText("Work");
  await expect(card.getByTestId("task-card-platform")).toHaveText("Comma");
  await app.stub().call("setTaskPreviewsFailing", false);

  await eventually(
    async () => {
      const [preview, boundary, side] = await Promise.all([
        card.boundingBox(),
        main.boundingBox(),
        sidebar.boundingBox(),
      ]);
      return Boolean(
        preview &&
        boundary &&
        side &&
        preview.x >= boundary.x &&
        preview.x + preview.width <= Math.min(boundary.x + boundary.width, side.x) + 1
      );
    },
    (inside) => expect(inside).toBe(true)
  );
  await userTask.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
  const references = main.getByTestId(`chat-inline-task-${smokeTaskId}`);
  await expect(references).toHaveCount(2);
  for (const reference of await references.all()) {
    await expect(reference).toHaveAttribute("data-status", "archived");
    await expect(reference).toHaveAttribute("aria-disabled", "true");
    await expect(reference).toContainText(taskTitle);
    await expect(reference.locator("svg")).toHaveCount(1);
    await reference.click({ force: true });
    await reference.click({ button: "right", force: true });
    await expect(page.getByRole("menu")).toHaveCount(0);
  }
  await expect(page).not.toHaveURL(/#\/tasks\//);
});

test("agent-created task docks above the composer, reveals its turn, and opens its chat", async ({
  page,
}) => {
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
  await composer.getByRole("button", { name: "Send" }).click();

  const panel = content.getByTestId("chat-task-panel");
  await expect(panel).toBeVisible();
  const item = panel.getByTestId(`chat-task-item-${smokeTaskId}`);
  await expect(item).toContainText(taskTitle);
  await expect(item).toContainText("In progress");

  for (const width of [1280, 800, 500]) {
    await page.setViewportSize({ width, height: 800 });
    await eventually(
      async () => {
        const bubble = await content
          .locator(".markdown-stream-bubble")
          .first()
          .boundingBox();
        const input = await composer.boundingBox();
        const tasks = await panel.boundingBox();
        return Math.max(
          Math.abs(bubble!.x - input!.x),
          Math.abs(bubble!.x - tasks!.x),
          Math.abs(tasks!.x + tasks!.width - input!.x - input!.width)
        );
      },
      (value) => expect(value).toBeLessThanOrEqual(1)
    );
  }

  // The panel docks above the input, inside the composer frame.
  expect(
    await page.evaluate(() => {
      const dockedPanel = document.querySelector(".comma-chat-task-panel");
      const composerShell = document.querySelector(".comma-chat-composer-shell");
      return dockedPanel && composerShell
        ? Boolean(
            dockedPanel.compareDocumentPosition(composerShell) &
            Node.DOCUMENT_POSITION_FOLLOWING
          )
        : false;
    })
  ).toBe(true);

  // Holding the Tasks title must not shrink its hit target or text.
  const toggle = panel.getByTestId("chat-task-panel-toggle");
  await toggle.hover();
  await waitForSettledMotion(page.locator("body"));
  const beforePress = await toggle.boundingBox();
  await page.mouse.down();
  await waitForSettledMotion(toggle);
  const duringPress = await toggle.boundingBox();
  expect(duringPress!.width).toBeCloseTo(beforePress!.width, 1);
  expect(duringPress!.height).toBeCloseTo(beforePress!.height, 1);
  await page.mouse.up();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  // Folded, the panel is its header line alone, so the count sits on the
  // panel's vertical centre: nothing of the list is left under it.
  await expect(item).toHaveCount(0);
  const folded = await panel.boundingBox();
  const header = await toggle.boundingBox();
  expect(header!.y - folded!.y).toBeCloseTo(
    folded!.y + folded!.height - (header!.y + header!.height),
    1
  );
  await toggle.focus();
  await page.keyboard.press("Enter");
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(item).toBeVisible();

  // The row's text actions live under the pointer.
  const reveal = item.getByRole("button", { name: /^Reveal in chat:/ });
  await expect(reveal).toHaveText("Reveal in Chat");
  expect(await reveal.evaluate((element) => getComputedStyle(element).opacity)).toBe(
    "0"
  );
  await item.hover();
  await eventually(
    async () => reveal.evaluate((element) => getComputedStyle(element).opacity),
    (value) => expect(value).toBe("1")
  );

  await reveal.click();
  await expect(
    content.locator('[data-message-id="msg-assistant-smoke"]')
  ).toBeInViewport();

  // Anywhere else on the row — here its leading inset, outside every
  // control's own box — opens the Task's chat beside this one, the way the
  // Task's chip in the transcript does. It is navigation: the row stays.
  const sidebarChat = page.getByTestId(`chat-sidebar-conversation-${smokeTaskId}`);
  await expect(sidebarChat).toHaveCount(0);
  await item.click({ position: { x: 2, y: 2 } });
  await expect(sidebarChat).toBeVisible();
  await expect(item).toBeVisible();
});

test("Quick Chat shows the person's words before a Router reply creates a Task card", async ({
  page,
}) => {
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  // The chat's next read brings the spoken words, without creating a Task.
  await eventually(
    async () => (await app.stub().call("initialChatSnapshotServed")) as boolean,
    (served) => expect(served).toBe(true)
  );
  await app.stub().call("publishWorkspaceChatMessage", quickChatMessage);
  const spoken = content.locator(
    '[data-slot="chat-user-output"][data-message-id="msg-quick-chat"]'
  );
  await expect(spoken.locator(".comma-chat-user-bubble")).toHaveText(quickChatWords);
  await expect(content.getByTestId("chat-task-card-" + smokeTaskId)).toHaveCount(0);
  await expect(content.getByTestId("chat-task-panel")).toHaveCount(0);
  await expect(spoken.locator('[data-source="quick-chat"]')).toHaveAttribute(
    "title",
    "Sent with Quick Chat"
  );

  await app.stub().call("publishWorkspaceChatMessage", quickChatRouterReply);
  const reply = content.locator('[data-message-id="msg-quick-chat-router"]');
  const card = reply.getByTestId(`chat-task-card-${smokeTaskId}`);
  await expect(card).toContainText(taskTitle);
  await expect(spoken.getByTestId(`chat-task-card-${smokeTaskId}`)).toHaveCount(0);

  // The person's words stay on the right; the Router's Task card sits on
  // the transcript's left edge, in the Router's own reply.
  await waitForSettledMotion(reply);
  const [messageBox, wordsBox, cardBox] = await Promise.all([
    spoken.boundingBox(),
    spoken.locator(".comma-chat-user-bubble").boundingBox(),
    card.boundingBox(),
  ]);
  expect(messageBox).not.toBeNull();
  expect(wordsBox).not.toBeNull();
  expect(cardBox).not.toBeNull();
  expect(Math.abs(cardBox!.x - messageBox!.x)).toBeLessThanOrEqual(1);
  expect(
    Math.abs(wordsBox!.x + wordsBox!.width - messageBox!.x - messageBox!.width)
  ).toBeLessThanOrEqual(1);
  expect(cardBox!.y).toBeGreaterThanOrEqual(wordsBox!.y + wordsBox!.height);

  const panel = content.getByTestId("chat-task-panel");
  const item = panel.getByTestId(`chat-task-item-${smokeTaskId}`);
  await expect(item).toContainText("In progress");
  await item.hover();
  await panel.getByTestId(`chat-task-reveal-${smokeTaskId}`).click();
  await expect(reply).toBeInViewport();
  await expect(reply.locator(".comma-chat-assistant-response-body")).toHaveAttribute(
    "data-reveal-highlight",
    "true"
  );

  const sidebarChat = page.getByTestId(`chat-sidebar-conversation-${smokeTaskId}`);
  await expect(sidebarChat).toHaveCount(0);
  await card.click();
  await expect(sidebarChat).toBeVisible();
});

test("a stored Quick Chat message still opens the Task it names", async ({ page }) => {
  await app.open(page);
  const spoken = page.locator(
    '[data-slot="chat-user-output"][data-message-id="msg-quick-chat"]'
  );
  await expect(spoken.locator(".comma-chat-user-bubble")).toHaveText(quickChatWords);
  const card = spoken.getByTestId(`chat-task-card-${smokeTaskId}`);
  await expect(card).toContainText(taskTitle);
  await card.click();
  await expect(
    page.getByTestId(`chat-sidebar-conversation-${smokeTaskId}`)
  ).toBeVisible();
});

test("archive sits with a settled task's reveal actions", async ({ page }) => {
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  await composer.getByRole("textbox", { name: "AI prompt" }).fill("创建可归档任务");
  await composer.getByRole("button", { name: "Send" }).click();

  const panel = content.getByTestId("chat-task-panel");
  const item = panel.getByTestId(`chat-task-item-${smokeTaskId}`);
  const archive = item.getByRole("button", {
    name: "Archive task",
    exact: true,
  });
  const dismiss = item.locator(".comma-chat-task-item-dismiss");
  const reveal = item.locator(".comma-chat-task-item-reveal");
  const toggleSidebar = page
    .getByTestId("comma-window-bar")
    .getByRole("button", { name: "New tab" });

  // Open the Task, Dismiss, Reveal in Chat, Archive — one hover cluster.
  await expect(item.getByRole("button")).toHaveCount(4);
  await expect(archive).toHaveCount(1);
  await item.hover();
  await expect(archive).toBeVisible();
  await eventually(
    async () => reveal.evaluate((element) => getComputedStyle(element).opacity),
    (value) => expect(value).toBe("1")
  );

  await archive.hover();
  await waitForSettledMotion(archive);
  await eventually(
    async () => dismiss.evaluate((element) => getComputedStyle(element).opacity),
    (value) => expect(value).toBe("1")
  );
  await eventually(
    async () => reveal.evaluate((element) => getComputedStyle(element).opacity),
    (value) => expect(value).toBe("1")
  );

  await toggleSidebar.hover();
  await waitForSettledMotion(toggleSidebar);
  const toggleSidebarHover = await readIconHoverSurface(toggleSidebar);
  expect(toggleSidebarHover).toMatchObject({ height: 28, width: 28 });
  await archive.hover();
  await waitForSettledMotion(archive);
  const archiveHover = await readIconHoverSurface(archive);
  expect(archiveHover.backgroundColor).toBe(toggleSidebarHover.backgroundColor);
  expect(archiveHover.borderRadius).toBe(toggleSidebarHover.borderRadius);
  expect(archiveHover.color).toBe(toggleSidebarHover.color);
  expect(archiveHover).toMatchObject({
    height: 20,
    width: 20,
    paddingBottom: "2px",
    paddingLeft: "2px",
    paddingRight: "2px",
    paddingTop: "2px",
  });

  for (const action of [dismiss, reveal]) {
    const radius = await action.evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        actual: style.borderRadius,
        expected: style.getPropertyValue("--radius-full").trim(),
      };
    });
    expect(radius.actual).toBe(radius.expected);
  }

  const revealBox = await reveal.boundingBox();
  const archiveBox = await archive.boundingBox();
  expect(revealBox).not.toBeNull();
  expect(archiveBox).not.toBeNull();
  expect(revealBox!.x + revealBox!.width).toBeLessThanOrEqual(archiveBox!.x);

  await archive.click();
  await expect(
    page.getByRole("menuitem", { name: "Archive task", exact: true })
  ).toBeVisible();
  // Opening the clustered menu must not open, reveal, or dismiss the row.
  await expect(item).toBeVisible();
  await expect(
    page.getByTestId(`chat-sidebar-conversation-${smokeTaskId}`)
  ).toHaveCount(0);
});

for (const arrivalMode of ["settled", "in-flight", "reduced-motion"] as const) {
  test(`Home task row stays mounted and does not reveal again across Inbox refresh: ${arrivalMode}`, async ({
    page,
  }) => {
    await page.emulateMedia({
      reducedMotion: arrivalMode === "reduced-motion" ? "reduce" : "no-preference",
    });
    await app.open(page);
    await page.evaluate(
      ({ taskId, pause }) => {
        const probe = {
          count: 0,
          duration: "",
          animation: undefined as Animation | undefined,
        };
        document.addEventListener(
          "animationstart",
          (event) => {
            if (
              event.animationName !== "comma-chat-task-item-reveal" ||
              !(event.target instanceof HTMLElement) ||
              event.target.dataset["testid"] !== `chat-task-item-${taskId}`
            )
              return;
            probe.count++;
            probe.duration = getComputedStyle(event.target).animationDuration;
            if (pause && probe.count === 1) {
              const animation = event.target
                .getAnimations()
                .find(
                  (candidate) =>
                    candidate instanceof CSSAnimation &&
                    candidate.animationName === event.animationName
                );
              if (!animation) throw new Error("Task reveal animation not found");
              animation.pause();
              probe.animation = animation;
            }
          },
          true
        );
        Reflect.set(window, "__commaTaskRevealProbe", probe);
      },
      { taskId: smokeTaskId, pause: arrivalMode === "in-flight" }
    );
    const home = page.locator('.comma-chat-route[data-variant="home"]');
    await home.getByRole("textbox", { name: "AI prompt" }).fill("创建可归档任务");
    await home.getByRole("button", { name: "Send" }).click();
    const panel = home.getByTestId("chat-task-panel");
    const item = panel.getByTestId(`chat-task-item-${smokeTaskId}`);
    const archive = panel.locator('[aria-label="Archive task"]');
    await expect(item).toBeVisible();
    await expect(archive).toHaveCount(1);
    await eventually(
      () => page.evaluate(() => Reflect.get(window, "__commaTaskRevealProbe").count),
      (value) => expect(value).toBe(1)
    );
    if (arrivalMode === "in-flight") {
      await expect(item).toHaveAttribute("data-arriving", "true");
      expect(
        await page.evaluate(() => {
          const animation = Reflect.get(window, "__commaTaskRevealProbe")
            .animation as Animation;
          return (
            animation.playState === "paused" &&
            Number(animation.currentTime) <
              Number(animation.effect!.getTiming().duration)
          );
        })
      ).toBe(true);
    } else {
      await expect(item).not.toHaveAttribute("data-arriving");
    }
    if (arrivalMode === "reduced-motion") {
      expect(
        await page.evaluate(
          () => matchMedia("(prefers-reduced-motion: reduce)").matches
        )
      ).toBe(true);
      expect(
        await page.evaluate(
          () => Reflect.get(window, "__commaTaskRevealProbe").duration
        )
      ).toBe("0s");
    }
    const originalItem = await item.elementHandle();
    expect(originalItem).not.toBeNull();
    const ownerReads = (await app
      .stub()
      .call("conversationListRequestCount")) as number;
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    // The list changes while Inbox shows it: the client core reads it again.
    await app.stub().call("invalidateTaskList");
    await eventually(
      async () => (await app.stub().call("conversationListRequestCount")) as number,
      (value) => expect(value).toBeGreaterThan(ownerReads)
    );
    // Current owner facts keep the archive control available during revalidation.
    await expect(archive).toHaveCount(1);
    expect(await originalItem!.evaluate((element) => element.isConnected)).toBe(true);
    if (arrivalMode === "in-flight") {
      // Resume the browser's real CSS animation while Home is hidden. No
      // synthetic animation events stand in for completion or cancellation.
      await expect(item).toHaveAttribute("data-arriving", "true");
      await page.evaluate(() =>
        (Reflect.get(window, "__commaTaskRevealProbe").animation as Animation).play()
      );
    }
    await expect(item).not.toHaveAttribute("data-arriving");
    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect(item).toBeVisible();
    await expect(archive).toHaveCount(1);
    expect(
      await item.evaluate((element, original) => element === original, originalItem)
    ).toBe(true);
    await waitForSettledMotion(item);
    expect(
      await page.evaluate(() => Reflect.get(window, "__commaTaskRevealProbe").count)
    ).toBe(1);
  });
}

test("a revealed task turn releases the bounded window after handoff", async ({
  page,
}) => {
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  await composer.getByRole("textbox", { name: "AI prompt" }).fill("创建任务");
  await composer.getByRole("button", { name: "Send" }).click();

  const thread = content.locator(".comma-home-chat .comma-chat-thread");
  const firstTurn = content.locator('[data-message-id="msg-user-smoke"]');
  await expect(firstTurn).toHaveCount(0);
  await expect(thread).toHaveAttribute("data-comma-turn-window-start", /^[1-9]\d*$/);

  await content.getByTestId(`chat-task-reveal-${smokeTaskId}`).click();
  await expect(thread).toHaveAttribute("data-comma-turn-window-start", "0");
  await expect(firstTurn).toBeInViewport();

  const viewport = content.locator(
    '.comma-home-chat [data-slot="scroll-area-viewport"]'
  );
  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
    element.dispatchEvent(new Event("scroll", { bubbles: true }));
  });
  await eventually(
    () =>
      viewport.evaluate(
        (element) => element.scrollHeight - element.clientHeight - element.scrollTop
      ),
    (value) => expect(value).toBeLessThanOrEqual(1)
  );

  await composer.getByRole("textbox", { name: "AI prompt" }).fill("继续");
  await composer.getByRole("button", { name: "Send" }).click();

  await expect(thread).toHaveAttribute("data-comma-turn-window-start", "1");
  await expect(firstTurn).toHaveCount(0);
  await expect(thread.locator("[data-chat-turn-anchor='true']")).toHaveCount(9);
});

test("six tasks keep creation order and scroll inside the panel", async ({ page }) => {
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  await composer.getByRole("textbox", { name: "AI prompt" }).fill("请安排这些任务");
  await composer.getByRole("button", { name: "Send" }).click();

  const panel = content.getByTestId("chat-task-panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator(".comma-chat-task-item")).toHaveCount(6);

  // Creation order: the announcing messages' transcript order, oldest first.
  const titles = panel.locator(".comma-chat-task-item-title");
  await expect(titles.first()).toHaveText(taskTitle);
  await expect(titles.nth(1)).toHaveText(taskFleet[0].title);
  await expect(titles.last()).toHaveText(taskFleet[4].title);

  // Each row carries its own status snapshot.
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_2")).toContainText(
    "Needs Review"
  );
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_4")).toContainText(
    "Done"
  );

  // A row is the control that opens its Task, followed by its text actions
  // in reading order: a running row offers Reveal, a settled row Dismiss and
  // then Reveal.
  const runningItem = panel.getByTestId("chat-task-item-cnv_task_fleet_5");
  const settledItem = panel.getByTestId("chat-task-item-cnv_task_fleet_2");
  await expect(runningItem.getByRole("button")).toHaveCount(2);
  await expect(settledItem.getByRole("button")).toHaveCount(3);
  await settledItem.getByRole("button", { name: /^Open task:/ }).focus();
  await page.keyboard.press("Tab");
  await expect(settledItem.getByRole("button", { name: /^Dismiss:/ })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(
    settledItem.getByRole("button", { name: /^Reveal in chat:/ })
  ).toBeFocused();

  // The row's actions lie over its trailing edge; they take no share of the
  // row at rest. Beside the Home rails the chat column is narrow, and a
  // settled row, which carries both actions, used to have no title left.
  const settledTitle = settledItem.locator(".comma-chat-task-item-title");
  const titleFits = () =>
    settledTitle.evaluate((title) => ({
      shown: title.clientWidth,
      truncated: title.scrollWidth > title.clientWidth,
    }));
  const atRest = await titleFits();
  expect(atRest.truncated).toBe(false);
  // Landing the pointer shows the actions without moving the title.
  await settledItem.hover();
  await expect(settledItem.getByRole("button", { name: /^Dismiss:/ })).toBeVisible();
  expect(await titleFits()).toEqual(atRest);
  await page.mouse.move(0, 0);

  // Past five rows the list overflows its viewport and scrolls internally.
  const scroll = panel.getByTestId("chat-task-panel-list");
  expect(
    await scroll.evaluate((element) => element.scrollHeight > element.clientHeight)
  ).toBe(true);
  await scroll.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_5")).toBeInViewport();

  // Revealing a settled row acknowledges it: reveal, then clear.
  // Running rows only reveal and stay docked.
  await panel.getByTestId("chat-task-reveal-cnv_task_fleet_4").click();
  await expect(panel.locator(".comma-chat-task-item")).toHaveCount(5);
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_4")).toHaveCount(0);
  await panel.getByTestId("chat-task-reveal-cnv_task_fleet_5").click();
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_5")).toBeVisible();

  // "Dismiss" hides a settled row without revealing its turn; a running row
  // offers no such action because it always docks.
  await expect(panel.getByTestId("chat-task-dismiss-cnv_task_fleet_5")).toHaveCount(0);
  await settledItem.hover();
  // The core records the acknowledgement before the row disappears.
  // The worker round trip need not finish within one renderer frame.
  await panel.getByTestId("chat-task-dismiss-cnv_task_fleet_2").click();
  await expect(panel.locator(".comma-chat-task-item")).toHaveCount(4);
  await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_2")).toHaveCount(0);
});

// packages/app/e2e/chat-task-panel.spec.ts: "a revealed turn holds while the
// run keeps working".
test("a revealed turn holds while the run keeps working", async ({ page }) => {
  // Reveal is the reader leaving the tail on purpose. A run that is still
  // working must not read that as "following" and pull them back down to its
  // thinking indicator a second later (COMMA-269); its next message belongs in
  // the unseen pill, and the reader decides when to go back.
  await app.open(page);

  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
  await composer.getByRole("button", { name: "Send" }).click();

  const item = content.getByTestId(`chat-task-item-${smokeTaskId}`);
  await expect(item).toContainText("In progress");

  const announcing = content.locator('[data-message-id="msg-assistant-smoke"]');
  const viewport = content.locator(
    '.comma-home-chat [data-slot="scroll-area-viewport"]'
  );
  const readTop = () => viewport.evaluate((element) => Math.round(element.scrollTop));

  await content.getByTestId(`chat-task-reveal-${smokeTaskId}`).click();
  await expect(announcing).toBeInViewport();
  const revealedTop = await readTop();

  // The run lands its next message while the reader is reading history. It
  // must announce itself rather than take the scrollport.
  await app.stub().call("commitThinkingReply");
  await expect(
    content.locator('[data-message-id="msg-assistant-thinking-1"]')
  ).toHaveCount(1);
  // Past the interaction settle, which is where a "following" thread
  // reconciles itself back onto the newest turn.
  await testClock().advance(1_400);

  await expect(announcing).toBeInViewport();
  expect(Math.abs((await readTop()) - revealedTop)).toBeLessThanOrEqual(2);
  const pill = content.locator(".comma-chat-new-pill");
  await expect(pill).toBeVisible();

  // Pressing it is how the reader asks for the tail back.
  await pill.click();
  await eventually(
    () =>
      viewport.evaluate(
        (element) => element.scrollHeight - element.clientHeight - element.scrollTop
      ),
    (value) => expect(value).toBeLessThanOrEqual(1)
  );
  await expect(pill).toHaveCount(0);
});

const readIconHoverSurface = (control: Locator) =>
  control.evaluate((element) => {
    const icon = element.querySelector("svg")?.getBoundingClientRect();
    const style = getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    return {
      backgroundColor: style.backgroundColor,
      borderRadius: style.borderRadius,
      color: style.color,
      height: Math.round(bounds.height),
      iconHeight: icon ? Math.round(icon.height) : null,
      iconWidth: icon ? Math.round(icon.width) : null,
      paddingBottom: style.paddingBottom,
      paddingLeft: style.paddingLeft,
      paddingRight: style.paddingRight,
      paddingTop: style.paddingTop,
      width: Math.round(bounds.width),
    };
  });
