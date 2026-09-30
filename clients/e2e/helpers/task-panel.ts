import { expect, type Locator, type Page } from "@playwright/test";

/**
 * The Task route's details panel: a second column while the route is wide,
 * the header toggle's popover once it folds below the breakpoint. Opens the
 * popover when the route is folded and returns whichever surface is showing,
 * so a test reads status and presses Done the same way at any width.
 */
export async function openTaskDetails(page: Page): Promise<Locator> {
  const column = page.locator('[data-testid="task-details-panel"][data-open="true"]');
  const folded = page.locator('[data-testid="task-details-panel"][data-open="false"]');
  await expect(column.or(folded).first()).toBeAttached();
  if ((await column.count()) > 0) return column;
  const popover = page.getByTestId("task-panel-popover");
  if ((await popover.count()) === 0)
    await page.getByTestId("task-panel-toggle").click();
  await expect(popover).toBeVisible();
  return popover;
}

/** The panel's Done control, present only while the Task awaits review. */
export function taskDoneButton(details: Locator): Locator {
  return details
    .locator(".comma-task-panel-done")
    .getByRole("button", { name: /^(Done|完成)$/ });
}
