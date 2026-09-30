import { expect, test } from "@playwright/test";

const CARD_STORY =
  "/iframe.html?id=app-components-tasks-task-board--card&viewMode=story";

test("running task card shows a shimmering progress line", async ({ page }) => {
  await page.goto(CARD_STORY);

  const progress = page.locator(".comma-shiny-text").first();
  await expect(progress).toBeVisible();
  // background-clip:text is what makes the sweep visible; without it the copy
  // would render as a flat block of color.
  await expect
    .poll(() =>
      progress.evaluate((element) => {
        const style = getComputedStyle(element);
        return {
          clipsToText:
            style.webkitBackgroundClip === "text" || style.backgroundClip === "text",
          hasGradient: style.backgroundImage.includes("gradient"),
        };
      })
    )
    .toEqual({ clipsToText: true, hasGradient: true });
});

test("task card paints its 0.5px stroke without spending layout on a border", async ({
  page,
}) => {
  await page.goto(CARD_STORY);

  const body = page.locator('[data-slot="task-card-body"]').first();
  await expect(body).toBeVisible();

  await expect
    .poll(() =>
      // TaskCard renders root > body, so the body's parent is the card root
      // that carries the stroke.
      body.evaluate((element) => {
        const style = getComputedStyle(element.parentElement as Element);
        return {
          borderTop: style.borderTopWidth,
          insetShadow: style.boxShadow.includes("inset"),
        };
      })
    )
    .toEqual({ borderTop: "0px", insetShadow: true });
});
