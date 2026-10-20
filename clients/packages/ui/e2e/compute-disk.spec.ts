import { expect, test } from "@playwright/test";

test("disk summary fits a 320px viewport without horizontal overflow", async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 720 });
  await page.goto(
    "/iframe.html?id=app-components-compute-disk--partial-detail&viewMode=story"
  );
  await expect(page.getByRole("group", { name: "4 GiB used of 16 GiB" })).toBeVisible();
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
  ).toBe(true);
});
