import { test, expect } from "@playwright/test";

const email = process.env.E2E_USER_EMAIL || "e2e@example.com";
const org = process.env.E2E_SUBSCRIPTION_ORG || "e2e";

test("organization subscriptions, Claude OAuth popup and private templates", async ({ page, context }, testInfo) => {
  const modelName = `Subscription model ${Date.now()}`;
  await context.route("https://claude.ai/**", route => route.fulfill({ contentType: "text/html", body: "<h1>Authorization test destination</h1>" }));
  await page.goto(`/dev/login?email=${encodeURIComponent(email)}&to=/orgs/${org}/settings/models`);
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
  if (await page.getByRole("button", { name: "Maybe later", exact: true }).isVisible()) {
    await page.getByRole("button", { name: "Maybe later", exact: true }).click();
  }
  await page.getByRole("link", { name: "Organization accounts", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Organization accounts", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Import", exact: true }).click();
  await page.getByLabel("Or paste credential JSON").fill(JSON.stringify({ access_token: "browser-fixture-token", email: "browser-fixture@example.com" }));
  await page.getByRole("button", { name: "Import subscription", exact: true }).click();
  const row = page.getByRole("row").filter({ hasText: "browser-fixture@example.com" });
  await expect(row).toBeVisible();
  await row.getByRole("switch").click();
  await expect(row).toHaveAttribute("data-disabled", "true");
  await expect(page.locator("body")).not.toContainText("browser-fixture-token");
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.screenshot({ path: testInfo.outputPath("subscriptions-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 823, height: 964 });
  await page.screenshot({ path: testInfo.outputPath("subscriptions-compact.png"), fullPage: true });
  await page.getByRole("button", { name: "Connect subscription", exact: true }).click();
  await page.locator("#subscription-provider").selectOption("claude");
  const popupReady = page.waitForEvent("popup");
  await page.getByRole("button", { name: "Continue with Claude", exact: true }).click();
  const popup = await popupReady;
  await expect(popup).toHaveURL(/claude\.ai/);
  await expect(page.getByLabel("Callback URL or authorization code")).toBeVisible();
  await popup.close();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await row.getByRole("button", { name: "Remove subscription", exact: true }).click();
  await page.locator("#subscription-dialog").getByRole("button", { name: "Remove subscription", exact: true }).click();
  await expect(row).toHaveCount(0);

  await page.getByRole("link", { name: "Manage private templates", exact: true }).click();
  await page.getByRole("button", { name: "Create private template", exact: true }).click();
  await page.getByLabel("Template name", { exact: true }).fill(modelName);
  await page.getByRole("button", { name: "Save template", exact: true }).click();
  const template = page.getByRole("row").filter({ hasText: modelName });
  await expect(template).toBeVisible();
  await template.getByRole("button", { name: `Edit ${modelName}`, exact: true }).click();
  await page.getByLabel("Maximum output tokens").fill("8192");
  await page.screenshot({ path: testInfo.outputPath("private-template-editor.png"), fullPage: true });
  await page.getByRole("button", { name: "Save template", exact: true }).click();
  await expect(page.locator("#template-dialog")).toHaveCount(0);
  await page.getByRole("link", { name: "← Models and access", exact: true }).click();
  await expect(page.locator("#models-allowed")).toContainText(modelName);
  await page.getByRole("link", { name: "Manage private templates", exact: true }).click();
  await template.getByRole("button", { name: `Delete ${modelName}`, exact: true }).click();
  await page.getByRole("button", { name: "Delete template", exact: true }).click();
  await expect(template).toHaveCount(0);
});
