import { expect, test as baseTest } from "@playwright/test";
import { serveAppFixtures } from "../../../e2e/helpers/app-fixtures";

const test = baseTest.extend<{}, { driveBaseURL: string }>({
  driveBaseURL: [
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

test.use({ actionTimeout: 10_000 });

const count = 2000;
test(`Drive directory ${count} files`, async ({ page, driveBaseURL }) => {
  await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
  await page.waitForFunction(() => Boolean(window.driveStress));
  const metrics = await page.evaluate(async (fileCount) => {
    window.driveStress.load(fileCount);
    await new Promise<void>((done) =>
      requestAnimationFrame(() => requestAnimationFrame(() => done()))
    );
    return {
      initialThumbnailRequests: window.driveStress.thumbnails.length,
      initialRows: document.querySelectorAll('[data-testid^="drive-file-file-"]')
        .length,
    };
  }, count);
  // Thumbnail requests and mounted rows must follow the viewport, not the directory.
  expect(metrics.initialThumbnailRequests).toBeLessThan(60);
  expect(metrics.initialRows).toBeLessThan(60);
  await page.getByTestId("drive-list-header").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText(String(count));
  await page.getByTestId("drive-list-header").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText("0");
  const viewport = page.locator('[data-slot="scroll-area-viewport"]');
  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await page.getByTestId(`drive-file-file-${count - 1}`).click();
  await expect(page.getByTestId("opened-file")).toHaveText(`file-${count - 1}`);
});

test("Drive window preserves keyboard traversal, menus and recording reveals", async ({
  page,
  driveBaseURL,
}) => {
  await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
  await page.waitForFunction(() => Boolean(window.driveStress));
  await page.evaluate(() => window.driveStress.load(200));
  await page.getByTestId("drive-file-file-0").focus();
  for (let row = 1; row <= 30; row++) {
    for (let control = 0; control < 4; control++) await page.keyboard.press("Tab");
    await expect(page.getByTestId(`drive-file-file-${row}`)).toBeFocused();
  }
  await page.getByTestId("drive-file-file-30").click({ button: "right" });
  await expect(page.getByRole("menu")).toBeVisible();
  await page.locator('[data-slot="scroll-area-viewport"]').evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(page.getByRole("menu")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("drive-file-file-30")).toBeFocused();
  await page.evaluate(() => {
    document.documentElement.style.fontSize = "20px";
  });
  await page.evaluate(() => window.driveStress.reveal(199));
  const target = page.getByTestId("drive-file-file-199");
  await expect(target).toHaveAttribute("data-reveal-highlight", "true");
  await expect(target).toBeFocused();
  await expect(target).toBeInViewport();
  await expect(page.getByTestId("selection-count")).toHaveText("0");
  await expect(page.getByTestId("opened-file")).toHaveText("");
  const rectangles = await page
    .locator('[data-testid^="drive-file-file-"]')
    .evaluateAll((elements) =>
      elements
        .map((element) => element.getBoundingClientRect())
        .filter((rect) => rect.top >= 0 && rect.bottom <= innerHeight)
        .sort((left, right) => left.top - right.top)
    );
  expect(rectangles.length).toBeGreaterThan(1);
  expect(
    rectangles.every(
      (rect, index) => index === 0 || rect.top >= rectangles[index - 1]!.bottom
    )
  ).toBe(true);
});

test("Drive folder selection includes unloaded rows and nested files", async ({
  page,
  driveBaseURL,
}) => {
  await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
  await page.waitForFunction(() => Boolean(window.driveStress));
  const metrics = await page.evaluate(async () => {
    window.driveStress.load(2000, true);
    await new Promise<void>((done) =>
      requestAnimationFrame(() => requestAnimationFrame(() => done()))
    );
    return {
      mountedFolders: document.querySelectorAll('[data-testid^="drive-folder-"]')
        .length,
    };
  });
  expect(metrics.mountedFolders).toBeLessThan(60);
  await page.getByTestId("drive-folder-Folder 0").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText("10");
  await page.getByTestId("drive-list-header").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText("2000");
  await page.getByTestId("drive-list-header").locator("label").click();
  await page.evaluate(() => window.driveStress.reveal(1999));
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Nested");
  await expect(page.getByTestId("drive-file-file-1999")).toBeFocused();
  await expect(page.getByTestId("drive-file-file-1999")).toBeInViewport();
});
