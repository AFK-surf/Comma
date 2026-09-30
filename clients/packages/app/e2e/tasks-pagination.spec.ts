import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const task = (id: string, status: string) => ({
  ...chatSmokeTaskConversation,
  id,
  title: id,
  status,
  schedule: null,
  messages: [],
});

test("the board loads one shared page when a resize makes every column fit", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 400 });
  const firstPage = ["active", "completed"].flatMap((status) =>
    Array.from({ length: 9 }, (_, index) => task(`${status}-${index}`, status))
  );
  const nextPage = [task("Older task", "active")];
  const cursors: string[] = [];
  const stub = await startChatSmokeStub({
    conversationList: (url) => {
      const cursor = url.searchParams.get("cursor");
      if (cursor) cursors.push(cursor);
      return {
        body: {
          data: cursor ? nextPage : firstPage,
          has_more: !cursor,
          next_cursor: cursor ? null : "older-tasks",
        },
      };
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-pagination@comma.local",
      token: "comma_sess_tasks_pagination",
    });
    await page.goto("/#/tasks");
    const cards = page.locator('[data-slot="task-card"]');
    const columns = page.locator(
      '[data-slot="task-board-column"] [data-slot="scroll-area-viewport"]'
    );
    await expect(cards).toHaveCount(18);
    await expect(columns).toHaveCount(2);
    await expect
      .poll(() =>
        columns.evaluateAll((nodes) =>
          nodes.every((node) => node.scrollHeight > node.clientHeight)
        )
      )
      .toBe(true);
    expect(cursors).toEqual([]);

    // Neither column can scroll after this resize. Their sentinels must not
    // strand the next page or each request a copy of the shared page.
    await page.setViewportSize({ width: 1280, height: 1200 });
    await expect(cards.filter({ hasText: "Older task" })).toBeVisible();
    await expect(cards).toHaveCount(19);
    expect(cursors).toEqual(["older-tasks"]);
  } finally {
    await stub.close();
  }
});

test("automatic task pagination keeps the first page during startup refreshes", async ({
  page,
}) => {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  const stub = await startChatSmokeStub({
    conversationList: (url) => ({
      body: {
        data: [
          url.searchParams.has("cursor")
            ? task("Older task", "completed")
            : task("First task", "active"),
        ],
        has_more: !url.searchParams.has("cursor"),
        next_cursor: url.searchParams.has("cursor") ? null : "older-tasks",
      },
    }),
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-startup-pagination@comma.local",
      token: "comma_sess_tasks_startup_pagination",
    });
    await page.goto("/#/tasks");
    const cards = page.locator('[data-slot="task-card"]');
    await expect(cards.filter({ hasText: "Older task" })).toBeVisible();
    await expect(cards.filter({ hasText: "First task" })).toBeVisible();
    await expect(cards).toHaveCount(2);
    await expect(page.getByTestId("tasks-sync-error")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});
