import { expect, test, type Page } from "@playwright/test";

const STORY =
  "/iframe.html?id=app-components-tasks-task-workspace--persisted-order&viewMode=story";

const reviewColumn = (page: Page) =>
  page
    .locator('[data-slot="task-board-column"]')
    .filter({ has: page.getByText("Needs Review", { exact: true }) });

const titles = async (page: Page) =>
  reviewColumn(page).locator('[data-slot="task-card-title"]').allInnerTexts();

test("a dragged order is reported out and survives a workspace remount", async ({
  page,
}) => {
  await page.goto(STORY);

  const items = reviewColumn(page).locator('[data-slot="task-card-reorder-item"]');
  await expect(items).toHaveCount(2);
  expect(await titles(page)).toEqual([
    "Summarize the latest product feedback into themes",
    "Collect design tokens for the marketing refresh",
  ]);

  // Drag the first Needs Review card past the second card's middle.
  const first = await items.nth(0).boundingBox();
  const second = await items.nth(1).boundingBox();
  if (!first || !second) throw new Error("cards are not laid out");
  await page.mouse.move(first.x + 60, first.y + 20);
  await page.mouse.down();
  await page.mouse.move(first.x + 60, second.y + second.height / 2 + 20, {
    steps: 10,
  });
  await page.mouse.up();

  const reordered = [
    "Collect design tokens for the marketing refresh",
    "Summarize the latest product feedback into themes",
  ];
  await expect.poll(() => titles(page)).toEqual(reordered);

  // Remount the workspace — the app-level reload. The order came back through
  // the taskOrder prop, not from any state inside the workspace instance.
  await page.getByTestId("persisted-order-reload").click();
  await expect(items).toHaveCount(2);
  await expect.poll(() => titles(page)).toEqual(reordered);
});
