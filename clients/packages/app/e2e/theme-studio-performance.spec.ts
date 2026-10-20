import { expect, test as baseTest, type Locator } from "@playwright/test";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";

const test = baseTest.extend<{}, { themeBaseURL: string }>({
  themeBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const fixtures = await serveAppFixtures();
      try {
        await use(fixtures.url);
      } finally {
        await fixtures.close();
      }
    },
    { scope: "worker" },
  ],
});

// The tests share this file's production build, so one worker runs them all.
test.describe.configure({ mode: "default" });

const countStyleMutations = (studio: Locator, duration: number) =>
  studio.evaluate(async (element, milliseconds) => {
    let count = 0;
    const observer = new MutationObserver((records) => {
      count += records.length;
    });
    observer.observe(element, {
      attributes: true,
      subtree: true,
      attributeFilter: ["style", "data-dragging"],
    });
    await new Promise<void>((done) => setTimeout(done, milliseconds));
    observer.disconnect();
    return count;
  }, duration);

test("Theme studio sleeps after settling in either motion preference", async ({
  page,
  themeBaseURL,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(new URL("/theme-studio-performance.html", themeBaseURL).href);
  const studio = page.locator('[data-slot="custom-theme-studio"]');
  await expect(studio).toBeVisible();
  // Once the entrance settles, an idle studio writes no styles.
  await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
  const mutations = await countStyleMutations(studio, 2000);
  const hue = studio.getByRole("slider", { name: "Hue", exact: true });
  const initial = await hue.getAttribute("aria-valuenow");
  const initialTransform = await hue.evaluate((element) => element.style.transform);
  await hue.focus();
  await page.keyboard.press("ArrowRight");
  await expect(hue).not.toHaveAttribute("aria-valuenow", initial!);
  await expect
    .poll(() => hue.evaluate((element) => element.style.transform))
    .not.toBe(initialTransform);
  const bounds = (await hue.boundingBox())!;
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  await page.mouse.down();
  await expect(hue).toHaveAttribute("data-dragging", "true");
  await page.mouse.move(
    bounds.x + bounds.width / 2 + 30,
    bounds.y + bounds.height / 2 - 15,
    { steps: 5 }
  );
  await page.mouse.up();
  await expect(hue).not.toHaveAttribute("data-dragging", "true");
  await page.waitForTimeout(750);
  await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
  const afterDrag = await hue.getAttribute("aria-valuenow");
  await page.getByRole("button", { name: "Close studio", exact: true }).click();
  await expect(studio).toHaveCount(0);
  await page.getByRole("button", { name: "Open studio", exact: true }).click();
  await expect(studio).toBeVisible();
  await expect(hue).toHaveAttribute("aria-valuenow", afterDrag!);
  await page.emulateMedia({
    reducedMotion: "reduce",
  });
  await hue.focus();
  const reopenedTransform = await hue.evaluate((element) => element.style.transform);
  await page.keyboard.press("ArrowLeft");
  await expect(hue).not.toHaveAttribute("aria-valuenow", afterDrag!);
  await expect
    .poll(() => hue.evaluate((element) => element.style.transform))
    .not.toBe(reopenedTransform);
  const canvas = studio.locator(".comma-custom-theme-studio__canvas");
  const oldCanvas = (await canvas.boundingBox())!;
  const oldTransform = await hue.evaluate((element) => element.style.transform);
  await page.setViewportSize({ width: 400, height: 800 });
  await expect
    .poll(async () => (await canvas.boundingBox())!.width)
    .toBeLessThan(oldCanvas.width);
  await expect
    .poll(() => hue.evaluate((element) => element.style.transform))
    .not.toBe(oldTransform);
  await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
  const newCanvas = (await canvas.boundingBox())!;
  const newHue = (await hue.boundingBox())!;
  expect(newHue.x + newHue.width / 2).toBeGreaterThan(newCanvas.x);
  expect(newHue.x + newHue.width / 2).toBeLessThan(newCanvas.x + newCanvas.width);
  await page.reload();
  await expect(studio).toBeVisible();
  await expect(hue).not.toHaveAttribute("aria-valuenow", initial!);
  expect(mutations).toBe(0);

  // The actual popover scales on entrance. Its visual scale must not become
  // the indicator's layout coordinate system when the pad goes to sleep.
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(new URL("/theme-studio-performance.html?picker", themeBaseURL).href);
  await page.getByRole("button", { name: /Select theme/ }).click();
  await page.getByRole("option", { name: "Custom", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-comma-theme", "custom");
  await expect(studio).toBeVisible();
  await page.waitForTimeout(750);
  await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
  const centerError = () =>
    hue.evaluate((element) => {
      const pad = element
        .closest('[data-slot="custom-theme-studio"]')!
        .querySelector(".comma-custom-theme-studio__canvas")!
        .getBoundingClientRect();
      const indicator = element.getBoundingClientRect();
      const value = Number.parseFloat(
        getComputedStyle(document.documentElement).getPropertyValue("--comma-theme-h")
      );
      return Math.abs(
        indicator.x + indicator.width / 2 - pad.x - (value / 360) * pad.width
      );
    });
  await expect.poll(centerError).toBeLessThan(0.1);
  const rootHue = () =>
    page.evaluate(() =>
      Number.parseFloat(
        getComputedStyle(document.documentElement).getPropertyValue("--comma-theme-h")
      )
    );
  const popupValue = await rootHue();
  const popupBounds = (await hue.boundingBox())!;
  const popupCanvas = (await canvas.boundingBox())!;
  await page.mouse.move(
    popupBounds.x + popupBounds.width / 2,
    popupBounds.y + popupBounds.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    popupBounds.x + popupBounds.width / 2 + 10,
    popupBounds.y + popupBounds.height / 2,
    { steps: 5 }
  );
  await page.mouse.up();
  await expect
    .poll(async () =>
      Math.abs((await rootHue()) - popupValue - (10 / popupCanvas.width) * 360)
    )
    .toBeLessThan(0.1);
  await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
});
