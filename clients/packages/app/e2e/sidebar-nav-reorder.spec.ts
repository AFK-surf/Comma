import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The icon rail reorders by pointer drag, the way routine cards do. The
// order is a client setting, so it survives a reload; a press that never
// travels stays the link's click, and a drag never navigates.

const installSession = (page: Page) =>
  installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "sidebar-reorder@comma.local",
    token: "comma_sess_sidebar_reorder",
  });

const rows = (page: Page) => page.getByTestId("comma-sidebar-nav-row");

test("Home shows a blue dot for a Router reply received on another page until it is opened", async ({
  page,
}) => {
  const reply = "The Router reply is ready to read.";
  const stub = await startChatSmokeStub({
    assistantReply: reply,
    streamAssistantReply: true,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-badge@comma.local",
      token: "comma_sess_home_badge",
    });
    await page.goto("/");
    const home = page.getByRole("link", { name: "Home", exact: true });
    const badge = home.locator('[data-slot="left-rail-item-badge"]');
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Tell me when you finish");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    await expect(content.getByTestId("chat-assistant-draft")).toBeVisible();
    await expect(badge).toHaveCount(0);
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await expect(page).toHaveURL(/#\/inbox$/);
    await expect(badge).toHaveCount(0);
    stub.completeStreamingReply();
    await expect(badge).toBeVisible();
    await expect(badge).toHaveCSS("background-color", "rgb(32, 91, 255)");
    await home.click();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(reply);
    await expect(badge).toHaveCount(0);
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await expect(badge).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

const railOrder = (page: Page) =>
  rows(page).evaluateAll((elements) =>
    elements.map((element) => (element as HTMLElement).dataset["navId"])
  );

const storedOrder = (page: Page) =>
  page.evaluate(() => {
    const stored = localStorage.getItem("comma.client-settings");
    return stored
      ? (JSON.parse(stored) as { sidebarNavOrder?: string[] }).sidebarNavOrder
      : null;
  });

async function dragRow(
  page: Page,
  fromId: string,
  toId: string,
  edge: "above" | "below"
) {
  const source = await page.locator(`[data-nav-id="${fromId}"]`).boundingBox();
  const target = await page.locator(`[data-nav-id="${toId}"]`).boundingBox();
  if (!source || !target) throw new Error("rail rows are not laid out");
  const startX = source.x + source.width / 2;
  const startY = source.y + source.height / 2;
  const endY = edge === "above" ? target.y + 2 : target.y + target.height - 2;
  await page.mouse.move(startX, startY);
  await page.mouse.down();
  for (let step = 1; step <= 8; step += 1) {
    await page.mouse.move(startX, startY + ((endY - startY) * step) / 8);
  }
  return { release: () => page.mouse.up() };
}

test("a dragged rail item settles where it was dropped, without navigating, and the order persists", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  expect(await railOrder(page)).toEqual(["home", "inbox", "tasks", "drive", "plugins"]);

  const drag = await dragRow(page, "tasks", "home", "above");
  // Mid-drag the lifted row carries the pointer and the rows it passed step aside.
  await expect(page.locator('[data-nav-id="tasks"]')).toHaveAttribute(
    "data-pointer-dragging",
    "true"
  );
  await expect(page.locator('[data-nav-id="home"]')).toHaveAttribute(
    "data-sidebar-drag-shift",
    "down"
  );
  await drag.release();

  await expect
    .poll(() => railOrder(page))
    .toEqual(["tasks", "home", "inbox", "drive", "plugins"]);
  expect(new URL(page.url()).hash).toMatch(/^(#\/)?$/);
  await expect(page.locator('[data-nav-id="tasks"]')).not.toHaveAttribute(
    "data-pointer-dragging",
    "true"
  );
  await expect
    .poll(() => storedOrder(page))
    .toEqual(["tasks", "home", "inbox", "drive", "plugins"]);

  await page.reload();
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  expect(await railOrder(page)).toEqual(["tasks", "home", "inbox", "drive", "plugins"]);

  // A plain press is still the link's own click.
  await page.getByRole("link", { name: "Tasks" }).click();
  await expect(page).toHaveURL(/#\/tasks$/);
});

test("Escape cancels navigation until the held pointer is released over its link", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  const tasks = page.getByRole("link", { name: "Tasks" });
  const source = await tasks.boundingBox();
  if (!source) throw new Error("Tasks link is not laid out");
  const drag = await dragRow(page, "tasks", "home", "above");
  await expect(page.locator('[data-nav-id="tasks"]')).toHaveAttribute(
    "data-pointer-dragging",
    "true"
  );
  await page.keyboard.press("Escape");
  // Keep the button held past the cancel task and the return animation. The
  // old zero-delay suppression expires before this gesture actually ends.
  await page.locator('[data-nav-id="tasks"]').evaluate(async (row) => {
    await Promise.all(row.getAnimations().map((animation) => animation.finished));
    await new Promise((resolve) => setTimeout(resolve, 50));
  });
  await page.mouse.move(source.x + source.width / 2, source.y + source.height / 2);
  await drag.release();

  expect(await railOrder(page)).toEqual(["home", "inbox", "tasks", "drive", "plugins"]);
  expect(await storedOrder(page)).toEqual([]);
  await expect(page).toHaveURL(/(?:\/#\/?|\/)$/);

  // Suppression belongs to the cancelled gesture, not the next plain click.
  await tasks.click();
  await expect(page).toHaveURL(/#\/tasks$/);
});

test("a cancelled drag released outside the rail leaves keyboard navigation usable", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  const drag = await dragRow(page, "tasks", "home", "above");
  await expect(page.locator('[data-nav-id="tasks"]')).toHaveAttribute(
    "data-pointer-dragging",
    "true"
  );
  await page.keyboard.press("Escape");
  await page.mouse.move(600, 400);
  // Keyboard activation must work before the pointer cleanup timer runs.
  await page.clock.install();
  await page.clock.pauseAt(new Date(Date.now() + 1000));
  await drag.release();
  expect(await railOrder(page)).toEqual(["home", "inbox", "tasks", "drive", "plugins"]);
  expect(await storedOrder(page)).toEqual([]);
  await expect(page).toHaveURL(/(?:\/#\/?|\/)$/);

  await page.getByRole("link", { name: "Tasks" }).focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/#\/tasks$/);
});
