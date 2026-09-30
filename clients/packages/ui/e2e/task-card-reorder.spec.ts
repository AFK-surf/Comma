import { expect, test, type Page } from "@playwright/test";

const STORY = "/iframe.html?id=app-components-tasks-task-board--reorder&viewMode=story";
const LIVE_UPDATE_STORY =
  "/iframe.html?id=app-components-tasks-task-board--reorder-live-update&viewMode=story";

const items = (page: Page) => page.locator('[data-slot="task-card-reorder-item"]');

const titles = async (page: Page) =>
  (await items(page).allInnerTexts()).map((text) => text.split("\n")[0]);

/** Presses the card at `from` and walks the pointer to the middle of `to`. */
async function dragCard(page: Page, from: number, to: number) {
  const source = await items(page).nth(from).boundingBox();
  const target = await items(page).nth(to).boundingBox();
  if (!source || !target) throw new Error("card is not laid out");
  await page.mouse.move(source.x + 40, source.y + source.height / 2);
  await page.mouse.down();
  // A few steps, so the lift threshold and the target index both go through
  // the same pointermove path a real drag would.
  await page.mouse.move(source.x + 40, target.y + target.height / 2, { steps: 12 });
}

test("dragging a card reorders its column and leaves a well behind", async ({
  page,
}) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);

  await dragCard(page, 0, 2);

  const lifted = items(page).nth(0);
  await expect(lifted).toHaveAttribute("data-dragging", "true");
  // The slot the card came out of paints itself as an empty well.
  await expect(lifted).toHaveClass(/bg-quaternary/);
  // The card travels on a transform, so its slot never leaves the flow.
  expect(
    await lifted.evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).not.toBe("none");
  // Its neighbours slide up to open the gap at the index the drop would use.
  expect(
    await items(page)
      .nth(1)
      .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).not.toBe("none");

  await page.mouse.up();

  await expect(items(page).nth(0)).not.toHaveAttribute("data-dragging", "true");
  expect(await titles(page)).toEqual([
    "Prepare the onboarding brief",
    "Review the launch checklist",
    "Summarize the latest product feedback",
    "Publish the weekly customer digest",
    "Archive the superseded research workspace",
  ]);
  // The settle animation runs the card from where the drag drew it to the slot
  // its new index gives it, and leaves nothing transformed behind.
  await expect
    .poll(() =>
      items(page)
        .nth(2)
        .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
    )
    .toBe("none");
});

test("Escape drops the card back where it started", async ({ page }) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);
  const before = await titles(page);

  await dragCard(page, 3, 0);
  await expect(items(page).nth(3)).toHaveAttribute("data-dragging", "true");
  await page.keyboard.press("Escape");

  await expect(items(page).nth(3)).not.toHaveAttribute("data-dragging", "true");
  expect(await titles(page)).toEqual(before);
  await page.mouse.up();
});

test("a click still opens the card, and the drag that moved it does not", async ({
  page,
}) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);
  await page.evaluate(() => {
    document.addEventListener("click", (event) => {
      const button = (event.target as HTMLElement).closest("button");
      if (button)
        document.body.dataset.opened = button.getAttribute("aria-label") ?? "";
    });
  });

  await items(page).nth(0).click();
  await expect(page.locator("body")).toHaveAttribute(
    "data-opened",
    "Summarize the latest product feedback"
  );

  await page.evaluate(() => {
    delete document.body.dataset.opened;
  });
  await dragCard(page, 0, 2);
  await page.mouse.up();

  await expect(page.locator("body")).not.toHaveAttribute("data-opened", /.*/);
});

test("the card sticks to the hand and falls into the well from where it is", async ({
  page,
}) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);

  const first = await items(page).nth(0).boundingBox();
  const last = await items(page).nth(4).boundingBox();
  if (!first || !last) throw new Error("cards are not laid out");

  // Drag the first card well past the end of the list, drifting sideways.
  await page.mouse.move(first.x + 40, first.y + first.height / 2);
  await page.mouse.down();
  await page.mouse.move(first.x + 160, last.y + last.height + 120, { steps: 12 });

  const held = await items(page)
    .nth(0)
    .evaluate((slot) => {
      const matrix = new DOMMatrix(getComputedStyle(slot.firstElementChild!).transform);
      return { x: matrix.m41, y: matrix.m42 };
    });
  // Vertically it follows the hand 1:1, past the end of the list; sideways it
  // only leans, staying inside the column.
  expect(held.y).toBeGreaterThan(last.y - first.y);
  expect(Math.abs(held.x)).toBeGreaterThan(0);
  expect(Math.abs(held.x)).toBeLessThanOrEqual(12);

  const drawnTop = first.y + first.height / 2 + held.y - first.height / 2;
  await page.mouse.up();

  // The settle animation starts from where the card was drawn — the very next
  // frame it must still be near the hand, not teleported back into the list.
  const settling = await items(page)
    .nth(4)
    .evaluate((slot) => {
      const carrier = slot.firstElementChild!;
      const rect = carrier.getBoundingClientRect();
      return { animations: carrier.getAnimations().length, top: rect.top };
    });
  expect(settling.animations).toBeGreaterThan(0);
  expect(Math.abs(settling.top - drawnTop)).toBeLessThan(60);

  // And it lands as the last card.
  expect((await titles(page))[4]).toBe("Summarize the latest product feedback");
});

test("a neighbour yields only once the card crosses its middle", async ({ page }) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);

  const first = await items(page).nth(0).boundingBox();
  const second = await items(page).nth(1).boundingBox();
  if (!first || !second) throw new Error("cards are not laid out");

  const grabY = first.y + 20;
  await page.mouse.move(first.x + 40, grabY);
  await page.mouse.down();

  // Covering the neighbour's top part is just hovering: nothing yields yet.
  const shy = second.y + second.height / 2 - 10 - (first.y + first.height);
  await page.mouse.move(first.x + 40, grabY + shy, { steps: 6 });
  expect(
    await items(page)
      .nth(1)
      .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).toBe("none");

  // The moment the card's bottom edge passes the neighbour's middle, the
  // neighbour slides over into the vacated spot.
  await page.mouse.move(first.x + 40, grabY + shy + 24, { steps: 4 });
  expect(
    await items(page)
      .nth(1)
      .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).not.toBe("none");

  await page.mouse.up();
  expect((await titles(page)).slice(0, 2)).toEqual([
    "Prepare the onboarding brief",
    "Summarize the latest product feedback",
  ]);
});

test("a neighbour yielding downward paints above the well, not under it", async ({
  page,
}) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);

  const first = await items(page).nth(0).boundingBox();
  const second = await items(page).nth(1).boundingBox();
  if (!first || !second) throw new Error("cards are not laid out");

  // Drag the SECOND card up past the first card's middle: the first card — an
  // earlier DOM sibling than the well — must slide down over the well.
  await page.mouse.move(second.x + 40, second.y + 20);
  await page.mouse.down();
  await page.mouse.move(second.x + 40, first.y + 4, { steps: 8 });

  expect(
    await items(page)
      .nth(0)
      .evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
  ).not.toBe("none");

  // Paint order, asserted for real: probing the origin slot's area must hit
  // the yielded card, never the gray well behind it.
  await expect
    .poll(() =>
      page.evaluate(
        ([x, y]) => {
          const hit = document.elementFromPoint(x!, y!);
          return (
            hit?.closest("button")?.getAttribute("aria-label") ??
            hit?.getAttribute("data-slot")
          );
        },
        [second.x + second.width / 2, second.y + second.height / 2]
      )
    )
    .toBe("Summarize the latest product feedback");

  await page.mouse.up();
  expect((await titles(page)).slice(0, 2)).toEqual([
    "Prepare the onboarding brief",
    "Summarize the latest product feedback",
  ]);
});

test("a card dragged below the last slot is not cut off by the column body", async ({
  page,
}) => {
  await page.goto(STORY);
  await expect(items(page)).toHaveCount(5);

  const last = await items(page).nth(4).boundingBox();
  if (!last) throw new Error("card is not laid out");
  await page.mouse.move(last.x + 40, last.y + 20);
  await page.mouse.down();
  await page.mouse.move(last.x + 40, last.y + 50, { steps: 6 });
  await expect(items(page).nth(4)).toHaveAttribute("data-dragging", "true");

  // The held card now hangs past the end of the list. The column's scrollport
  // is the only box allowed to clip it: anything in between that clips the
  // vertical axis is exactly as tall as the cards and would cut the card off.
  const clipping = await items(page)
    .nth(4)
    .evaluate((slot) => {
      const found: string[] = [];
      for (
        let node = slot.parentElement;
        node && node.dataset.slot !== "scroll-area-viewport";
        node = node.parentElement
      ) {
        if (getComputedStyle(node).overflowY !== "visible") {
          found.push(node.dataset.slot ?? node.tagName);
        }
      }
      return found;
    });
  expect(clipping).toEqual([]);

  await page.mouse.up();
});

test("a live id update cancels the drag without reordering another task", async ({
  page,
}) => {
  test.slow();
  await page.goto(LIVE_UPDATE_STORY);
  await expect(items(page)).toHaveCount(3, { timeout: 45_000 });

  await dragCard(page, 0, 1);
  await expect(items(page).nth(0)).toHaveAttribute("data-dragging", "true");

  // Product-inbox updates can insert, remove, or reorder tasks while the
  // pointer is held. Trigger the same state update without releasing it.
  await page.getByRole("button", { name: "Insert live task" }).evaluate((button) => {
    (button as HTMLButtonElement).click();
  });

  await expect(items(page)).toHaveCount(4);
  await expect(
    page.locator('[data-slot="task-card-reorder-list"]')
  ).not.toHaveAttribute("data-dragging", "true");
  await expect(
    page.locator('[data-slot="task-card-reorder-item"][data-dragging="true"]')
  ).toHaveCount(0);
  for (const item of await items(page).all()) {
    await expect
      .poll(() =>
        item.evaluate((slot) => getComputedStyle(slot.firstElementChild!).transform)
      )
      .toBe("none");
  }

  await page.mouse.up();
  expect(await titles(page)).toEqual(["New live task", "Task A", "Task B", "Task C"]);

  // Cancellation leaves the primitive ready for the next real gesture.
  await dragCard(page, 1, 2);
  await page.mouse.up();
  expect(await titles(page)).toEqual(["New live task", "Task B", "Task A", "Task C"]);
});
