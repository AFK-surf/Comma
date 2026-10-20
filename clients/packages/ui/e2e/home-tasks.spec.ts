import { expect, test } from "@playwright/test";

test("status indicator switches the home task cards", async ({ page }) => {
  await page.goto("/iframe.html?id=app-components-home-tasks--default&viewMode=story");

  const stack = page.getByTestId("home-tasks-card-stack");
  await expect(stack.getByTestId("home-task-card")).toHaveCount(2);
  await expect(stack.getByTestId("home-task-card").first()).toContainText(
    "Summarizing recent OpenAI's update and create a HTML"
  );

  // Playwright pierces the status-indicator shadow DOM; segment 1 = Needs Review.
  await page.locator('status-indicator [role="radio"]').nth(1).click();

  await expect(
    page.locator('[data-role="current"]').getByTestId("home-task-card").first()
  ).toContainText("Start on refraction UI library");
  // The outgoing page ghosts away after the slide.
  await expect(page.locator('[data-role="outgoing"]')).toHaveCount(0);
  await expect(page.getByTestId("home-task-card")).toHaveCount(2);

  // Return to In progress, then reproduce an automatic controlled switch while
  // a task card — rather than the indicator — owns keyboard focus.
  await page.locator('status-indicator [role="radio"]').nth(0).click();
  await expect(
    page.locator('[data-role="current"]').getByTestId("home-task-card").first()
  ).toContainText("Summarizing recent OpenAI's update and create a HTML");
  await expect(page.locator('[data-role="outgoing"]')).toHaveCount(0);

  const focusedCard = page
    .locator('[data-role="current"]')
    .getByTestId("home-task-card")
    .first();
  await focusedCard.evaluate((card) => {
    card.addEventListener(
      "click",
      () => {
        document.body.dataset.outgoingTaskActivated = "true";
      },
      { once: true }
    );
  });
  await focusedCard.focus();
  await expect(focusedCard).toBeFocused();

  await page.locator("status-indicator").evaluate((indicator) => {
    const element = indicator as HTMLElement & { value: string };
    element.value = "needs-review";
    element.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { index: 1, label: "Needs Review", value: "needs-review" },
      })
    );
  });

  const outgoing = page.locator('[data-role="outgoing"]');
  await expect(outgoing).toHaveAttribute("aria-hidden", "true");
  await expect(outgoing).toHaveAttribute("inert", "");
  await expect(outgoing.locator('[data-slot="scroll-area-viewport"]')).toHaveAttribute(
    "tabindex",
    "-1"
  );
  await expect(page.getByRole("heading", { name: "Tasks" })).toBeFocused();
  await expect(
    page.locator('[data-role="current"]').getByTestId("home-task-card").first()
  ).toContainText("Start on refraction UI library");
  expect(
    await page.evaluate(() => {
      const active = document.activeElement;
      return (
        active !== document.body && active?.closest('[aria-hidden="true"]') === null
      );
    })
  ).toBe(true);
  await page.keyboard.press("Enter");
  await expect(page.getByRole("heading", { name: "Tasks" })).toBeFocused();
  await expect(page.locator("body")).not.toHaveAttribute(
    "data-outgoing-task-activated",
    "true"
  );
  await expect(page.locator('[data-role="outgoing"]')).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Tasks" })).toBeFocused();
});

test("home rail cards reorder by drag with the same well and settle", async ({
  page,
}) => {
  await page.goto("/iframe.html?id=app-components-home-tasks--default&viewMode=story");

  const stack = page.getByTestId("home-tasks-card-stack");
  const cards = stack.getByTestId("home-task-card");
  await expect(cards).toHaveCount(2);
  await expect(cards.first()).toContainText(
    "Summarizing recent OpenAI's update and create a HTML"
  );

  const first = await cards.nth(0).boundingBox();
  const second = await cards.nth(1).boundingBox();
  if (!first || !second) throw new Error("cards are not laid out");

  // Drag the first card past the second card's middle.
  await page.mouse.move(first.x + 60, first.y + 20);
  await page.mouse.down();
  await page.mouse.move(first.x + 60, second.y + second.height / 2 + 24, {
    steps: 10,
  });

  // Same gesture grammar as the board: the origin paints itself as the well
  // and the neighbour slides over it.
  const slots = stack.locator('[data-slot="task-card-reorder-item"]');
  await expect(slots.nth(0)).toHaveAttribute("data-dragging", "true");
  await expect(slots.nth(0)).toHaveClass(/bg-quaternary/);
  expect(
    await slots
      .nth(1)
      .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).not.toBe("none");

  await page.mouse.up();
  await expect(cards.first()).toContainText("Implement UI library to Comma repo");
  await expect(cards.nth(1)).toContainText(
    "Summarizing recent OpenAI's update and create a HTML"
  );
});
