import { expect, test } from "@playwright/test";

test("status indicator switches the home task cards", async ({ page }) => {
  await page.goto("/iframe.html?id=app-components-home-tasks--default&viewMode=story");

  const stack = page.getByTestId("home-tasks-card-stack");
  await expect(stack.getByTestId("home-task-card")).toHaveCount(2);
  await expect(stack.getByTestId("home-task-card").first()).toContainText(
    "Start on refraction UI library"
  );

  // Playwright pierces the status-indicator shadow DOM; segment 1 = In progress.
  await page.locator('status-indicator [role="radio"]').nth(1).click();

  await expect(
    page.locator('[data-role="current"]').getByTestId("home-task-card").first()
  ).toContainText("Summarizing recent OpenAI's update and create a HTML");
  // The outgoing page ghosts away after the slide.
  await expect(page.locator('[data-role="outgoing"]')).toHaveCount(0);
  await expect(page.getByTestId("home-task-card")).toHaveCount(2);

  // Return to Backlog, then reproduce an automatic controlled switch while a
  // task card — rather than the indicator — owns keyboard focus.
  await page.locator('status-indicator [role="radio"]').nth(0).click();
  await expect(
    page.locator('[data-role="current"]').getByTestId("home-task-card").first()
  ).toContainText("Start on refraction UI library");
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
    element.value = "in-progress";
    element.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { index: 1, label: "In progress", value: "in-progress" },
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
  ).toContainText("Summarizing recent OpenAI's update and create a HTML");
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

test("new tasks pop in and cascade when arriving together", async ({ page }) => {
  await page.goto(
    "/iframe.html?id=app-components-home-tasks--new-card-arrival&viewMode=story"
  );

  // The story's play function adds a batch of three; wait until it settled.
  await expect(page.getByTestId("home-task-card")).toHaveCount(5);
  await expect(page.locator('[data-state="new"]')).toHaveCount(0);

  await page.getByRole("button", { name: "+3 tasks" }).click();

  const fresh = page.locator('[data-state="new"]');
  await expect(fresh).toHaveCount(3);
  await expect(fresh.nth(0)).toHaveCSS("--comma-home-tasks-new-index", "0");
  await expect(fresh.nth(1)).toHaveCSS("--comma-home-tasks-new-index", "1");
  await expect(fresh.nth(2)).toHaveCSS("--comma-home-tasks-new-index", "2");

  // The batch settles back into the regular flow once the cascade finishes.
  await expect(page.locator('[data-state="new"]')).toHaveCount(0);
  await expect(page.getByTestId("home-task-card")).toHaveCount(8);
});

test("status indicator is hidden only when there are no tasks", async ({ page }) => {
  await page.goto("/iframe.html?id=app-components-home-tasks--no-tasks&viewMode=story");

  await expect(page.getByText("No tasks", { exact: true })).toBeVisible();
  await expect(page.locator("status-indicator")).toHaveCount(0);

  await page.goto("/iframe.html?id=app-components-home-tasks--empty&viewMode=story");

  // Tasks exist, the selected status just has none of them: the rail is
  // filtered, not empty, and must not read as "you have no tasks".
  await expect(page.getByText("No tasks in this status")).toBeVisible();
  await expect(page.getByText("No tasks", { exact: true })).toHaveCount(0);
  await expect(page.locator("status-indicator")).toBeVisible();
});

test("home rail cards reorder by drag with the same well and settle", async ({
  page,
}) => {
  await page.goto("/iframe.html?id=app-components-home-tasks--default&viewMode=story");

  const stack = page.getByTestId("home-tasks-card-stack");
  const cards = stack.getByTestId("home-task-card");
  await expect(cards).toHaveCount(2);
  await expect(cards.first()).toContainText("Start on refraction UI library");

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
  await expect(cards.first()).toContainText(
    "Summarizing recent OpenAI's update and create a HTML"
  );
  await expect(cards.nth(1)).toContainText("Start on refraction UI library");
});
