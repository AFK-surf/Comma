import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeTaskLoop,
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

// The stub's Loop runs in Asia/Shanghai. On a UTC page, its rule always names
// that zone as an offset, whatever zone the machine uses.
test.use({ timezoneId: "UTC" });

const LABELS = [
  {
    color: "blue",
    description: "Add when the task is for the day job; skip when it is personal.",
    id: "lbl_work",
    name: "Work",
  },
  {
    color: "orange",
    description: "Add when someone is waiting on the result today.",
    id: "lbl_urgent",
    name: "Urgent",
  },
];

/**
 * Label and platform on the Tasks page, through the real client: the card
 * wears the Task's label and origin chips, the filter menu gains a Label and
 * a Platform section, and a chip on a card or in the Task's properties panel
 * lands on the Tasks page narrowed to exactly what it named.
 */
test("tasks page filters by label and platform and chips link through", async ({
  page,
}) => {
  const taskExtras = { labels: ["lbl_work"], origin: "slack" };
  let catalogLabels = [...LABELS];
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskConversationExtras: taskExtras,
    taskStatus: "active",
  });
  try {
    await page.route(/\/task-labels(\?|$)/, async (route) => {
      const request = route.request();
      const headers = {
        "access-control-allow-credentials": "true",
        "access-control-allow-headers": "*",
        "access-control-allow-methods": "GET,PATCH,POST,DELETE,OPTIONS",
        "access-control-allow-origin": request.headers()["origin"] ?? "*",
        vary: "origin",
      };
      if (request.method() === "OPTIONS") {
        await route.fulfill({ headers, status: 204 });
        return;
      }
      await route.fulfill({
        body: JSON.stringify({ colors: [], labels: catalogLabels, proposals: [] }),
        headers: { ...headers, "content-type": "application/json" },
        status: 200,
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-filter@comma.local",
      token: "comma_sess_tasks_filter",
    });
    await page.goto("/#/tasks");

    const card = page.locator('[data-slot="task-card"]').first();
    await expect(card).toBeVisible();
    await expect(card.getByTestId("task-card-label")).toHaveText("Work");
    await expect(card.getByTestId("task-card-platform")).toHaveText("Slack");

    // The shared task projection survives navigation. Labels must remain usable
    // when the redundant summary endpoint is unavailable on the next visit.
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await expect(page.getByTestId("tasks-route")).toHaveCount(0);
    await page.route(/\/task-summaries\?/, (route) => route.abort());
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await expect(card.getByTestId("task-card-label")).toHaveText("Work");
    await page.unroute(/\/task-summaries\?/);

    // A server-created label arrives while this Tasks page stays open.
    await expect.poll(() => stub.activeTaskListEventStreams).toBeGreaterThan(0);
    catalogLabels = [
      ...catalogLabels,
      {
        id: "lbl_release",
        name: "Release",
        color: "purple",
        description: "Add for releases.",
      },
    ];
    taskExtras.labels.push("lbl_release");
    stub.publishTaskReviewUpdate({
      assistantMessages: [],
      title: chatSmokeTaskConversation.title,
      updatedAt: chatSmokeTaskConversation.updated_at + 10,
    });
    await expect(
      card.getByTestId("task-card-label").filter({ hasText: "Release" })
    ).toBeVisible();

    const filter = page.getByRole("button", { name: "Filter tasks" });
    await filter.click();
    await page.getByRole("menuitem", { name: "Label" }).click();
    await expect(page.getByRole("dialog", { name: "Label" })).toBeVisible();
    await expect(page.getByRole("menuitemcheckbox", { name: /Work/ })).toBeVisible();
    // Compare layout sizes, not transient transformed bounds during animations.
    const capsuleDot = card
      .getByTestId("task-card-label")
      .filter({ hasText: "Work" })
      .locator(".comma-label-dot");
    const capsuleSize = await capsuleDot.evaluate((dot) => {
      const { width, height } = getComputedStyle(dot);
      return { width, height };
    });
    expect(Number.parseFloat(capsuleSize.width)).toBeGreaterThan(0);
    expect(Number.parseFloat(capsuleSize.height)).toBeGreaterThan(0);
    for (const name of [/Work/, /Urgent/, /Release/]) {
      const dot = page
        .getByRole("dialog", { name: "Label" })
        .getByRole("menuitemcheckbox", { name })
        .locator(".comma-label-dot");
      await expect(dot).toBeVisible();
      await expect
        .poll(() =>
          dot.evaluate((element) => {
            const { width, height } = getComputedStyle(element);
            return { width, height };
          })
        )
        .toEqual(capsuleSize);
    }
    const noLabel = page.getByRole("menuitemcheckbox", { name: /No label/ });
    await expect(noLabel).toBeVisible();
    await expect(noLabel.locator(".comma-label-dot")).toHaveCount(0);
    const alignedLabels = page
      .getByRole("menuitemcheckbox", { name: /Work/ })
      .locator('[data-slot="menu-item-label"]')
      .or(noLabel.locator('[data-slot="menu-item-label"]'));
    await expect(alignedLabels).toHaveCount(2);
    // Sample both labels in one layout read so submenu animation cannot leave
    // a stale expected coordinate. Half a pixel allows subpixel rounding only.
    await expect
      .poll(() =>
        alignedLabels.evaluateAll(([label, emptyLabel]) =>
          Math.abs(
            label!.getBoundingClientRect().x - emptyLabel!.getBoundingClientRect().x
          )
        )
      )
      .toBeLessThanOrEqual(0.5);
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
    await filter.click();
    await page.getByRole("menuitem", { name: "Platform" }).click();
    await expect(page.getByRole("dialog", { name: "Platform" })).toBeVisible();
    await expect(page.getByRole("menuitemcheckbox", { name: /Slack/ })).toBeVisible();
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");

    await expect(filter).toHaveAttribute("data-filtered", "false");
    await card.getByTestId("task-card-label").filter({ hasText: "Work" }).click();
    await expect(page).toHaveURL(/label=lbl_work/);
    await expect(filter).toHaveAttribute("data-filtered", "true");
    await expect(card).toBeVisible();

    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const originPill = page.getByTestId("task-panel-origin");
    await expect(originPill).toHaveText(/Slack/);
    await originPill.click();
    await expect(page).toHaveURL(/platform=slack/);
    await expect(filter).toHaveAttribute("data-filtered", "true");
    await expect(page.locator('[data-slot="task-card"]').first()).toBeVisible();
  } finally {
    await stub.close();
  }
});

for (const trigger of ["Work", "Add label", "folded Add label"]) {
  test(`label picker stays usable after removing its anchor label via ${trigger}`, async ({
    page,
  }) => {
    const taskExtras = { labels: ["lbl_work"], origin: "slack" };
    const writes: string[][] = [];
    const stub = await startChatSmokeStub({
      includeTaskInInbox: true,
      taskConversationExtras: taskExtras,
      taskStatus: "active",
    });
    try {
      await page.route(/\/task-labels(\?|$)/, (route) =>
        route.fulfill({ json: { colors: [], labels: LABELS, proposals: [] } })
      );
      await page.route(
        `**/conversations/${chatSmokeTaskConversation.id}`,
        async (route) => {
          if (route.request().method() !== "PATCH") return route.continue();
          const { labels } = route.request().postDataJSON() as { labels: string[] };
          writes.push(labels);
          taskExtras.labels = labels;
          // The refreshed conversation must contain the accepted write, so the
          // actual panel removes its chip rather than only calling a mock action.
          const response = await route.fetch({ method: "GET" });
          await route.fulfill({ response });
        }
      );
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "task-label-picker@comma.local",
        token: "comma_sess_task_label_picker",
      });
      await page.goto(
        `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
      );
      const folded = trigger === "folded Add label";
      if (folded) {
        await page.setViewportSize({ width: 641, height: 800 });
        await page.getByTestId("task-panel-toggle").click();
      }
      const panel = page.getByTestId("task-panel-labels");
      await panel
        .getByRole("button", { name: folded ? "Add label" : trigger, exact: true })
        .click();
      const picker = page.getByTestId("task-label-picker");
      const work = picker.getByRole("menuitemcheckbox", { name: "Work", exact: true });
      await expect(work).toHaveAttribute("aria-checked", "true");
      await work.click();
      await expect(
        panel.getByRole("button", { name: "Work", exact: true })
      ).toHaveCount(0);
      await expect(work).toHaveAttribute("aria-checked", "false");
      await expect(picker).toBeVisible();
      const add = panel.getByRole("button", { name: "Add label", exact: true });
      await expect
        .poll(async () => {
          const anchor = await add.boundingBox();
          const popup = await picker.boundingBox();
          if (!anchor || !popup) return Infinity;
          return (
            Math.abs(popup.x - anchor.x) +
            Math.abs(popup.y - (anchor.y + anchor.height + 4))
          );
        })
        .toBeLessThan(4);

      // Continue in the same picker after its original chip has disappeared.
      const search = picker.getByRole("textbox", { name: "Change or add labels…" });
      await search.fill("urg");
      await picker
        .getByRole("menuitemcheckbox", { name: "Urgent", exact: true })
        .click();
      await expect(
        panel.getByRole("button", { name: "Urgent", exact: true })
      ).toBeVisible();
      await search.fill("work");
      await work.click();
      await expect(
        panel.getByRole("button", { name: "Work", exact: true })
      ).toBeVisible();
      expect(writes).toEqual([[], ["lbl_urgent"], ["lbl_urgent", "lbl_work"]]);
      await page.keyboard.press("Escape");
      await expect(picker).toBeHidden();
      if (folded) await expect(page.getByTestId("task-panel-popover")).toBeVisible();
      await add.click();
      await expect(search).toHaveValue("");
      await expect(work).toHaveAttribute("aria-checked", "true");
    } finally {
      await stub.close();
    }
  });
}

test("Inbox filters chats and tasks by platform alongside task status and clears both", async ({
  page,
}) => {
  // Serve origins through the API stub so the shared host's Inbox projection,
  // including its native-bridge schema, must preserve them for the filter.
  const additionalInboxConversations = [
    chatSmokeWorkspaceChat,
    {
      id: "cnv_inbox_slack_done",
      kind: "agent_task",
      origin: "slack",
      status: "completed",
      title: "Slack completed task",
    },
    {
      id: "cnv_inbox_slack_chat",
      kind: "user_chat",
      origin: "slack",
      status: "active",
      title: "Slack conversation",
    },
    {
      id: "cnv_inbox_telegram_done",
      kind: "agent_task",
      origin: "telegram",
      status: "completed",
      title: "Telegram completed task",
    },
    {
      id: "cnv_inbox_unknown_chat",
      kind: "user_chat",
      status: "active",
      title: "Conversation without a platform",
    },
  ].map((conversation, index) => ({
    ...conversation,
    created_at: 1_720_000_010 + index,
    group_id: chatSmokeWorkspace.group_id,
    updated_at: 1_720_000_010 + index,
  }));
  const stub = await startChatSmokeStub({
    additionalInboxConversations,
    includeTaskInInbox: true,
    taskConversationExtras: { origin: "slack" },
    taskStatus: "active",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "inbox-platform-filter@comma.local",
      token: "comma_sess_inbox_platform_filter",
    });
    await page.goto("/#/inbox");

    const rows = page.getByTestId("inbox-item");
    const homeChat = page.locator(
      `[data-testid="inbox-item"][href$="/${chatSmokeWorkspaceChat.id}"]`
    );
    const trigger = page.getByTestId("inbox-filter-trigger");
    const footer = page.getByTestId("inbox-filter-footer");
    const platformPanel = page.getByTestId("inbox-platform-filter");
    const slack = page.getByRole("menuitemcheckbox", { name: /Slack/ });
    const telegram = page.getByRole("menuitemcheckbox", { name: /Telegram/ });
    const unspecified = page.getByRole("menuitemcheckbox", { name: /Unspecified/ });
    const closeFilter = async () => {
      // This scenario exercises filtering, not nested-menu keyboard focus.
      // Dismiss outside so submenu focus restoration cannot eat an Escape.
      const outside = await page
        .getByRole("heading", { name: "Inbox", exact: true })
        .boundingBox();
      expect(outside).not.toBeNull();
      // The modal backdrop, not the obscured heading, receives this click.
      await page.mouse.click(
        outside!.x + outside!.width / 2,
        outside!.y + outside!.height / 2
      );
      await expect(trigger).toHaveAttribute("aria-expanded", "false");
    };
    const openPlatforms = async () => {
      await trigger.click();
      await page.getByRole("menuitem", { name: "Platform", exact: true }).click();
      await expect(platformPanel).toBeVisible();
    };

    // Every notification, including the Chat, comes from the host list.
    await expect(homeChat).toBeVisible();
    await expect(rows).toHaveCount(6);
    await expect(trigger).toHaveAttribute("data-filtered", "false");
    await expect(footer).toHaveCount(0);
    await openPlatforms();
    await expect(platformPanel.getByRole("menuitemcheckbox")).toHaveCount(3);
    await expect(slack).toHaveAttribute("aria-checked", "true");
    await expect(slack).toContainText("3 notifications");
    await expect(telegram).toHaveAttribute("aria-checked", "true");
    await expect(telegram).toContainText("1 notification");
    await expect(unspecified).toHaveAttribute("aria-checked", "true");
    await expect(unspecified).toContainText("2 notifications");
    await unspecified.click();
    await expect(rows).toHaveCount(4);

    // Search narrows the options only; changing a searched option keeps the
    // other platform's selection and filters both Chats and Tasks.
    const search = platformPanel.getByRole("textbox");
    await search.fill("  TELE  ");
    await expect(slack).toHaveCount(0);
    await expect(telegram).toBeVisible();
    await expect(rows).toHaveCount(4);
    await telegram.click();
    await expect(telegram).toHaveAttribute("aria-checked", "false");
    await search.fill("");
    await expect(slack).toHaveAttribute("aria-checked", "true");
    await expect(rows).toHaveCount(3);
    await expect(rows.filter({ hasText: "Slack conversation" })).toBeVisible();
    await expect(rows.filter({ hasText: "Slack completed task" })).toBeVisible();
    await expect(rows.filter({ hasText: "Telegram completed task" })).toHaveCount(0);
    await expect(rows.filter({ hasText: "without a platform" })).toHaveCount(0);
    await expect(footer).toContainText("3 notifications hidden by filters");
    await expect(trigger).toHaveAttribute("data-filtered", "true");

    // An empty selection is an active filter, not an alias for all platforms.
    await slack.click();
    await expect(rows).toHaveCount(0);
    await expect(page.getByTestId("inbox-empty")).toHaveText("No notifications");
    await expect(footer).toContainText("6 notifications hidden by filters");
    await unspecified.click();
    await expect(rows).toHaveCount(2);
    await expect(rows.filter({ hasText: "without a platform" })).toBeVisible();
    await expect(homeChat).toBeVisible();
    await expect(footer).toContainText("4 notifications hidden by filters");
    await unspecified.click();
    await slack.click();
    await expect(rows).toHaveCount(3);
    await closeFilter();

    await trigger.click();
    await page.getByRole("menuitem", { name: /Task status/ }).click();
    const done = page.getByRole("menuitemcheckbox", { name: /Done/ });
    await expect(done).toContainText("2 notifications");
    await done.click();
    await expect(rows).toHaveCount(2);
    await expect(
      rows.filter({ hasText: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await expect(rows.filter({ hasText: "Slack conversation" })).toBeVisible();
    await expect(rows.filter({ hasText: "Slack completed task" })).toHaveCount(0);
    await expect(footer).toContainText("4 notifications hidden by filters");
    await closeFilter();

    // Counts still describe all loaded notifications. Selecting every option,
    // including Unspecified, restores all platforms; Task status stays in force.
    await openPlatforms();
    await expect(slack).toContainText("3 notifications");
    await expect(telegram).toContainText("1 notification");
    await telegram.click();
    await expect(rows).toHaveCount(2);
    await expect(rows.filter({ hasText: "without a platform" })).toHaveCount(0);
    await unspecified.click();
    await expect(rows).toHaveCount(4);
    await expect(rows.filter({ hasText: "without a platform" })).toBeVisible();
    await expect(rows.filter({ hasText: "completed task" })).toHaveCount(0);
    await telegram.click();
    await unspecified.click();
    await expect(rows).toHaveCount(2);
    await closeFilter();

    await page.getByRole("button", { name: "Clear Filters" }).click();
    await expect(rows).toHaveCount(6);
    await expect(footer).toHaveCount(0);
    await expect(trigger).toHaveAttribute("data-filtered", "false");
    await openPlatforms();
    await expect(slack).toHaveAttribute("aria-checked", "true");
    await expect(telegram).toHaveAttribute("aria-checked", "true");
    await expect(unspecified).toHaveAttribute("aria-checked", "true");
    await closeFilter();
  } finally {
    await stub.close();
  }
});

/**
 * What a chip's outline and type measure, from layout: a card's enter
 * transform scales its bounding box while the chips are read one at a time.
 */
const chipBox = (chip: Locator) =>
  chip.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      borderRadius: style.borderRadius,
      borderTop: style.borderTopWidth,
      fontSize: style.fontSize,
      height: style.height,
    };
  });

/** Where each named option's words start in a filter panel, in CSS px. */
const wordStarts = (panel: Locator, names: string[]) =>
  Promise.all(
    names.map((name) =>
      panel
        .getByText(name, { exact: true })
        .evaluate((element) => Math.round(element.getBoundingClientRect().left))
    )
  );

/**
 * A Loop Task (one a Loop runs or ran) on the Tasks page and in the Inbox,
 * through the real client in a real browser. The server's Loops reach the
 * cards as trigger chips, a chip opens the Tasks route narrowed to its type,
 * the Inbox icon shows the rule on hover, and both Loops filter panels align
 * their words. The jsdom TasksRoute and InboxView tests prove which Tasks and
 * notifications each filter choice keeps.
 */
test("Loop Tasks show their trigger labels and aligned filter choices", async ({
  page,
}) => {
  const oneOff = {
    created_at: 1_720_000_010,
    group_id: chatSmokeWorkspace.group_id,
    id: "cnv_one_off_task",
    kind: "agent_task",
    status: "active",
    title: "One-off report",
    updated_at: 1_720_000_010,
  };
  const eventTask = {
    ...oneOff,
    id: "cnv_event_task",
    title: "PR updates",
    loop: {
      state: "active",
      cadence: { events: "new comments" },
      started_at: 1_720_000_002_000,
      wake_count: 2,
    },
  };
  const stub = await startChatSmokeStub({
    additionalInboxConversations: [oneOff, eventTask],
    includeTaskInInbox: true,
    taskConversationExtras: { labels: ["lbl_work"] },
    taskLoop: chatSmokeTaskLoop,
    taskStatus: "active",
  });
  try {
    await page.route(/\/task-labels(\?|$)/, (route) =>
      route.fulfill({ json: { colors: [], labels: LABELS, proposals: [] } })
    );
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-schedules@comma.local",
      token: "comma_sess_tasks_loops",
    });
    await page.goto("/#/tasks");

    const cards = page.locator('[data-slot="task-card"]');
    const loopCard = cards.filter({ hasText: chatSmokeTaskConversation.title });
    const oneOffCard = cards.filter({ hasText: oneOff.title });
    await expect(oneOffCard).toBeVisible();
    await expect(loopCard.locator("[data-chip]")).toHaveText(["Scheduled", "Work"]);
    await expect(
      cards.filter({ hasText: eventTask.title }).getByTestId("task-card-schedule")
    ).toHaveText("On updates");
    await expect(oneOffCard.getByTestId("task-card-schedule")).toHaveCount(0);
    // Trigger chips keep the Label chip's geometry.
    const schedule = loopCard.getByTestId("task-card-schedule");
    const label = loopCard.getByTestId("task-card-label");
    await expect(schedule.locator("svg")).toBeVisible();
    expect(await chipBox(schedule)).toEqual(await chipBox(label));

    const filter = page.getByRole("button", { name: "Filter tasks" });
    await filter.click();
    await page.getByRole("menuitem", { name: "Loops" }).click();
    const panel = page.getByRole("dialog", { name: "Loops" });
    // "No loop" keeps an empty icon slot, so both options' words line up.
    const [loopWords, oneOffWords] = await wordStarts(panel, ["Scheduled", "No loop"]);
    expect(oneOffWords).toBe(loopWords);
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");

    // The chip goes through the app's hash route.
    await schedule.click();
    await expect(page).toHaveURL(/#\/tasks\?schedule=scheduled$/);
    await expect(filter).toHaveAttribute("data-filtered", "true");
    await expect(loopCard).toBeVisible();
    await expect(oneOffCard).toHaveCount(0);

    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    const rows = page.getByTestId("inbox-item");
    const loopRow = rows.filter({ hasText: chatSmokeTaskConversation.title });
    await expect(rows.filter({ hasText: oneOff.title })).toBeVisible();
    await expect(
      loopRow.getByTestId("inbox-item-schedule").locator("svg")
    ).toBeVisible();
    // The compact icon previews the same trigger as a card's type label.
    await loopRow.getByTestId("inbox-item-schedule").hover();
    const loopPreview = page.getByRole("tooltip");
    await expect(loopPreview).toContainText("Scheduled");
    await expect(loopPreview.getByRole("listitem")).toHaveText([
      "Every day at 9:00 AM · GMT+8",
    ]);
    await page.keyboard.press("Escape");
    // The pointer still rests on that icon. Move it off the list until the
    // preview is gone, so the walk below starts with a new hover.
    await page.mouse.move(800, 400);
    await expect(page.getByRole("tooltip")).toHaveCount(0);
    // Down the list, one preview after another: an open preview never covers
    // the icon of a row below it, so a pointer moving down reaches the next one.
    const marks = [loopRow, rows.filter({ hasText: eventTask.title })].map((row) =>
      row.getByTestId("inbox-item-schedule")
    );
    const centers = await Promise.all(
      marks.map(async (mark) => {
        const box = (await mark.boundingBox())!;
        return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      })
    );
    const down = centers[0]!.y < centers[1]!.y ? [0, 1] : [1, 0];
    const [from, to] = down.map((index) => centers[index]!);
    await page.mouse.move(from!.x, from!.y, { steps: 8 });
    await expect(
      page
        .getByRole("tooltip")
        .filter({ hasText: down[0] === 0 ? "Every day at 9:00 AM" : "new comments" })
    ).toBeVisible();
    await page.mouse.move(to!.x, to!.y, { steps: 12 });
    await expect(
      page
        .getByRole("tooltip")
        .filter({ hasText: down[1] === 0 ? "Every day at 9:00 AM" : "new comments" })
    ).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(loopRow).toHaveAccessibleName(
      `${chatSmokeTaskConversation.title}, Scheduled`
    );
    await expect(
      rows.filter({ hasText: oneOff.title }).getByTestId("inbox-item-schedule")
    ).toHaveCount(0);
    await page.getByTestId("inbox-filter-trigger").click();
    await page.getByRole("menuitem", { name: "Loops", exact: true }).click();
    const inboxPanel = page.getByTestId("inbox-schedule-filter");
    const [inboxLoopWords, inboxOneOffWords] = await wordStarts(inboxPanel, [
      "Scheduled",
      "No loop",
    ]);
    expect(inboxOneOffWords).toBe(inboxLoopWords);
  } finally {
    await stub.close();
  }
});

/** The browser grants durable permission once; only server results settle application. */
test("new Task labels share server approval permissions with Settings and can retry adding", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  const labels = ["Backend", "Release", "Design", "QA"].map((name) => ({
    name,
    color: "blue",
    description: `Add when the Task concerns ${name.toLowerCase()}.`,
  }));
  let policy = "ask";
  let status = "pending";
  let applicationStatus = "pending";
  const decisions: unknown[] = [];
  const policies: unknown[] = [];
  const catalog = () => ({
    approval_policy: policy,
    colors: [],
    labels: LABELS,
    proposals: [
      {
        id: "prp_task_labels",
        created_at: 1,
        op: "create",
        source_conversation_id: chatSmokeWorkspaceChat.id,
        status,
        application_status: applicationStatus,
        ...(status === "approved" && applicationStatus === "pending"
          ? { application_error: "The Task could not be updated. Retry adding." }
          : {}),
        payload: {
          conversation_id: chatSmokeTaskConversation.id,
          conversation_title: chatSmokeTaskConversation.title,
          labels,
        },
      },
    ],
  });
  try {
    await page.route(/\/task-labels(\/.*)?(\?|$)/, async (route) => {
      const request = route.request();
      const headers = {
        "access-control-allow-credentials": "true",
        "access-control-allow-headers": "*",
        "access-control-allow-methods": "GET,PATCH,POST,OPTIONS",
        "access-control-allow-origin": request.headers()["origin"] ?? "*",
        vary: "origin",
      };
      if (request.method() === "OPTIONS") {
        await route.fulfill({ headers, status: 204 });
        return;
      }
      if (request.method() === "POST") {
        expect(request.url()).toContain("/proposals/prp_task_labels/resolve");
        const body = request.postDataJSON();
        decisions.push(body);
        if (body.auto_approve) policy = "auto";
        // The first server response commits approval but reports a retryable binding failure.
        applicationStatus = status === "approved" ? "applied" : "pending";
        status = "approved";
      } else if (request.method() === "PATCH") {
        expect(request.url()).toContain("/task-labels/policy");
        const body = request.postDataJSON();
        policies.push(body);
        policy = body.approval_policy;
      }
      await route.fulfill({
        body: JSON.stringify(catalog()),
        headers: { ...headers, "content-type": "application/json" },
        status: 200,
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-approval@comma.local",
      token: "comma_sess_tasks_approval",
    });
    await page.addInitScript(() =>
      localStorage.setItem("comma.labelProposalPolicy", "auto")
    );
    const chatUrl = `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}`;
    await page.goto("/");
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await expect(page.getByTestId("chat-label-proposals-create")).toBeVisible();
    await page.goto(chatUrl);
    const chat = page.getByTestId("inbox-detail-pane");
    const pending = chat.getByTestId("chat-label-proposals-create");
    await expect(pending).toBeVisible();
    await expect(pending).toContainText(chatSmokeTaskConversation.title);
    await expect(
      pending.getByRole("checkbox", { name: "Auto approve" })
    ).not.toBeChecked();
    // The card carries no rule text of its own.
    await expect(pending.getByText("Label rules", { exact: false })).toHaveCount(0);
    for (const label of labels)
      await expect(pending.getByText(label.description, { exact: false })).toHaveCount(
        0
      );
    await pending.getByRole("button", { name: "+1 labels", exact: true }).hover();
    await expect(page.getByRole("tooltip")).toContainText("QA");
    expect(decisions).toEqual([]);
    await pending.getByText("Auto approve", { exact: true }).click();
    const approved = chat.getByTestId("chat-label-proposals-create-approved");
    await expect(approved).toContainText("Approved · Waiting to add to Task");
    await expect(approved).not.toContainText("Created and added");
    expect(decisions).toEqual([{ decision: "approve", auto_approve: true }]);
    expect(policies).toEqual([]);
    await expect(approved.getByRole("button", { name: "Retry adding" })).toBeVisible();
    await page.goto("/#/settings?category=labels");
    const request = page.getByTestId("label-proposal-prp_task_labels");
    await expect(request).toContainText("Approved · Waiting to add to Task");
    await expect(
      request.getByRole("button", { name: `Task: ${chatSmokeTaskConversation.title}` })
    ).toBeVisible();
    for (const label of labels) await expect(request).toContainText(label.description);
    await request.getByRole("button", { name: "Retry adding" }).click();
    await expect(request).not.toBeVisible();
    await page.goto(chatUrl);
    await expect(approved).toContainText("Created and added");
    expect(decisions).toEqual([
      { decision: "approve", auto_approve: true },
      { decision: "approve" },
    ]);
    await page.reload();
    await expect(approved).toContainText("Created and added");
    await expect(
      approved.getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    expect(decisions).toHaveLength(2);

    await page.goto("/#/settings?category=general");
    const permission = page.locator('[data-setting-id="permissions.label-changes"]');
    const dropdown = permission.getByRole("button");
    await expect(dropdown).toHaveText("Auto approve");
    // The Settings entrance transform changes the menu's positioning container.
    await expect(
      page.locator('[data-entering] > [data-slot="settings-dialog"]')
    ).toHaveCount(0);
    await dropdown.click();
    await page.getByRole("option", { name: "Always ask", exact: true }).click();
    await expect(dropdown).toHaveText("Always ask");
    expect(policies).toEqual([{ approval_policy: "ask" }]);
    await page.goto(chatUrl);
    await expect(
      approved.getByRole("checkbox", { name: "Auto approve" })
    ).not.toBeChecked();
    expect(decisions).toHaveLength(2);
  } finally {
    await stub.close();
  }
});

test("Ask Comma appends selected Tasks to the unsent Home draft without sending", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  const sentMessages: string[] = [];
  page.on("request", (request) => {
    if (request.method() === "POST" && /\/messages(?:\?|$)/u.test(request.url())) {
      sentMessages.push(request.url());
    }
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-draft@comma.local",
      token: "comma_sess_tasks_draft",
    });
    await page.goto("/#/");
    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("Please compare these before making changes.");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    const card = page
      .getByTestId("tasks-route")
      .locator('[data-slot="task-card"]')
      .first();
    await expect(card).toBeVisible();
    await card.click({ modifiers: ["Shift"] });
    await page.getByTestId("tasks-ask-comma").click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(prompt).toContainText("Please compare these before making changes.");
    await expect(prompt).toContainText(chatSmokeTaskConversation.title);
    expect(sentMessages).toEqual([]);
    // Rich-editor boundary spaces are empty spacer elements, not DOM text.
    // Read their semantic spaces just as the editor's serializer does.
    await expect
      .poll(() =>
        prompt.evaluate((editor) =>
          Array.from(editor.childNodes)
            .map((node) =>
              node instanceof HTMLElement &&
              node.hasAttribute("data-ai-input-token-spacer")
                ? " "
                : (node.textContent ?? "")
            )
            .join("")
        )
      )
      .toBe(
        `Please compare these before making changes. ${chatSmokeTaskConversation.title} `
      );
  } finally {
    await stub.close();
  }
});

function turnKeyOf(node: Locator) {
  return node.evaluate(
    (element) =>
      element.closest("[data-chat-turn-anchor]")?.getAttribute("data-turn-key") ?? null
  );
}

function newestTurnKeyOf(thread: Locator) {
  return thread
    .locator('[data-chat-latest-turn="true"]')
    .evaluate((element) => element.getAttribute("data-turn-key"));
}

/**
 * Each card belongs to the reply that filed it.
 *
 * The stub files the first round from its first reply and then serves two turns
 * that arrived later; a second round files from one of those turns. A settled
 * card must keep its own reply's place through both, while the transcript keeps
 * following the newest turn.
 */
test("holds each label proposal card at the reply that filed it as the chat continues", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ laterChatTurns: 2 });
  let firstRoundStatus = "pending";
  let secondRoundFiled = false;
  const proposalPayload = {
    conversation_id: chatSmokeTaskConversation.id,
    conversation_title: chatSmokeTaskConversation.title,
    labels: LABELS.map((label) => ({ ...label })),
  };
  try {
    await page.route(/\/task-labels(\/.*)?(\?|$)/, async (route) => {
      const request = route.request();
      const headers = {
        "access-control-allow-credentials": "true",
        "access-control-allow-headers": "*",
        "access-control-allow-methods": "GET,PATCH,POST,OPTIONS",
        "access-control-allow-origin": request.headers()["origin"] ?? "*",
        vary: "origin",
      };
      if (request.method() === "OPTIONS") {
        await route.fulfill({ headers, status: 204 });
        return;
      }
      if (request.method() === "POST") {
        expect(request.url()).toContain("/proposals/prp_task_labels/resolve");
        firstRoundStatus = "approved";
      }
      await route.fulfill({
        body: JSON.stringify({
          approval_policy: "ask",
          colors: [],
          labels: LABELS,
          proposals: [
            {
              application_status: "pending",
              // The stub's first reply, msg-assistant-smoke, is dated here.
              created_at: 1_720_000_002_000,
              id: "prp_task_labels",
              op: "create",
              payload: proposalPayload,
              source_conversation_id: chatSmokeWorkspaceChat.id,
              status: firstRoundStatus,
            },
            ...(secondRoundFiled
              ? [
                  {
                    application_status: "pending",
                    // A later reply, msg-later-assistant-smoke-1.
                    created_at: 1_720_000_011_000,
                    id: "prp_task_labels_later",
                    op: "create",
                    payload: proposalPayload,
                    source_conversation_id: chatSmokeWorkspaceChat.id,
                    status: "pending",
                  },
                ]
              : []),
          ],
        }),
        headers: { ...headers, "content-type": "application/json" },
        status: 200,
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "label-anchor@comma.local",
      token: "comma_sess_label_anchor",
    });
    await page.goto("/");

    // The reply that files the first round, then two turns that arrived later.
    const thread = page.locator(".comma-home-chat .comma-chat-thread");
    const composer = page.locator(".comma-chat-composer");
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("请给这个任务加标签");
    await composer.getByRole("button", { name: "Send" }).click();
    const filingReply = thread.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(filingReply).toBeVisible();
    await expect(
      thread.locator('[data-message-id="msg-later-assistant-smoke-2"]')
    ).toBeVisible();

    // The card holds the filing reply's turn, not the newest turn.
    const card = page.getByTestId("chat-label-proposals-create");
    await expect(card).toBeVisible();
    const filedAt = await turnKeyOf(filingReply);
    expect(filedAt).not.toBeNull();
    await expect.poll(() => turnKeyOf(card)).toBe(filedAt);
    const turnTailKey = await newestTurnKeyOf(thread);
    expect(filedAt).not.toBe(turnTailKey);

    // Settling the card does not move it.
    await card.getByRole("button", { name: "Approve", exact: true }).click();
    const settled = page.getByTestId("chat-label-proposals-create-approved");
    await expect(settled).toContainText("Approved · Waiting to add to Task");
    expect(await turnKeyOf(settled)).toBe(filedAt);

    // A second round files from a later reply. The new card lands there, the
    // settled card keeps its place, and a new message still reaches the bottom.
    secondRoundFiled = true;
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("继续聊");
    await composer.getByRole("button", { name: "Send" }).click();
    await expect(
      thread.locator('[data-message-id="msg-assistant-followup-window-smoke"]')
    ).toBeVisible();

    const laterReply = thread.locator(
      '[data-message-id="msg-later-assistant-smoke-1"]'
    );
    const laterRound = page.getByTestId("chat-label-proposals-create");
    await expect(laterRound).toBeVisible();
    const laterFiledAt = await turnKeyOf(laterReply);
    expect(laterFiledAt).not.toBeNull();
    expect(laterFiledAt).not.toBe(filedAt);
    await expect.poll(() => turnKeyOf(laterRound)).toBe(laterFiledAt);
    expect(laterFiledAt).not.toBe(await newestTurnKeyOf(thread));
    // The first round's settled card stayed with its own reply.
    expect(
      await turnKeyOf(page.getByTestId("chat-label-proposals-create-approved"))
    ).toBe(filedAt);
  } finally {
    await stub.close();
  }
});

// Rendering boundary: a rule per task must not mount the entire picker. The
// jsdom TasksRoute test proves how the picker searches and filters.
test("trigger rule picker virtualizes a large rule catalog", async ({ page }) => {
  const rules = Array.from({ length: 1_000 }, (_, index) => ({
    id: `cnv_rule_${index}`,
    kind: "agent_task",
    status: "active",
    title: `Watch PR ${index}`,
    group_id: chatSmokeWorkspace.group_id,
    updated_at: chatSmokeTaskConversation.updated_at,
    loop: {
      state: "active",
      started_at: 1,
      wake_count: 0,
      cadence: { events: `PR #${String(index).padStart(4, "0")} updated` },
    },
  }));
  const stub = await startChatSmokeStub({
    additionalInboxConversations: rules,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "rule-filter@comma.local",
      token: "comma_sess_rule_filter",
    });
    await page.goto("/#/tasks");
    await page.getByRole("button", { name: "Filter tasks" }).click();
    await page.getByRole("menuitem", { name: "Trigger rule", exact: true }).click();
    const panel = page.getByRole("dialog", { name: "Trigger rule" });
    await expect(panel.getByRole("menuitemradio").first()).toBeVisible();
    expect(await panel.getByRole("menuitemradio").count()).toBeLessThan(50);
    // End scrolls the list to the last rule and mounts only the rows near it.
    await panel.getByRole("menuitemradio").first().focus();
    await page.keyboard.press("End");
    await expect(
      panel.getByRole("menuitemradio", { name: /PR #0999 updated/ })
    ).toBeFocused();
    expect(await panel.getByRole("menuitemradio").count()).toBeLessThan(50);
  } finally {
    await stub.close();
  }
});
