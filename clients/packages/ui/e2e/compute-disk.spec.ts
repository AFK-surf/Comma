import { expect, test } from "@playwright/test";

for (const width of [320, 736]) {
  for (const theme of ["light", "dark"]) {
    test(`disk summary supports keyboard and reduced motion at ${width}px in ${theme}`, async ({
      page,
    }) => {
      await page.setViewportSize({ width, height: 720 });
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(
        `/iframe.html?id=app-components-compute-disk--partial-detail&viewMode=story&globals=theme:${theme};motionPreference:reduced`
      );
      await expect(
        page.getByRole("group", { name: "4 GiB used of 16 GiB" })
      ).toBeVisible();
      const local = page.getByRole("button", { name: "Local environment: 1 GiB" });
      await page.keyboard.press("Tab");
      await expect(local).toBeFocused();
      await page.keyboard.press("Enter");
      await expect(page.getByRole("status")).toHaveText("Selected local");
      expect(
        await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
      ).toBe(true);
      await page.screenshot({ path: `/tmp/rfc40-disk-${width}-${theme}.png` });
    });
  }
}
test("stale detail keeps the total and removes environment interaction", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-compute-disk--stale-detail&viewMode=story"
  );
  await expect(page.getByRole("group", { name: "4 GiB used of 16 GiB" })).toBeVisible();
  await expect(page.getByText("Environment detail unavailable")).toBeVisible();
  await expect(page.getByRole("button")).toHaveCount(0);
});
