import { test, expect } from "@playwright/test";

const email = process.env.E2E_USER_EMAIL || "e2e@example.com";
const org = process.env.E2E_SUBSCRIPTION_ORG || "e2e";

// Organization accounts and private templates are sections of the React
// AI models page.
test("organization subscriptions, Claude OAuth popup and private templates", async ({ page, context }, testInfo) => {
  const modelName = `Subscription model ${Date.now()}`;
  const identity = "browser-fixture@example.com";
  await context.route("https://claude.ai/**", route => route.fulfill({ contentType: "text/html", body: "<h1>Authorization test destination</h1>" }));
  await page.goto(`/dev/login?email=${encodeURIComponent(email)}&to=/orgs/${org}/settings/models`);
  await expect(page.getByRole("heading", { name: "Organization accounts", exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Add account", exact: true }).click();
  await page.getByRole("menuitem", { name: "Import credentials", exact: true }).click();
  await page.getByRole("textbox", { name: "Or paste credential JSON" }).fill(JSON.stringify({ access_token: "browser-fixture-token", email: identity }));
  await page.getByRole("button", { name: "Import subscription", exact: true }).click();
  const row = page.getByRole("list", { name: "Organization accounts" }).getByRole("listitem").filter({ hasText: identity });
  await expect(row).toBeVisible();
  const enabled = page.getByRole("switch", { name: `Enable ${identity}` });
  await page.locator("label").filter({ has: enabled }).click();
  await expect(enabled).not.toBeChecked();
  await expect(page.locator("body")).not.toContainText("browser-fixture-token");
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.screenshot({ path: testInfo.outputPath("subscriptions-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 823, height: 964 });
  await page.screenshot({ path: testInfo.outputPath("subscriptions-compact.png"), fullPage: true });

  await page.getByRole("button", { name: "Add account", exact: true }).click();
  await page.getByRole("menuitem", { name: "Connect subscription", exact: true }).click();
  await page.getByRole("button", { name: /Provider/ }).click();
  await page.getByRole("option", { name: "Claude", exact: true }).click();
  const popupReady = page.waitForEvent("popup");
  await page.getByRole("button", { name: "Continue with Claude", exact: true }).click();
  const popup = await popupReady;
  await expect(popup).toHaveURL(/claude\.ai/);
  await expect(page.getByRole("textbox", { name: "Callback URL or authorization code" })).toBeVisible();
  await popup.close();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await page.getByRole("button", { name: `Actions for ${identity}`, exact: true }).click();
  await page.getByRole("menuitem", { name: "Remove", exact: true }).click();
  await page.getByRole("dialog", { name: "Remove subscription" }).getByRole("button", { name: "Remove", exact: true }).click();
  await expect(row).toHaveCount(0);

  await page.getByRole("button", { name: "Create template", exact: true }).click();
  await page.getByRole("textbox", { name: "Template name", exact: true }).fill(modelName);
  await page.getByRole("button", { name: "Save template", exact: true }).click();
  const template = page.getByRole("listitem").filter({ hasText: modelName });
  await expect(template).toBeVisible();
  await template.getByRole("button", { name: `Edit ${modelName}`, exact: true }).click();
  await page.getByRole("textbox", { name: "Maximum output tokens" }).fill("8192");
  await page.screenshot({ path: testInfo.outputPath("private-template-editor.png"), fullPage: true });
  await page.getByRole("button", { name: "Save template", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  // The allowed models above offer the new private template.
  await expect(page.locator(".bft-checklist")).toContainText(modelName);
  await template.getByRole("button", { name: `Delete ${modelName}`, exact: true }).click();
  await page.getByRole("button", { name: "Delete template", exact: true }).click();
  await expect(template).toHaveCount(0);
});
