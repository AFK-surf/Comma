import { expect, test } from "@playwright/test";
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

test("inline task keeps prose geometry and archives from its own context menu", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    inlineTaskReference: true,
    taskStatus: "failed",
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
    const chipTestId = `chat-inline-task-${chatSmokeTaskConversation.id}`;
    const chip = message.getByTestId(chipTestId);
    await expect(chip).toBeVisible();
    // The message also shows the Task's card below its prose; the chip and its
    // archive menu belong to the prose paragraph.
    // `has` queries inside each <p>, so it takes a locator rooted at the page.
    const prose = message.locator("p", { has: page.getByTestId(chipTestId) });
    const originalText = await prose.textContent();
    expect(await chip.evaluate((element) => element.parentElement?.tagName)).toBe("P");
    await expect(chip).toHaveAccessibleName(
      `Open task: ${chatSmokeTaskConversation.title}`
    );
    await expect(
      prose.getByRole("button", { name: "Archive task", exact: true })
    ).toHaveCount(0);
    await chip.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Archive task", exact: true }).click();
    await expect(chip).toHaveAttribute("aria-disabled", "true");
    await expect(prose).toHaveText(originalText!);
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
