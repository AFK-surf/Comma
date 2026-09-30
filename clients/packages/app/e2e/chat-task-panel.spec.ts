import { waitForSettledMotion } from "../../../e2e/helpers/motion";
import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("inline tasks reuse independent sidebar tabs and route explicit opens to task details", async ({
  page,
}) => {
  const secondTask = {
    id: "cnv_second_task",
    status: "needs_review",
    title: "Second task",
  };
  const stub = await startChatSmokeStub({
    inlineTaskReference: true,
    extraInlineTasks: [secondTask],
    additionalTaskRefs: [
      {
        ...secondTask,
        browserLink: { label: "Docs", url: "https://example.com/docs" },
      },
    ],
    taskStatus: "completed",
    taskSchedule: null,
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
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-tabs@comma.local",
      token: "comma_sess_task_tabs",
    });
    await page.goto("/");
    const main = page.locator('.comma-chat-route[data-variant="home"]');
    await main.getByRole("textbox", { name: "AI prompt" }).fill("Create tasks");
    await main.getByRole("button", { name: "Send", exact: true }).click();
    const first = main.getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`);
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
    await expect(routerGroup.locator(".comma-chat-assistant-router-mark")).toHaveCount(
      0
    );
    await first.click();
    const sidebar = page.getByTestId("chat-sidebar");
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect(sidebar.locator(".markdown-stream-bubble").first()).toBeVisible();
    await expect
      .poll(async () => {
        const bubble = await sidebar
          .locator(".markdown-stream-bubble")
          .first()
          .boundingBox();
        const input = await sidebar.locator(".comma-chat-composer").boundingBox();
        return Math.abs(bubble!.x - input!.x);
      })
      .toBeLessThanOrEqual(1);
    await second.click();
    await expect(sidebar.getByRole("tab", { name: secondTask.title })).toBeVisible();
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await first.click();
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toHaveAttribute("aria-selected", "true");
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toHaveCount(1);
    await expect(
      sidebar
        .getByRole("tab", { name: chatSmokeTaskConversation.title })
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
    const taskPath = `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
    await page.goBack();
    await first.click({ modifiers: ["Meta"] });
    await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
    await page.goBack();
    await first.click();
    await sidebar.getByRole("button", { name: "Open task", exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`#${taskPath}$`));
  } finally {
    await stub.close();
  }
});

test("archived inline tasks remain visible and inert, and task previews stay outside the browser sidebar", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "[Open docs](https://example.com/docs)",
    inlineTaskReference: true,
    includeTaskInInbox: true,
    taskConversationExtras: { labels: ["lbl_work"], origin: "comma" },
    taskSchedule: null,
    taskStatus: "completed",
  });
  try {
    await page.route(/\/task-labels(?:\?|$)/, (route) =>
      route.fulfill({
        status: route.request().method() === "OPTIONS" ? 204 : 200,
        headers: {
          "access-control-allow-origin": route.request().headers()["origin"] ?? "*",
          "access-control-allow-credentials": "true",
          "access-control-allow-headers": "*",
        },
        body:
          route.request().method() === "OPTIONS"
            ? ""
            : JSON.stringify({
                colors: [],
                proposals: [],
                labels: [{ id: "lbl_work", name: "Work", color: "blue" }],
              }),
        contentType: "application/json",
      })
    );
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-archive-preview@comma.local",
      token: "comma_sess_task_archive_preview",
    });
    await page.goto("/");
    const main = page.locator('.comma-chat-route[data-variant="home"]');
    await main
      .getByRole("textbox", { name: "AI prompt" })
      .fill(
        `Check [${chatSmokeTaskConversation.title}](comma:task/${chatSmokeTaskConversation.id})`
      );
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
    await page
      .context()
      .route("https://example.com/**", (route) =>
        route.fulfill({ contentType: "text/html", body: "<h1>Docs</h1>" })
      );
    const popupPromise = page.waitForEvent("popup");
    await external.click();
    const popup = await popupPromise;
    await expect(popup).toHaveURL("https://example.com/docs");
    await popup.close();

    const userTask = main
      .locator('[data-slot="chat-user-output"]')
      .getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`);
    await page.route(/\/preview$/, (route) => route.abort());
    await userTask.hover();
    const card = page.locator('[data-slot="hover-card"]');
    await expect(card).toBeVisible();
    await expect(card.getByTestId("task-card-label")).toHaveText("Work");
    await expect(card.getByTestId("task-card-platform")).toHaveText("Comma");
    await page.unroute(/\/preview$/);

    await expect
      .poll(async () => {
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
      })
      .toBe(true);
    await userTask.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
    const references = main.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(references).toHaveCount(2);
    for (const reference of await references.all()) {
      await expect(reference).toHaveAttribute("data-status", "archived");
      await expect(reference).toHaveAttribute("aria-disabled", "true");
      await expect(reference).toContainText(chatSmokeTaskConversation.title);
      await expect(reference.locator("svg")).toHaveCount(1);
      await reference.click({ force: true });
      await reference.click({ button: "right", force: true });
      await expect(page.getByRole("menu")).toHaveCount(0);
    }
    await expect(page).not.toHaveURL(/#\/tasks\//);
  } finally {
    await stub.close();
  }
});

/**
 * The Tasks panel above the composer, end to end through the real client: a
 * committed assistant reply carrying an inline Task ref docks a row above the
 * input, the row's actions show under the pointer, "Reveal in Chat" anchors
 * the announcing turn, and the row itself opens the Task's chat. The docking
 * is the part worth covering here — it depends on the conversation_ref block
 * surviving the real SSE-to-channel decode, which only this path produces.
 */
test("agent-created task docks above the composer, reveals its turn, and opens its chat", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    taskStatus: "in_progress",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-task-panel@comma.local",
      token: "comma_sess_chat_task_panel",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const panel = content.getByTestId("chat-task-panel");
    await expect(panel).toBeVisible();
    const item = panel.getByTestId(`chat-task-item-${chatSmokeTaskConversation.id}`);
    await expect(item).toContainText(chatSmokeTaskConversation.title);
    await expect(item).toContainText("In progress");

    for (const width of [1280, 800, 500]) {
      await page.setViewportSize({ width, height: 800 });
      await expect
        .poll(async () => {
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
        })
        .toBeLessThanOrEqual(1);
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
    await expect
      .poll(async () => reveal.evaluate((element) => getComputedStyle(element).opacity))
      .toBe("1");

    await reveal.click();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toBeInViewport();

    // Anywhere else on the row — here its leading inset, outside every
    // control's own box — opens the Task's chat beside this one, the way the
    // Task's chip in the transcript does. It is navigation: the row stays.
    const sidebarChat = page.getByTestId(
      `chat-sidebar-conversation-${chatSmokeTaskConversation.id}`
    );
    await expect(sidebarChat).toHaveCount(0);
    await item.click({ position: { x: 2, y: 2 } });
    await expect(sidebarChat).toBeVisible();
    await expect(item).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("archive sits with a settled task's reveal actions", async ({ page }) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    taskSchedule: null,
    taskStatus: "completed",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-task-archive@comma.local",
      token: "comma_sess_chat_task_archive",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("创建可归档任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const panel = content.getByTestId("chat-task-panel");
    const item = panel.getByTestId(`chat-task-item-${chatSmokeTaskConversation.id}`);
    const archive = item.getByRole("button", {
      name: "Archive task",
      exact: true,
    });
    const dismiss = item.locator(".comma-chat-task-item-dismiss");
    const reveal = item.locator(".comma-chat-task-item-reveal");
    const toggleSidebar = page.getByRole("button", { name: "Toggle chat sidebar" });

    // Open the Task, Dismiss, Reveal in Chat, Archive — one hover cluster.
    await expect(item.getByRole("button")).toHaveCount(4);
    await expect(archive).toHaveCount(1);
    await item.hover();
    await expect(archive).toBeVisible();
    await expect
      .poll(async () => reveal.evaluate((element) => getComputedStyle(element).opacity))
      .toBe("1");

    await archive.hover();
    await waitForSettledMotion(archive);
    await expect
      .poll(async () =>
        dismiss.evaluate((element) => getComputedStyle(element).opacity)
      )
      .toBe("1");
    await expect
      .poll(async () => reveal.evaluate((element) => getComputedStyle(element).opacity))
      .toBe("1");

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
      page.getByTestId(`chat-sidebar-conversation-${chatSmokeTaskConversation.id}`)
    ).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

for (const arrivalMode of ["settled", "in-flight", "reduced-motion"] as const) {
  test(`Home task row stays mounted and does not reveal again across Inbox refresh: ${arrivalMode}`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub({
      includeTaskInInbox: true,
      inlineTaskReference: true,
      taskSchedule: null,
      taskStatus: "completed",
    });
    try {
      await page.emulateMedia({
        reducedMotion: arrivalMode === "reduced-motion" ? "reduce" : "no-preference",
      });
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "chat-task-home-inbox@comma.local",
        token: "comma_sess_chat_task_home_inbox",
      });
      await page.goto("/");
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
        { taskId: chatSmokeTaskConversation.id, pause: arrivalMode === "in-flight" }
      );
      const home = page.locator('.comma-chat-route[data-variant="home"]');
      await home.getByRole("textbox", { name: "AI prompt" }).fill("创建可归档任务");
      await home.getByRole("button", { name: "Send" }).click();
      const panel = home.getByTestId("chat-task-panel");
      const item = panel.getByTestId(`chat-task-item-${chatSmokeTaskConversation.id}`);
      const archive = panel.locator('[aria-label="Archive task"]');
      await expect(item).toBeVisible();
      await expect(archive).toHaveCount(1);
      await expect
        .poll(() =>
          page.evaluate(() => Reflect.get(window, "__commaTaskRevealProbe").count)
        )
        .toBe(1);
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
      const ownerReads = stub.conversationListRequestCount;
      await page.getByRole("link", { name: "Inbox", exact: true }).click();
      await expect
        .poll(() => stub.conversationListRequestCount)
        .toBeGreaterThan(ownerReads);
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
    } finally {
      await stub.close();
    }
  });
}

test("a revealed task turn releases the bounded window after handoff", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    laterChatTurns: 8,
    taskStatus: "in_progress",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-task-window@comma.local",
      token: "comma_sess_chat_task_window",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("创建任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const thread = content.locator(".comma-home-chat .comma-chat-thread");
    const firstTurn = content.locator('[data-message-id="msg-user-smoke"]');
    await expect(firstTurn).toHaveCount(0);
    await expect(thread).toHaveAttribute("data-comma-turn-window-start", /^[1-9]\d*$/);

    await content
      .getByTestId(`chat-task-reveal-${chatSmokeTaskConversation.id}`)
      .click();
    await expect(thread).toHaveAttribute("data-comma-turn-window-start", "0");
    await expect(firstTurn).toBeInViewport();

    const viewport = content.locator(
      '.comma-home-chat [data-slot="scroll-area-viewport"]'
    );
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
      element.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await expect
      .poll(() =>
        viewport.evaluate(
          (element) => element.scrollHeight - element.clientHeight - element.scrollTop
        )
      )
      .toBeLessThanOrEqual(1);

    await composer.getByRole("textbox", { name: "AI prompt" }).fill("继续");
    await composer.getByRole("button", { name: "Send" }).click();

    await expect(thread).toHaveAttribute("data-comma-turn-window-start", "1");
    await expect(firstTurn).toHaveCount(0);
    await expect(thread.locator("[data-chat-turn-anchor='true']")).toHaveCount(9);
  } finally {
    await stub.close();
  }
});

test("a revealed turn holds while the run keeps working", async ({ page }) => {
  // Reveal is the reader leaving the tail on purpose. A run that is still
  // working must not read that as "following" and pull them back down to its
  // thinking indicator a second later (COMMA-269); its next message belongs in
  // the unseen pill, and the reader decides when to go back.
  const stub = await startChatSmokeStub({
    assistantReply: "我已经创建了任务",
    inlineTaskReference: true,
    keepThinkingAfterReply: true,
    laterChatTurns: 60,
    taskStatus: "in_progress",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-task-reveal-hold@comma.local",
      token: "comma_sess_chat_task_reveal_hold",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const item = content.getByTestId(`chat-task-item-${chatSmokeTaskConversation.id}`);
    await expect(item).toContainText("In progress");

    const announcing = content.locator('[data-message-id="msg-assistant-smoke"]');
    const viewport = content.locator(
      '.comma-home-chat [data-slot="scroll-area-viewport"]'
    );
    const readTop = () => viewport.evaluate((element) => Math.round(element.scrollTop));

    await content
      .getByTestId(`chat-task-reveal-${chatSmokeTaskConversation.id}`)
      .click();
    await expect(announcing).toBeInViewport();
    const revealedTop = await readTop();

    // The run lands its next message while the reader is reading history. It
    // must announce itself rather than take the scrollport.
    stub.commitThinkingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-thinking-1"]')
    ).toHaveCount(1);
    // Past the interaction settle, which is where a "following" thread
    // reconciles itself back onto the newest turn.
    await page.waitForTimeout(1_400);

    await expect(announcing).toBeInViewport();
    expect(Math.abs((await readTop()) - revealedTop)).toBeLessThanOrEqual(2);
    const pill = content.locator(".comma-chat-new-pill");
    await expect(pill).toBeVisible();

    // Pressing it is how the reader asks for the tail back.
    await pill.click();
    await expect
      .poll(() =>
        viewport.evaluate(
          (element) => element.scrollHeight - element.clientHeight - element.scrollTop
        )
      )
      .toBeLessThanOrEqual(1);
    await expect(pill).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

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

test("six tasks keep creation order and scroll inside the panel", async ({ page }) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我已经创建了任务",
    extraInlineTasks: taskFleet,
    inlineTaskReference: true,
    taskStatus: "in_progress",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-task-panel-fleet@comma.local",
      token: "comma_sess_chat_task_panel_fleet",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("请安排这些任务");
    await composer.getByRole("button", { name: "Send" }).click();

    const panel = content.getByTestId("chat-task-panel");
    await expect(panel).toBeVisible();
    await expect(panel.locator(".comma-chat-task-item")).toHaveCount(6);

    // Creation order: the announcing messages' transcript order, oldest first.
    const titles = panel.locator(".comma-chat-task-item-title");
    await expect(titles.first()).toHaveText(chatSmokeTaskConversation.title);
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
    await expect(panel.getByTestId("chat-task-dismiss-cnv_task_fleet_5")).toHaveCount(
      0
    );
    await settledItem.hover();
    // The clearance is the answer to the press: the row is detached by the
    // first frame after it, with no exit tween holding it on screen. Pressed
    // from inside the page, because Playwright's own click stalls frame
    // production long past the moment under test. The row left behind its own
    // press would fail this by a full state-change beat.
    const cleared = await page.evaluate(async () => {
      const row = document.querySelector(
        '[data-testid="chat-task-item-cnv_task_fleet_2"]'
      );
      document
        .querySelector<HTMLElement>(
          '[data-testid="chat-task-dismiss-cnv_task_fleet_2"]'
        )
        ?.click();
      await new Promise((resolve) => {
        requestAnimationFrame(() => resolve(undefined));
      });
      return {
        detached: row !== null && !row.isConnected,
        leaving: document.querySelectorAll(".comma-chat-task-item[data-leaving]")
          .length,
      };
    });
    expect(cleared).toEqual({ detached: true, leaving: 0 });
    await expect(panel.locator(".comma-chat-task-item")).toHaveCount(4);
    await expect(panel.getByTestId("chat-task-item-cnv_task_fleet_2")).toHaveCount(0);
  } finally {
    await stub.close();
  }
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
