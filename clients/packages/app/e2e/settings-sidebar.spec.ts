import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("Settings sidebar leaves a gap between category backgrounds and the scrollbar", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ taskSchedule: null });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "settings-spacing@comma.local",
      token: "comma_sess_settings_spacing",
    });
    // Short enough that the category list overflows and shows its scrollbar.
    await page.setViewportSize({ width: 1280, height: 600 });
    await page.goto("/#/settings");
    const sidebar = page.getByRole("complementary", { name: "Settings sections" });
    const scrollbar = sidebar.locator(
      '[data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
    );
    const general = sidebar.getByRole("button", { name: "General", exact: true });
    await general.hover();
    await expect(scrollbar).toBeVisible();
    const expectGap = async () => {
      const track = await scrollbar.boundingBox();
      const row = await general.boundingBox();
      expect(track).not.toBeNull();
      expect(row).not.toBeNull();
      expect(track!.x - row!.x - row!.width).toBeGreaterThanOrEqual(4);
    };
    await expectGap();
    const viewport = sidebar.locator('[data-slot="scroll-area-viewport"]');
    await viewport.hover();
    await page.mouse.wheel(0, 600);
    await expect
      .poll(() => viewport.evaluate((element) => element.scrollTop))
      .toBeGreaterThan(0);
    const lastItem = sidebar.locator('[data-slot="settings-sidebar-item"]').last();
    await lastItem.scrollIntoViewIfNeeded();
    await expect(lastItem).toBeVisible();
    const track = await scrollbar.boundingBox();
    const row = await lastItem.boundingBox();
    expect(track!.x - row!.x - row!.width).toBeGreaterThanOrEqual(4);
  } finally {
    await stub.close();
  }
});
