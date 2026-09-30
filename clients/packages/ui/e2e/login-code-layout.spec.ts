import { expect, test } from "@playwright/test";

test("verification cells stay square across desktop and narrow layouts", async ({
  page,
}) => {
  for (const width of [1280, 420]) {
    await page.setViewportSize({ width, height: 720 });
    await page.goto(
      "/iframe.html?id=app-components-login--awaiting-code&viewMode=story"
    );
    const input = page.getByRole("textbox", { name: "Verification code" });
    await expect(input).toBeVisible();
    await input.fill("123");
    await input.blur();
    const cells = page.locator("[data-login-code-cell]");
    await expect(cells).toHaveCount(6);
    await expect
      .poll(async () =>
        cells.evaluateAll((elements) =>
          elements.every((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && Math.abs(rect.width - rect.height) < 1;
          })
        )
      )
      .toBe(true);
    const bounds = await cells.last().boundingBox();
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
    await input.press("End");
    await input.press("4");
    await expect(input).toHaveValue("1234");
  }
});
