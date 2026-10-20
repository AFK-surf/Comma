import { expect, test, type Page } from "@playwright/test";
import { resolve } from "node:path";

// Uses the actual Electron renderer build, but holds the application chunk so
// the first painted frame cannot depend on React or Session startup.
const rendererRoot = resolve("apps/electron/.vite/renderer/main_window");
const origin = "http://comma-main-boot.test";

async function openWithApplicationHeld(page: Page, role: string) {
  // The preload exposes the window identity before any page script runs.
  await page.addInitScript((windowRole) => {
    Object.assign(window, { commaNative: { self: { role: windowRole } } });
  }, role);
  let applicationRequested = false;
  await page.route(`${origin}/**`, async (route) => {
    const pathname = new URL(route.request().url()).pathname;
    if (/\/renderComma-[^/]+\.js$/.test(pathname)) {
      applicationRequested = true;
      await route.abort();
      return;
    }
    await route.fulfill({
      path: resolve(rendererRoot, `.${pathname === "/" ? "/index.html" : pathname}`),
    });
  });
  await page.goto(`${origin}/`, { waitUntil: "domcontentloaded" });
  await expect.poll(() => applicationRequested).toBe(true);
}

for (const reducedMotion of ["no-preference", "reduce"] as const) {
  test(`main window paints the logo animation before the application loads (${reducedMotion})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion });
    await openWithApplicationHeld(page, "main-window");

    const logo = page.locator("#comma-main-window-boot .comma-logo-animation");
    await expect(logo).toBeVisible();
    await expect(page.locator("#root")).toBeEmpty();
    const box = await logo.boundingBox();
    const viewport = page.viewportSize()!;
    expect(box!.width).toBe(36);
    expect(box!.height).toBe(36);
    expect(box!.x + box!.width / 2).toBeCloseTo(viewport.width / 2, 0);
    expect(box!.y + box!.height / 2).toBeCloseTo(viewport.height / 2, 0);
    const running = await logo.evaluate(
      (element) => element.getAnimations({ subtree: true }).length
    );
    if (reducedMotion === "reduce") {
      expect(running).toBe(0);
    } else {
      expect(running).toBeGreaterThan(0);
    }
  });
}

test("other windows that share the document paint no main window boot", async ({
  page,
}) => {
  await openWithApplicationHeld(page, "onboarding-window");
  await expect(page.locator("#comma-main-window-boot")).toHaveCount(0);
});
