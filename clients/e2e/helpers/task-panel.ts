import { expect, type Locator, type Page } from "@playwright/test";

/**
 * The Task route's details panel: a second column while the route is wide,
 * the header toggle's popover once it folds below the breakpoint. Opens the
 * popover when the route is folded and returns whichever surface is showing,
 * so a test reads and changes the status the same way at any width.
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

/** The details' status pill; it opens the status menu. */
export function taskStatusPill(details: Locator): Locator {
  return details.getByTestId("task-conversation-status");
}

/** Opens the status menu and picks a manual end status. */
export async function chooseTaskStatus(
  details: Locator,
  status: "Done" | "Cancelled"
): Promise<void> {
  await taskStatusPill(details).click();
  const name = status === "Done" ? /^(Done|完成)$/ : /^(Cancelled|已取消)$/;
  await details.page().getByRole("menuitem", { name }).click();
}

/**
 * Checks whether the status pill offers the manual Done choice, which needs
 * the loaded Task detail. Without a choice the pill stays read-only.
 */
export async function expectManualDoneChoice(
  details: Locator,
  offered: boolean
): Promise<void> {
  const pill = taskStatusPill(details);
  if (!offered) {
    await expect(pill).toBeDisabled();
    return;
  }
  await expect(pill).toBeEnabled();
  await pill.click();
  const page = details.page();
  await expect(page.getByRole("menuitem", { name: /^(Done|完成)$/ })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
}
