import { expect, test } from "@playwright/test";

test("disk categories and accessible total fit a 320px viewport", async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 720 });
  await page.goto(
    "/iframe.html?id=app-components-compute-disk--categories&viewMode=story"
  );
  await expect(page.getByRole("group", { name: "4 GiB used of 16 GiB" })).toBeVisible();
  for (const label of [
    "Images & runtime: 2.9 GiB",
    "Build cache: 1 GiB",
    "Private data: 1 MiB",
    "Remaining: 12 GiB",
  ]) {
    await expect(page.getByText(label, { exact: true })).toBeVisible();
  }
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
  ).toBe(true);
});
