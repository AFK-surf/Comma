import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The remote browser's frames, takeover and panel run on the web app world:
// e2e/app-shell/agent-browser.chromium.test.ts.
test("Settings clears the shared browser logins after a confirmation", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ taskStatus: "active" });
  let cleared = false;
  await page.route("**/v1/comma/workspaces/*/browsers**", async (route) => {
    const request = route.request();
    const headers = {
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
    };
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers });
    const url = new URL(request.url());
    if (request.method() === "POST" && url.pathname.endsWith("/clear-storage")) {
      cleared = true;
      return route.fulfill({
        headers,
        contentType: "application/json",
        body: JSON.stringify({ cleared: true }),
      });
    }
    await route.fulfill({
      headers,
      contentType: "application/json",
      body: JSON.stringify({ browsers: [] }),
    });
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "browser-e2e@comma.local",
      token: "comma_sess_browser_e2e",
    });
    await page.goto("/#/settings?category=browser");
    await expect(
      page.locator('[data-slot="settings-sidebar-item"][aria-current="page"]')
    ).toHaveText("Browser");
    await page.getByRole("button", { name: "Clear shared logins…" }).click();
    const clearDialog = page.getByRole("dialog", {
      name: "Clear shared logins",
      exact: true,
    });
    await expect(clearDialog).toBeVisible();
    await clearDialog.getByRole("button", { name: "Cancel", exact: true }).click();
    expect(cleared).toBe(false);
    await page.getByRole("button", { name: "Clear shared logins…" }).click();
    await clearDialog
      .getByRole("button", { name: "Clear shared logins", exact: true })
      .click();
    await expect.poll(() => cleared).toBe(true);
    await expect(page.getByText("Saved browser logins cleared.")).toBeVisible();
  } finally {
    await stub.close();
  }
});
