import { expect, test } from "@playwright/test";

const STORY =
  "/iframe.html?id=base-components-scrollarea--hidden-input-rows&viewMode=story";

/**
 * react-aria renders a `Radio`'s real `<input>` in a visually hidden box that
 * is absolutely positioned without an offset. Its containing block is the
 * area's content layer, so the input scrolls with its row. Were the root the
 * containing block instead, the input would stay where the row started;
 * clicking the row would focus it, and the browser would scroll the root's
 * overflow-hidden box to reveal it, clipping the rows on screen.
 */
test("a visually hidden input scrolls with its row and a click leaves the root unscrolled", async ({
  page,
}) => {
  await page.goto(STORY);
  const root = page.locator('[data-slot="scroll-area"]').first();
  const viewport = root.locator('[data-slot="scroll-area-viewport"]');
  const lastRow = page.getByTestId("scroll-area-radio-row-24");
  await expect(lastRow).toBeAttached();

  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  expect(await viewport.evaluate((element) => element.scrollTop)).toBeGreaterThan(0);

  const rowBox = await lastRow.boundingBox();
  const inputBox = await lastRow.locator('input[type="radio"]').boundingBox();
  expect(rowBox && inputBox).toBeTruthy();
  expect(inputBox!.y).toBeGreaterThanOrEqual(rowBox!.y - 2);
  expect(inputBox!.y).toBeLessThanOrEqual(rowBox!.y + rowBox!.height + 2);

  await lastRow.click();
  await expect(lastRow).toHaveAttribute("data-selected", "true");
  expect(await root.evaluate((element) => element.scrollTop)).toBe(0);
});
