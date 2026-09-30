import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("archive hides a task everywhere and Settings restores its status", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "failed",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive@comma.local",
      token: "comma_sess_archive",
    });
    // The icon rail holds no task list, so the card's own menu is where a task
    // is archived from.
    await page.goto("/#/tasks");
    const card = page.locator('[data-slot="task-card"]').first();
    await expect(card).toBeVisible();
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await expect(
      page.getByText("This task is archived and read-only.", { exact: false })
    ).toHaveCount(0);
    await page.goto("/#/tasks");
    await card.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
    await expect(page.locator('[data-slot="task-card"]')).toHaveCount(0);
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await expect(
      page.getByText("This task is archived and read-only.", { exact: false })
    ).toBeVisible();
    await page.goto("/#/tasks");
    await expect(
      page.getByRole("button", { name: new RegExp(chatSmokeTaskConversation.title) })
    ).toHaveCount(0);
    await expect(
      page.getByRole("heading", { name: "Archived", exact: true })
    ).toHaveCount(0);
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await expect(
      page.getByText("This task is archived and read-only.", { exact: false })
    ).toBeVisible();
    await page.getByRole("link", { name: "Open archived tasks" }).click();
    await expect(
      page.getByRole("button", { name: "Unarchive", exact: true })
    ).toBeVisible();
    await page.getByRole("button", { name: "Unarchive", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Unarchive", exact: true })
    ).toHaveCount(0);
    await page.goto("/#/tasks");
    await expect(page.locator('[data-slot="task-card"]').first()).toBeVisible();
    const response = await page.request.get(
      `${stub.baseUrl}/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}`
    );
    expect((await response.json()).status).toBe("failed");
  } finally {
    await stub.close();
  }
});

test("running tasks hide Archive in the card menu", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "active",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-running@comma.local",
      token: "comma_sess_archive_running",
    });
    await page.goto("/#/tasks");
    const card = page.locator('[data-slot="task-card"]').first();
    await expect(card).toBeVisible();
    await card.click({ button: "right" });
    await expect(page.getByRole("menuitem", { name: /Archive task/ })).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Archive task", exact: true })
    ).toHaveCount(0);
    await expect(
      page.getByText("Finish the task before archiving", { exact: true })
    ).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("card More archives a finished task and another client hides it", async ({
  page,
  browser,
  baseURL,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "completed",
    taskSchedule: null,
  });
  const peerContext = await browser.newContext(baseURL ? { baseURL } : {});
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-cards@comma.local",
      token: "comma_sess_archive_cards",
    });
    await page.goto("/#/tasks");
    const other = await peerContext.newPage();
    await installBrowserTestSession(other, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-peer@comma.local",
      token: "comma_sess_archive_peer",
    });
    await other.goto("/#/tasks");
    await expect(other.locator('[data-slot="task-card"]')).toHaveCount(1);
    await expect.poll(() => stub.activeTaskListEventStreams).toBeGreaterThan(0);
    await page.getByRole("button", { name: "Archive task", exact: true }).click();
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
    await expect(page.locator('[data-slot="task-card"]')).toHaveCount(0);
    await expect(
      other.locator('[data-slot="task-card"]'),
      `list reads=${stub.conversationListRequestCount}, streams=${stub.activeTaskListEventStreams}`
    ).toHaveCount(0);
    await other.reload();
    await expect(other.locator('[data-slot="task-card"]')).toHaveCount(0);
  } finally {
    await peerContext.close();
    await stub.close();
  }
});

test("inline task keeps prose geometry and archives from its own context menu", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    inlineTaskReference: true,
    taskStatus: "failed",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-inline@comma.local",
      token: "comma_sess_archive_inline",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("Show the task");
    await composer.getByRole("button", { name: "Send" }).click();
    const message = content.locator('[data-message-id="msg-assistant-smoke"]');
    const chip = message.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(chip).toBeVisible();
    const originalText = await message.locator("p").textContent();
    expect(await chip.evaluate((element) => element.parentElement?.tagName)).toBe("P");
    await expect(chip).toHaveAccessibleName(
      `Open task: ${chatSmokeTaskConversation.title}`
    );
    await expect(
      message.getByRole("button", { name: "Archive task", exact: true })
    ).toHaveCount(0);
    await chip.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
    await expect(chip).toHaveAttribute("aria-disabled", "true");
    await expect(message.locator("p")).toHaveText(originalText!);
    const archivedBounds = (await chip.boundingBox())!;
    await page.mouse.click(
      archivedBounds.x + archivedBounds.width / 2,
      archivedBounds.y + archivedBounds.height / 2,
      { button: "right" }
    );
    await expect(page.getByRole("menu")).toHaveCount(0);
    const currentUrl = page.url();
    await page.mouse.click(
      archivedBounds.x + archivedBounds.width / 2,
      archivedBounds.y + archivedBounds.height / 2
    );
    await expect(page).toHaveURL(currentUrl);
    await expect(content.getByTestId("chat-sidebar")).not.toHaveAttribute(
      "data-open",
      "true"
    );
  } finally {
    await stub.close();
  }
});

test("Archived tasks pages past an empty filtered page on its own", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "archived",
    taskSchedule: null,
  });
  let archivePages = 0;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-pages@comma.local",
      token: "comma_sess_archive_pages",
    });
    await page.route("**/v1/comma/groups/*/conversations?*", async (route) => {
      const url = new URL(route.request().url());
      if (url.searchParams.get("archive") !== "only") return route.continue();
      archivePages++;
      if (!url.searchParams.has("cursor")) {
        await route.fulfill({
          json: { data: [], has_more: true, next_cursor: "scanned-page" },
        });
      } else {
        expect(url.searchParams.get("cursor")).toBe("scanned-page");
        await route.continue();
      }
    });
    await page.goto("/#/settings?category=archived-tasks");
    // The first page came back empty but not last: its end is in view, so the
    // next page loads without the list ever claiming there is nothing.
    await expect(
      page.getByRole("button", { name: "Unarchive", exact: true })
    ).toBeVisible();
    await expect(page.getByText("No archived tasks", { exact: true })).toHaveCount(0);
    expect(archivePages).toBe(2);
  } finally {
    await stub.close();
  }
});

test("the board drops an archived card without waiting for the authority", async ({
  page,
}) => {
  // The Tasks board is the surface whose cards follow the ProductInbox
  // projection, so it is where a server round trip used to hold the user's own
  // decision back. Holding the archive open for a known time makes the wait
  // measurable: until the stub accepts it nothing in the system says the Task
  // is archived, so a card that leaves early left on the decision alone.
  const archiveLatencyMs = 3_000;
  const stub = await startChatSmokeStub({
    archiveLatencyMs,
    includeTaskInInbox: true,
    taskStatus: "completed",
    taskSchedule: null,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-latency@comma.local",
      token: "comma_sess_archive_latency",
    });
    await page.goto("/#/tasks");
    const cards = page.locator('[data-slot="task-card"]');
    await expect(cards).toHaveCount(1);
    await cards.first().click({ button: "right" });

    const elapsedMs = await timeCardRemoval(
      page.getByRole("menuitem", { name: "Archive task", exact: true }),
      cards
    );

    expect(
      elapsedMs,
      `the card waited ${elapsedMs}ms for an archive the authority took ${archiveLatencyMs}ms to accept`
    ).toBeLessThan(archiveLatencyMs / 3);
    await expect(cards).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

/** Milliseconds from choosing Archive to the board no longer showing the card. */
async function timeCardRemoval(trigger: Locator, cards: Locator) {
  const startedAt = Date.now();
  await trigger.click();
  await expect
    .poll(() => cards.count(), {
      intervals: [5, 10, 15, 20, 30, 50, 100, 200, 400],
      timeout: 20_000,
    })
    .toBe(0);
  return Date.now() - startedAt;
}

test("the board gives a Task back when the authority outruns the archive", async ({
  page,
}) => {
  // The stub reverses the archive while this client is still waiting for it, so
  // the decision it took is stale by the time the authority answers. A local
  // view that only ends when the authority agrees would keep the card hidden.
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskSchedule: null,
    taskStatus: "completed",
    unarchiveAfterArchiveMs: 600,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archive-reversed@comma.local",
      token: "comma_sess_archive_reversed",
    });
    await page.goto("/#/tasks");
    const cards = page.locator('[data-slot="task-card"]');
    await expect(cards).toHaveCount(1);
    await cards.first().click({ button: "right" });
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();

    // The decision takes the card away at once, and the authority's later word
    // brings it back instead of leaving it hidden behind an archive that no
    // longer exists.
    await expect(cards).toHaveCount(0);
    await expect(cards).toHaveCount(1, { timeout: 15_000 });
  } finally {
    await stub.close();
  }
});
