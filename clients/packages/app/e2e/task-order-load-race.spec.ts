import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const groupId = chatSmokeWorkspace.group_id;
const orderPath = `/v1/comma/groups/${groupId}/task-order`;
const tasks = [
  {
    created_at: 1_720_000_001,
    group_id: groupId,
    id: "cnv_task_order_first",
    kind: "agent_task",
    status: "queued",
    title: "First ordered task",
    updated_at: 1_720_000_002,
  },
  {
    created_at: 1_720_000_003,
    group_id: groupId,
    id: "cnv_task_order_second",
    kind: "agent_task",
    status: "queued",
    title: "Second ordered task",
    updated_at: 1_720_000_004,
  },
] as const;

const backlogColumn = (page: Page) =>
  page
    .locator('[data-slot="task-board-column"]')
    .filter({ has: page.getByText("Backlog", { exact: true }) });

const titles = (page: Page) =>
  backlogColumn(page).locator('[data-slot="task-card-title"]').allInnerTexts();

async function fulfillJson(route: Route, json: unknown, status = 200) {
  const origin = route.request().headers().origin;
  await route.fulfill({
    headers: {
      "access-control-allow-credentials": "true",
      ...(origin ? { "access-control-allow-origin": origin } : {}),
      "content-type": "application/json",
      vary: "origin",
    },
    body: JSON.stringify(json),
    status,
  });
}

async function dragTopCardBelowNext(page: Page) {
  const items = backlogColumn(page).locator('[data-slot="task-card-reorder-item"]');
  await expect(items).toHaveCount(2);
  const first = await items.nth(0).boundingBox();
  const second = await items.nth(1).boundingBox();
  if (!first || !second) throw new Error("Task cards are not laid out");
  await page.mouse.move(first.x + 60, first.y + 20);
  await page.mouse.down();
  await page.mouse.move(first.x + 60, second.y + second.height / 2 + 20, {
    steps: 10,
  });
  await page.mouse.up();
}

test("an older initial Task-order read cannot undo a completed drag", async ({
  page,
}) => {
  // The product inbox loads inside a SharedWorker on web, out of reach of
  // Playwright page routes — the seed tasks must come from the stub itself.
  const stub = await startChatSmokeStub({ additionalInboxConversations: tasks });
  let releaseInitialOrder!: () => void;
  let observeInitialOrder!: () => void;
  let released = false;
  const initialOrderRelease = new Promise<void>((resolve) => {
    releaseInitialOrder = () => {
      released = true;
      resolve();
    };
  });
  const initialOrderObserved = new Promise<void>((resolve) => {
    observeInitialOrder = resolve;
  });
  const writes: unknown[] = [];

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-order-race@comma.local",
      token: "comma_sess_task_order_race",
    });
    await page.addInitScript((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
    }, chatSmokeWorkspace.id);

    await page.route(
      (url) => url.pathname === orderPath,
      async (route) => {
        if (route.request().method() === "OPTIONS") {
          await route.fallback();
          return;
        }
        observeInitialOrder();
        await initialOrderRelease;
        await fulfillJson(route, {
          orders: { backlog: tasks.map((task) => task.id) },
        });
      }
    );
    await page.route(
      (url) => url.pathname === `${orderPath}/backlog`,
      async (route) => {
        if (route.request().method() === "OPTIONS") {
          await route.fallback();
          return;
        }
        writes.push(route.request().postDataJSON());
        await fulfillJson(route, {
          orders: { backlog: [tasks[1].id, tasks[0].id] },
        });
      }
    );

    await page.goto("/#/tasks");
    await initialOrderObserved;

    const items = backlogColumn(page).locator('[data-slot="task-card-reorder-item"]');
    await expect(items).toHaveCount(2);
    expect(await titles(page)).toEqual(["First ordered task", "Second ordered task"]);

    await dragTopCardBelowNext(page);

    const reordered = ["Second ordered task", "First ordered task"];
    await expect.poll(() => titles(page)).toEqual(reordered);
    await expect.poll(() => writes).toEqual([{ ids: [tasks[1].id, tasks[0].id] }]);

    const initialReply = page.waitForResponse(
      (response) =>
        new URL(response.url()).pathname === orderPath &&
        response.request().method() === "GET"
    );
    releaseInitialOrder();
    await initialReply;
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    expect(await titles(page)).toEqual(reordered);
  } finally {
    if (!released) releaseInitialOrder();
    await stub.close();
  }
});

test("rapid same-bucket drops persist in causal order across a remount", async ({
  page,
}) => {
  // The product inbox loads inside a SharedWorker on web, out of reach of
  // Playwright page routes — the seed tasks must come from the stub itself.
  const stub = await startChatSmokeStub({ additionalInboxConversations: tasks });
  const canonical = tasks.map((task) => task.id);
  const reversed = [tasks[1].id, tasks[0].id];
  let persisted: string[] = [...canonical];
  let releaseFirstWrite!: () => void;
  let firstWriteReleased = false;
  const firstWriteRelease = new Promise<void>((resolve) => {
    releaseFirstWrite = () => {
      firstWriteReleased = true;
      resolve();
    };
  });
  const writes: Array<{ ids: string[] }> = [];

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-order-write-race@comma.local",
      token: "comma_sess_task_order_write_race",
    });
    await page.addInitScript((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
    }, chatSmokeWorkspace.id);

    await page.route(
      (url) => url.pathname === orderPath,
      async (route) => {
        if (route.request().method() === "OPTIONS") {
          await route.fallback();
          return;
        }
        await fulfillJson(route, { orders: { backlog: persisted } });
      }
    );
    await page.route(
      (url) => url.pathname === `${orderPath}/backlog`,
      async (route) => {
        if (route.request().method() === "OPTIONS") {
          await route.fallback();
          return;
        }
        const body = route.request().postDataJSON() as { ids: string[] };
        writes.push(body);
        if (writes.length === 1) await firstWriteRelease;
        persisted = [...body.ids];
        await fulfillJson(route, { orders: { backlog: persisted } });
      }
    );

    await page.goto("/#/tasks");
    await expect(
      backlogColumn(page).locator('[data-slot="task-card-reorder-item"]')
    ).toHaveCount(2, { timeout: 30_000 });
    expect(await titles(page)).toEqual(["First ordered task", "Second ordered task"]);

    await dragTopCardBelowNext(page);
    await expect
      .poll(() => titles(page))
      .toEqual(["Second ordered task", "First ordered task"]);
    await expect.poll(() => writes).toEqual([{ ids: reversed }]);

    await dragTopCardBelowNext(page);
    await expect
      .poll(() => titles(page))
      .toEqual(["First ordered task", "Second ordered task"]);

    // The old write is still unresolved. A second network request here could
    // finish first and then be overwritten when the old request resumes.
    await page.waitForTimeout(200);
    expect(writes).toEqual([{ ids: reversed }]);

    releaseFirstWrite();
    await expect.poll(() => writes).toEqual([{ ids: reversed }, { ids: canonical }]);
    await expect.poll(() => persisted).toEqual(canonical);

    // Remount the full app surface and prove the durable value is the newest
    // completed drop, not whichever request happened to finish last.
    await page.reload();
    await expect
      .poll(() => titles(page))
      .toEqual(["First ordered task", "Second ordered task"]);
  } finally {
    if (!firstWriteReleased) releaseFirstWrite();
    await stub.close();
  }
});
