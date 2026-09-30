import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// Toasts are a top-layer surface: a modal neither hides them from assistive
// tech nor takes their presses. The Settings modal covers the stack's corner,
// which is exactly where a reader has to reach a toast raised behind it.
test("toasts stay reachable over the Settings modal and leave it open", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "toast-top-layer@comma.local",
    token: "comma_sess_toast_top_layer",
  });
  const workspacesUrl = "http://127.0.0.1:65535/v1/comma/workspaces";
  await page.route(workspacesUrl, (route) => route.abort("connectionrefused"));
  // A failed workspace request raises the plugins load error as a toast.
  await page.goto("/#/plugins");
  const dismiss = page.getByRole("button", { name: "Dismiss notification" });
  await expect(dismiss.first()).toBeVisible();

  // A failed retry replaces the notification. The previous toast's delayed
  // dismissal must not close the replacement.
  const retryFailure = page.waitForEvent(
    "requestfailed",
    (request) => request.url() === workspacesUrl
  );
  await page
    .getByTestId("plugins-load-error")
    .getByRole("button", { name: "Retry" })
    .click();
  await retryFailure;
  await expect(dismiss).toHaveCount(1);
  await expect(dismiss.first()).toBeVisible();

  await page.getByRole("button", { exact: true, name: "Settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Settings sections" });
  await expect(dialog).toBeVisible();

  // Still in the accessibility tree behind the modal, and its press lands on
  // the toast rather than on the modal's own content underneath.
  await expect(dismiss.first()).toBeVisible();
  await dismiss.first().click();
  await expect(dismiss).toHaveCount(0);
  await expect(dialog).toBeVisible();
});
