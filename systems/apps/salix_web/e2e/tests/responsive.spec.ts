import { test, expect } from "@playwright/test";

// Use the existing local dashboard and real token login. Each test owns its group.
for (const width of [1440, 1024, 768, 390]) {
  test(`responsive navigation and group tabs at ${width}px`, async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto("/dash/login");
    await page.locator('input[name="token"]').fill(process.env.SALIX_API_TOKEN || "e2e-admin-token");
    await page.getByRole("button", { name: "Sign in" }).click();
    await page.goto("/dash/groups");
    await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
    await page.getByRole("button", { name: "New group" }).click();
    const form = page.locator("#new-group form");
    await form.locator('input[name="name"]').fill(`Responsive ${width} ${Date.now()}`);
    await form.locator('button[type="submit"]').click();
    await expect(page).toHaveURL(/\/dash\/groups\/.+/);
    await page.setViewportSize({ width, height: 900 });
    await expect.poll(() => page.locator("main").evaluate(el => el.scrollWidth - el.clientWidth)).toBe(0);

    const tabs = page.locator("main nav").getByRole("link");
    // Overview through Inbound API, then Voice and Signal.
    await expect(tabs).toHaveCount(11);
    for (let index = 0; index < 11; index++) {
      const tab = tabs.nth(index);
      await tab.focus();
      const box = await tab.boundingBox();
      expect(box!.x).toBeGreaterThanOrEqual(0);
      expect(box!.x + box!.width).toBeLessThanOrEqual(width);
      const href = await tab.getAttribute("href");
      await page.keyboard.press("Enter");
      await expect(page).toHaveURL(new RegExp(href!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$"));
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
    }

    const sidebar = page.locator("#dash-sidebar");
    const toggle = page.getByRole("button", { name: "Open navigation", includeHidden: true });
    if (width >= 1024) {
      await expect(sidebar).toBeVisible();
      expect((await sidebar.boundingBox())!.width).toBe(240);
      await expect(toggle).toBeHidden();
    } else {
      await expect(sidebar).toBeHidden();
      await toggle.focus();
      await page.keyboard.press("Enter");
      await expect(toggle).toHaveAttribute("aria-expanded", "true");
      await expect(sidebar).toHaveAttribute("aria-modal", "true");
      expect(await page.locator("#dash-content").evaluate(el => el.inert)).toBe(true);
      const close = page.locator("#dash-navigation-close");
      await expect(close).toBeFocused();
      await page.keyboard.press("Shift+Tab");
      await expect(sidebar.getByRole("link", { name: "Sign out" })).toBeFocused();
      await page.keyboard.press("Tab");
      await expect(close).toBeFocused();
      await page.keyboard.press("Escape");
      await expect(toggle).toBeFocused();
      await expect(sidebar).toBeHidden();
      expect(await page.locator("#dash-content").evaluate(el => el.inert)).toBe(false);
      await toggle.click();
      await close.click();
      await expect(sidebar).toBeHidden();
      await toggle.click();
      await page.locator("#dash-navigation-backdrop").click({ position: { x: width - 10, y: 200 } });
      await expect(sidebar).toBeHidden();
      await toggle.click();
      await page.setViewportSize({ width: 1440, height: 900 });
      await expect(toggle).toHaveAttribute("aria-expanded", "false");
      expect(await page.locator("#dash-content").evaluate(el => el.inert)).toBe(false);
      await page.setViewportSize({ width, height: 900 });
      await expect(sidebar).toBeHidden();
      await toggle.click();
      await sidebar.getByRole("link", { name: "Home", exact: true }).click();
      await expect(page).toHaveURL(/\/dash$/);
      await expect(sidebar).toBeHidden();
    }
    expect(errors).toEqual([]);
  });
}
