import { expect, type Locator } from "@playwright/test";

/**
 * Opens a Dropdown and chooses one of its options from the keyboard.
 *
 * The list opens with its chosen row over the trigger and corrects its scroll
 * in the frames after it appears. A pointer aimed at a row while that happens
 * can land on the neighbouring row, so the option is focused and chosen with
 * Enter, whatever the list's position. The option is focused directly: an
 * open list does not always take focus itself (Firefox, after an earlier
 * choice from the same Dropdown).
 */
export async function chooseDropdownOption(
  trigger: Locator,
  name: string | RegExp
): Promise<void> {
  const page = trigger.page();
  await trigger.focus();
  await page.keyboard.press("Enter");
  const listbox = page.getByRole("listbox");
  await expect(listbox).toBeVisible();
  const option = listbox.getByRole("option", {
    name,
    exact: typeof name === "string",
  });
  await option.focus();
  await expect(option).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(listbox).toBeHidden();
}
