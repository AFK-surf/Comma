import { expect, test, type Locator, type Page, type Route } from "@playwright/test";

const apiBaseUrl = "http://127.0.0.1:65535";
const sessionId = "11111111-1111-4111-8111-111111111111";
const adminSessionEmail = "operator-with-a-very-long-name@example.com";

test("review code is configured, replaced and removed through account management", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes,
  });
  await page.goto("/?user=usr_admin_e2e");
  const userPage = page.getByTestId("admin-user-page");
  const open = async (name: string) => {
    await userPage.getByRole("button", { name: "More account actions" }).click();
    await page.getByRole("menuitem", { name, exact: true }).click();
  };
  await open("Change Admin access");
  const access = page.getByRole("dialog", { name: "Change Admin access", exact: true });
  await access.getByRole("combobox").selectOption("deny");
  await access.getByRole("button", { name: "Continue…" }).click();
  await confirmCommand(page, "Change Admin access?", "Use a dedicated demo account");

  for (const code of ["037291", "482693", null]) {
    await open("Review login code");
    const drawer = page.getByRole("dialog", { name: "Review login code", exact: true });
    if (code === null) {
      await drawer.getByRole("combobox", { name: /^Action/ }).selectOption("clear");
    } else {
      const input = drawer.getByLabel(/^Review login code/);
      await expect(input).toHaveValue("");
      await input.fill(code);
    }
    await drawer.getByRole("button", { name: "Continue…" }).click();
    const confirmation = page.getByRole("dialog", {
      name: "Review login code?",
      exact: true,
    });
    if (code) await expect(confirmation).not.toContainText(code);
    await confirmCommand(page, "Review login code?", "Prepare app review");
    expect(writes.at(-1)).toMatchObject({
      method: "PATCH",
      body: { review_login_code: code },
    });
    await expect(drawer).toHaveCount(0);
    await expect(userPage).toContainText(code ? "Review login code" : "Email OTP");
    expect(await localStorageSnapshot(page)).not.toContain(code ?? "037291");
  }
  await page.reload();
  await expect(userPage).toContainText("Email OTP");
  await expect(userPage).toContainText("Explicit deny");
});

test("Free Router models saves the edited list after review and reloads it", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes,
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Free Router models", exact: true }).click();
  await expect(page).toHaveURL(/\?section=free-models$/);
  const panel = page.getByRole("region", { name: "Free Router models", exact: true });
  const saveBar = page.getByRole("region", { name: "Unsaved changes" });
  await expect(panel.getByText("No models are free under this policy.")).toBeVisible();
  await expect(saveBar).toHaveCount(0);
  await panel.getByRole("textbox", { name: "Provider", exact: true }).fill("openai");
  await panel.getByRole("textbox", { name: "Model SKU" }).fill("gpt-5.6-luna");
  await panel.getByRole("button", { name: "Add model" }).click();
  await expect(saveBar).toContainText("1 unsaved change");
  await saveBar.getByRole("button", { name: "Save free Router models…" }).click();
  const review = page.getByRole("dialog", { name: "Save free Router models?" });
  await expect(review.getByRole("definition")).toContainText("Free");
  await expect(review).toContainText("openai/gpt-5.6-luna");
  await confirmCommand(
    page,
    "Save free Router models?",
    "Offer free Router calls",
    "free models"
  );
  await expect(panel).toContainText("Saved. New Router calls use this policy.");
  await expect(saveBar).toHaveCount(0);
  expect(writes.at(-1)).toMatchObject({
    method: "PUT",
    path: "/v1/comma/admin/billing/free-router-models",
    body: {
      models: [{ provider: "openai", sku: "gpt-5.6-luna" }],
      revision: 0,
      reason: "Offer free Router calls",
      confirmation: "update-free-router-models:comma",
    },
  });
  await page.reload();
  await panel.getByRole("button", { name: "Remove gpt-5.6-luna" }).click();
  await expect(saveBar).toContainText("1 unsaved change");
  await saveBar.getByRole("button", { name: "Discard" }).click();
  await expect(
    panel.getByRole("button", { name: "Remove gpt-5.6-luna" })
  ).toBeVisible();
  await panel.getByRole("button", { name: "Remove gpt-5.6-luna" }).click();
  await saveBar.getByRole("button", { name: "Save free Router models…" }).click();
  await confirmCommand(
    page,
    "Save free Router models?",
    "End free Router offer",
    "free models"
  );
  expect(writes.at(-1)).toMatchObject({ body: { models: [], revision: 1 } });
  await page.getByRole("button", { name: "Reload", exact: true }).click();
  await expect(panel.getByText("No models are free under this policy.")).toBeVisible();
});

test("Guest mode creates a guest tenant, then enables and persists the policy", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes,
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Guest mode", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Guest mode", level: 1 })
  ).toBeVisible();
  const tenant = page.getByRole("region", { name: "Guest tenant" });
  const policy = page.getByRole("region", { name: "Guest mode policy" });
  await expect(tenant).toContainText("None. Create a guest tenant");
  await expect(tenant).toContainText("7 of 100");

  await tenant.getByRole("button", { name: "Create new guest tenant" }).click();
  await expect(
    page.getByRole("dialog", { name: "Create new guest tenant?" })
  ).toContainText("Existing guest workspaces stay in their current tenant.");
  await confirmCommand(
    page,
    "Create new guest tenant?",
    "Start guest trials",
    "guest mode"
  );
  await expect(tenant.getByText("tenant_guest_e2e_1")).toBeVisible();
  expect(writes.at(-1)).toMatchObject({
    method: "POST",
    path: "/v1/comma/admin/guest-mode/tenant",
    body: {
      revision: 0,
      reason: "Start guest trials",
      confirmation: "create-guest-tenant:comma",
    },
  });

  await policy.getByRole("switch", { name: /Guest mode enabled/ }).press("Space");
  await policy
    .getByRole("spinbutton", { name: "Tenant concurrency per node" })
    .fill("12");
  await policy
    .getByRole("spinbutton", { name: "Guest session lifetime (days)" })
    .fill("3");
  await policy
    .getByRole("spinbutton", { name: "Proof-of-work difficulty (bits)" })
    .fill("16");
  const saveBar = page.getByRole("region", { name: "Unsaved changes" });
  await expect(saveBar).toContainText("4 unsaved changes");
  await saveBar.getByRole("button", { name: "Save guest mode…" }).click();
  const review = page.getByRole("dialog", { name: "Save guest mode?" });
  await expect(review).toContainText("Tenant concurrency per node");
  await expect(review).toContainText("3 days");
  await review.getByRole("textbox", { name: "Reason" }).fill("Open guest trials");
  await review.getByRole("button", { name: "Confirm" }).click();
  await expect(review.getByRole("alert")).toHaveText(
    "The confirmation does not match this target."
  );
  await confirmCommand(page, "Save guest mode?", "Open guest trials", "guest mode");
  await expect(saveBar).toHaveCount(0);
  await expect(
    page.getByText("Saved. New guest sessions use these settings.")
  ).toBeVisible();
  expect(writes.at(-1)).toMatchObject({
    method: "PUT",
    path: "/v1/comma/admin/guest-mode",
    body: {
      enabled: true,
      daily_creation_limit: 100,
      tenant_concurrency: 12,
      session_ttl_seconds: 259_200,
      pow_difficulty: 16,
      revision: 1,
      reason: "Open guest trials",
      confirmation: "update-guest-policy:comma",
    },
  });

  await page.reload();
  await expect(
    policy.getByRole("switch", { name: /Guest mode enabled/ })
  ).toBeChecked();
  await expect(
    policy.getByRole("spinbutton", { name: "Tenant concurrency per node" })
  ).toHaveValue("12");
  await expect(
    policy.getByRole("spinbutton", { name: "Proof-of-work difficulty (bits)" })
  ).toHaveValue("16");
  await policy.getByRole("button", { name: "Open Free Router models" }).click();
  await expect(
    page.getByRole("region", { name: "Free Router models", exact: true })
  ).toBeVisible();
});

test("dashboard navigation is reflected in the URL and browser history", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();

  await page.getByRole("button", { name: "Redeem codes", exact: true }).click();
  await expect(page).toHaveURL(/\/\?section=billing$/);
  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeVisible();

  await page.getByRole("button", { name: "Compute nodes" }).click();
  await page.getByRole("textbox", { name: "Tenant ID" }).fill("tenant-e2e");
  await page.getByRole("button", { name: "Load tenant" }).click();
  await page.getByRole("button", { name: "Open compute node host-e2e" }).click();
  await expect(page).toHaveURL(
    /\?section=compute&tenant=tenant-e2e&registration=registration-e2e$/
  );

  await page.reload();
  await expect(page.getByRole("dialog", { name: "host-e2e" })).toBeVisible();
  await page
    .getByRole("dialog", { name: "host-e2e" })
    .getByRole("button", { name: "Close", exact: true })
    .click();
  await expect(page).toHaveURL(/\?section=compute&tenant=tenant-e2e$/);

  await page.goBack();
  await expect(page).toHaveURL(/\/\?section=billing$/);
  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Redeem codes", exact: true })
  ).toHaveAttribute("aria-current", "page");

  await page.goBack();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();

  await page.goForward();
  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeVisible();
});

test("a long Free Router models list scrolls while the save bar stays in view", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    freeRouterModels: Array.from({ length: 80 }, (_, index) => ({
      provider: "openai",
      sku: `gpt-e2e-model-with-a-long-name-${index}`,
    })),
    writes: [],
  });
  await page.setViewportSize({ width: 1280, height: 600 });
  await page.goto("/?section=free-models");

  const panel = page.getByRole("region", { name: "Free Router models", exact: true });
  const last = panel.getByRole("button", {
    name: "Remove gpt-e2e-model-with-a-long-name-79",
  });
  await last.scrollIntoViewIfNeeded();
  await last.click();
  const saveBar = page.getByRole("region", { name: "Unsaved changes" });
  await expect(saveBar).toBeInViewport();
  await expect(
    page.getByRole("heading", { name: "Free Router models", level: 1 })
  ).toBeInViewport();
});

test("compute nodes remain usable on narrow screens and support audited actions", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Compute nodes" }).click();
  await page.getByRole("textbox", { name: "Tenant ID" }).fill("tenant-e2e");
  await page.getByRole("button", { name: "Load tenant" }).click();
  await expect(
    page.getByRole("heading", { name: "Compute nodes", level: 1 })
  ).toBeVisible();
  const computeNode = page.getByRole("button", { name: "Open compute node host-e2e" });
  await expect(computeNode).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(computeNode).toBeVisible();
  const nodeBounds = await computeNode.boundingBox();
  expect(nodeBounds).not.toBeNull();
  expect(nodeBounds!.x).toBeGreaterThanOrEqual(0);
  expect(nodeBounds!.x + nodeBounds!.width).toBeLessThanOrEqual(390);
  await expect(computeNode.getByText("View details →")).toBeVisible();
  await page.setViewportSize({ width: 1280, height: 800 });
  await computeNode.click();
  const drawer = page.getByRole("dialog", { name: "host-e2e" });
  await expect(drawer).toContainText("observation_stale");
  await expect(drawer).toContainText(
    "512 PID limit, 2 GiB writable disk limit, no network access."
  );
  await drawer
    .getByRole("button", { name: "Create Shell workload", exact: true })
    .click();
  await confirmCommand(
    page,
    "Create Shell workload",
    "Create an isolated shell for validation"
  );
  await expect(page.getByText(/was accepted/)).toBeVisible();
  await drawer.getByRole("button", { name: "Disable / drain" }).click();
  await confirmCommand(
    page,
    "Disable and drain registration",
    "Drain for planned maintenance"
  );
  await expect(page.getByText(/was accepted/)).toBeVisible();
  await drawer.getByRole("button", { name: "Close", exact: true }).click();
});

test("the standalone dashboard runs audited User and Billing operations", async ({
  page,
}) => {
  const adminRequestHeaders: Array<Record<string, string>> = [];
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders,
    forbidden: false,
    writes,
  });

  await page.goto("/");

  await expect(page).toHaveTitle(/Comma Admin/);
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();
  await expect(page.getByRole("button", { name: "Sign out" })).toHaveCount(0);
  const accountTrigger = page.getByRole("button", {
    name: `Account menu for ${adminSessionEmail}`,
  });
  const accountLayout = await accountTrigger
    .locator(".admin-account-trigger-content")
    .evaluate((content) => {
      const children = Array.from(content.children).map((child) =>
        child.getBoundingClientRect()
      );
      const contentRect = content.getBoundingClientRect();
      const triggerRect = content.parentElement?.parentElement?.getBoundingClientRect();
      return {
        centers: children.map((rect) => rect.top + rect.height / 2),
        chevronGap: contentRect.right - (children.at(-1)?.right ?? 0),
        verticalSpace: (triggerRect?.height ?? 0) - contentRect.height,
      };
    });
  expect(
    Math.max(...accountLayout.centers) - Math.min(...accountLayout.centers)
  ).toBeLessThan(2);
  expect(accountLayout.chevronGap).toBeLessThan(2);
  expect(accountLayout.verticalSpace).toBeGreaterThanOrEqual(12);
  const emailOverflow = await accountTrigger.locator("strong").evaluate((element) => ({
    clientWidth: element.clientWidth,
    scrollWidth: element.scrollWidth,
  }));
  expect(emailOverflow.scrollWidth).toBeGreaterThan(emailOverflow.clientWidth);
  await accountTrigger.click();
  await expect(page.getByRole("menuitem", { name: "Sign out" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("link", { name: "Comma product" })).toHaveAttribute(
    "target",
    "_blank"
  );
  await expect(page.getByRole("region", { name: "Admin summary" })).toHaveCount(0);
  const usersTable = page.getByRole("table", { name: "Comma users" });
  await expect(usersTable).toContainText("owner@example.com");
  await expect(usersTable).toContainText("Email OTP");
  await expect(usersTable).toContainText("Google");
  let drawer: Locator;

  await page.getByRole("button", { name: "Audit log" }).click();
  await expect(
    page.getByRole("heading", { name: "Audit log", level: 1 })
  ).toBeVisible();
  const auditTable = page.getByRole("table", { name: "Admin audit events" });
  await expect(auditTable).toContainText("Update user");
  await expect(auditTable).toContainText("owner@example.com");
  await auditTable.getByRole("button", { name: "View audit event" }).click();
  drawer = page.getByRole("dialog", { name: "Update user" });
  await expect(drawer).toContainText("Correct an approved account name");
  await expect(drawer).toContainText("usr_person_e2e");
  await expect(drawer).not.toContainText("request_fingerprint");
  await drawer.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Users" }).click();

  // A row opens the account's page, kept in the URL; the browser's Back returns to the list.
  await usersTable.getByRole("button", { name: "Open owner@example.com" }).click();
  await expect(page).toHaveURL(/\?user=usr_admin_e2e$/);
  const userPage = page.getByTestId("admin-user-page");
  await expect(
    userPage.getByRole("heading", { name: "owner@example.com", level: 1 })
  ).toBeVisible();
  await expect(userPage).toContainText("owner@gmail.com");
  await page.goBack();
  await expect(usersTable).toContainText("owner@example.com");

  await page.getByRole("button", { name: "New user" }).click();
  drawer = page.getByRole("dialog", { name: "New user" });
  await drawer.getByRole("textbox", { name: "Email" }).fill("person@example.com");
  await drawer.getByRole("textbox", { name: "Display name" }).fill("Person");
  await drawer.getByLabel("Admin access").selectOption("allow");
  await drawer.getByRole("button", { name: "Create user…" }).click();
  // Granting Admin access is guarded: the operator types the account's email.
  await confirmCommand(
    page,
    "Create this user?",
    "Create an approved support-managed account",
    "person@example.com"
  );

  await expect(page).toHaveURL(/\?user=usr_person_e2e$/);
  await expect(
    userPage.getByRole("heading", { name: "person@example.com", level: 1 })
  ).toBeVisible();
  await expect(userPage).toContainText("Explicit allow");
  await expect(userPage).toContainText("Email OTP");
  await expect(userPage).toContainText("Google not linked");

  const openAction = async (name: string) => {
    await userPage.getByRole("button", { name: "More account actions" }).click();
    await page.getByRole("menuitem", { name }).click();
  };

  await openAction("Edit account");
  drawer = page.getByRole("dialog", { name: "Edit account" });
  await drawer.getByRole("textbox", { name: "Display name" }).fill("Person Updated");
  await drawer.getByRole("button", { name: "Continue…" }).click();
  await expect(page.getByRole("dialog", { name: "Edit account?" })).toContainText(
    "Person Updated"
  );
  await confirmCommand(page, "Edit account?", "Correct the display name");
  await expect(drawer).toHaveCount(0);
  await expect(userPage).toContainText("Updated person@example.com.");

  await openAction("Change Admin access");
  await page
    .getByRole("dialog", { name: "Change Admin access" })
    .getByRole("button", { name: "Continue…" })
    .click();
  await confirmCommand(page, "Change Admin access?", "Remove temporary Admin access");
  await expect(userPage).toContainText("Explicit deny");

  await userPage.getByRole("tab", { name: "Sessions & devices" }).click();
  const sessions = userPage.getByTestId("admin-user-sessions");
  await expect(sessions.getByText("Web on macOS")).toBeVisible();
  await expect(sessions.getByText("Comma Desktop on Windows")).toBeVisible();
  await expect(sessions.getByText(/Reported Web · Email OTP/)).toBeVisible();
  await expect(sessions.getByText("Comma SSH", { exact: true })).toBeVisible();
  await expect(sessions.getByText(/Reported SSH · SSH public key/)).toBeVisible();
  await expect(sessions.getByText("Comma Android app", { exact: true })).toBeVisible();
  await expect(sessions.getByText(/Reported Android · Google/)).toBeVisible();

  const webSessionCard = sessions
    .locator("article.admin-session-card")
    .filter({ hasText: "Web on macOS" });
  await webSessionCard.getByRole("button", { name: "Revoke" }).click();
  await confirmCommand(page, "Revoke this Session?", "Remove a stale browser Session");
  await expect(sessions).toContainText("Revoked Web on macOS.");
  // The list shows active Sessions by default; the revoked one moves to its own filter.
  await expect(webSessionCard).toHaveCount(0);
  await sessions.getByRole("button", { name: /Filter by status/ }).click();
  await page.getByRole("option", { name: "Revoked" }).click();
  await expect(webSessionCard).toBeVisible();
  await expect(sessions.locator("article.admin-session-card")).toHaveCount(1);
  await expect(webSessionCard.getByRole("button", { name: "Revoke" })).toBeDisabled();
  await webSessionCard.getByText("Session details", { exact: true }).click();
  await expect(webSessionCard.getByText("sess_web_e2e", { exact: true })).toBeVisible();
  await sessions.getByRole("button", { name: /Filter by client/ }).click();
  await page.getByRole("option", { name: "Android" }).click();
  await expect(sessions.getByText("No matching Sessions")).toBeVisible();
  await sessions.getByRole("button", { name: "Show all Sessions" }).click();
  await expect(sessions.locator("article.admin-session-card")).toHaveCount(4);

  await sessions.getByRole("button", { name: "Revoke all" }).click();
  await confirmCommand(
    page,
    "Revoke all Sessions?",
    "End all remaining Sessions",
    "person@example.com"
  );
  await expect(sessions).toContainText("Revoked 3 active Sessions.");
  await userPage.getByRole("tab", { name: "Overview" }).click();

  await userPage.getByRole("button", { name: "Support session" }).click();
  await page
    .getByRole("dialog", { name: "Create support Session" })
    .getByRole("button", { name: "Continue…" })
    .click();
  await confirmCommand(
    page,
    "Create support Session?",
    "Investigate a reported account issue",
    "person@example.com"
  );
  await expect(userPage.getByText("comma_sess_support_e2e")).toBeVisible();
  // The account fails to reload after the command; the one-time token stays shown.
  await expect(
    userPage.getByRole("heading", { name: "Account couldn’t be loaded" })
  ).toBeVisible();
  expect(await localStorageSnapshot(page)).not.toContain("comma_sess_support_e2e");
  await userPage.getByRole("button", { name: "Done and clear" }).click();
  await expect(userPage.getByText("comma_sess_support_e2e")).toHaveCount(0);
  await userPage.getByRole("button", { name: "Retry" }).click();
  await expect(userPage).toContainText("No default Workspace");

  await userPage.getByRole("button", { name: "Ensure default Workspace" }).click();
  await page
    .getByRole("dialog", { name: "Ensure default Workspace" })
    .getByRole("button", { name: "Continue…" })
    .click();
  await confirmCommand(
    page,
    "Ensure default Workspace?",
    "Ensure the default Workspace exists"
  );
  await expect(userPage).toContainText("wsp_person_e2e");

  await expect(userPage).toContainText("Person Workspace");
  await expect(userPage).toContainText("Tenant ID");
  await expect(userPage).toContainText("tnt_person_e2e");
  await expect(userPage).toContainText("Agent group ID");
  await expect(userPage).toContainText("grp_person_e2e");
  await expect(userPage).toContainText("billing_person_e2e");
  await expect(userPage.getByRole("heading", { name: "Agent models" })).toBeVisible();
  await expect(userPage).toContainText("gpt-5.6-luna");
  await expect(userPage).toContainText("gpt-5.6-sol");
  const vmSection = userPage.getByRole("region", { name: "Cloud VM", exact: true });
  const vmSwitch = vmSection.getByRole("switch", { name: "Cloud VM" });
  await expect(vmSwitch).toBeChecked();
  // Cancelling the review leaves the saved setting.
  await vmSwitch.press("Space");
  await page
    .getByRole("dialog", { name: "Disable Cloud VM?" })
    .getByRole("button", { name: "Cancel" })
    .click();
  await expect(vmSwitch).toBeChecked();
  for (const setting of ["disabled", "enabled"]) {
    await vmSwitch.press("Space");
    await confirmCommand(
      page,
      setting === "enabled" ? "Enable Cloud VM?" : "Disable Cloud VM?",
      `Set shared VM ${setting}`
    );
    await expect(vmSection).toContainText("Cloud VM setting saved.");
    await expect(vmSection).toContainText("Pending");
    if (setting === "enabled") await expect(vmSwitch).toBeChecked();
    else await expect(vmSwitch).not.toBeChecked();
  }
  expect(
    writes
      .filter((write) => write.path.endsWith("/workspaces/wsp_person_e2e/vm"))
      .map((write) => write.body.enabled)
  ).toEqual([false, true]);

  await userPage.getByRole("button", { name: "Change Worker model" }).click();
  drawer = page.getByRole("dialog", { name: "Change Worker model" });
  const workerPicker = drawer.getByRole("combobox", { name: "Worker model" });
  await expect(workerPicker).toHaveValue("catalog:gpt-5.6-sol");
  await expect(drawer.locator('option[value="default"]')).toHaveText(
    "Platform default (GPT-5.6 Luna)"
  );
  await workerPicker.selectOption("default");
  await drawer.getByRole("button", { name: "Change model…" }).click();
  await expect(
    page.getByRole("dialog", { name: "Change Worker model?" })
  ).toContainText("Platform default (GPT-5.6 Luna)");
  await confirmCommand(
    page,
    "Change Worker model?",
    "Use the approved lower-latency Worker model"
  );
  await expect(drawer).toHaveCount(0);
  await expect(userPage).toContainText("Worker model changed to gpt-5.6-luna.");
  await expect(userPage).not.toContainText("gpt-5.6-sol");
  await expect(userPage).toContainText(
    "The Billing account does not belong to this Workspace."
  );
  await expect(
    userPage.getByRole("button", { name: "Apply redeem code" })
  ).toBeDisabled();
  await expect(userPage.getByRole("button", { name: "Issue credits" })).toBeDisabled();
  await userPage
    .getByRole("region", { name: "Workspace" })
    .getByRole("button", { name: "Refresh", exact: true })
    .click();
  await expect(userPage).toContainText("comma_monthly@v1");
  await expect(userPage.getByText("1,200")).toHaveCount(2);

  await userPage.getByRole("button", { name: "Issue credits" }).click();
  drawer = page.getByRole("dialog", { name: "Issue credits" });
  await expect(drawer).toContainText("Person Workspace");
  await expect(drawer).toContainText("100 credits");
  await drawer.getByRole("button", { name: "Issue credits…" }).click();
  await expect(
    page.getByRole("dialog", { name: "Issue these credits?" })
  ).toContainText("+100");
  await confirmCommand(
    page,
    "Issue these credits?",
    "Issue the approved direct Workspace credit"
  );
  await expect(drawer).toHaveCount(0);
  await expect(userPage).toContainText("Issued 100 credits.");
  await expect(userPage.getByText("1,300")).toBeVisible();

  await userPage.getByRole("button", { name: "Apply redeem code" }).click();

  drawer = page.getByRole("dialog", { name: "Apply redeem code" });
  await expect(drawer).toContainText("Person Workspace");
  await expect(drawer).toContainText("wsp_person_e2e");
  await expect(drawer).toContainText("billing_person_e2e");
  await expect(drawer.getByRole("textbox", { name: "Billing account ID" })).toHaveCount(
    0
  );
  await expect(drawer.getByRole("textbox", { name: "Owner ID" })).toHaveCount(0);
  await drawer.getByLabel("Active code").selectOption("code_e2e");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Apply this redeem code?",
    "Apply the approved Workspace credit"
  );

  drawer = page.getByRole("dialog", { name: "COMMA-INTERNAL" });
  await expect(
    drawer.getByRole("table", { name: "Redemptions for code" })
  ).toContainText("billing_person_e2e");

  await drawer.getByRole("button", { name: "Disable code" }).click();
  await confirmCommand(
    page,
    "Disable this redeem code?",
    "Retire the completed support code"
  );
  await expect(drawer).toContainText("Disabled");
  await drawer.getByRole("button", { name: "Close", exact: true }).click();

  await expect(page.getByRole("table", { name: "Redeem codes" })).toContainText(
    "COMMA-INTERNAL"
  );

  await page.getByRole("button", { name: "New code" }).click();
  drawer = page.getByRole("dialog", { name: "New redeem code" });
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Create this redeem code?",
    "Issue an approved support credit"
  );

  drawer = page.getByRole("dialog", { name: "Code created" });
  await expect(drawer.getByText("COMMA-NEW-ONE-TIME")).toBeVisible();
  expect(await localStorageSnapshot(page)).not.toContain("COMMA-NEW-ONE-TIME");
  await drawer.getByRole("button", { name: "Done and clear" }).click();

  expect(adminRequestHeaders.length).toBeGreaterThan(0);
  for (const headers of adminRequestHeaders) {
    expect(headers["x-comma-expected-auth-session-id"]).toBe(sessionId);
    expect(headers["x-comma-session-lifecycle-version"]).toBe("1");
    expect(headers["x-comma-session-transport"]).toBe("cookie");
    expect(headers.authorization).toBeUndefined();
  }

  expect(writes.map((write) => write.method)).toEqual(
    expect.arrayContaining(["PATCH", "POST", "PUT"])
  );
  for (const write of writes) {
    expect(write.body.reason).toEqual(expect.any(String));
    expect(write.body.confirmation).toEqual(expect.any(String));
    expect(write.body.idempotency_key).toEqual(expect.any(String));
    expect(write.body.operator).toBeUndefined();
  }
  const creditWrite = writes.find((write) => write.path.endsWith("/workspace-credits"));
  expect(creditWrite?.body).toEqual(
    expect.objectContaining({
      package_code: "comma_monthly",
      package_version: "v1",
      reason: "Issue the approved direct Workspace credit",
    })
  );
  expect(creditWrite?.body.billing_account_id).toBeUndefined();
  expect(creditWrite?.body.workspace_id).toBeUndefined();
  const modelWrite = writes.find((write) =>
    write.path.endsWith("/workspaces/agent-models/worker")
  );
  expect(modelWrite?.body).toEqual(
    expect.objectContaining({
      confirmation: "workspace-agent-model:usr_person_e2e:worker:default",
      model: null,
      reason: "Use the approved lower-latency Worker model",
    })
  );
  expect(modelWrite?.body.agent_id).toBeUndefined();
  expect(modelWrite?.body.workspace_id).toBeUndefined();
  expect(modelWrite?.body.tenant_id).toBeUndefined();
  expect(modelWrite?.body.group_id).toBeUndefined();
});

test("a Workspace without a Worker shows and changes only its Router model", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    workerlessReadyWorkspaces: ["usr_admin_e2e"],
    writes: [],
  });

  await page.goto("/");

  const usersTable = page.getByRole("table", { name: "Comma users" });
  await usersTable.getByRole("button", { name: "Open owner@example.com" }).click();
  const userPage = page.getByTestId("admin-user-page");
  await expect(
    userPage.getByRole("heading", { name: "Agent models", exact: true })
  ).toBeVisible();
  await expect(userPage).toContainText("gpt-5.6-luna");
  await expect(userPage).not.toContainText("gpt-5.6-sol");
  await expect(
    userPage.getByRole("button", { name: "Change Router model" })
  ).toBeVisible();
  await expect(
    userPage.getByRole("button", { name: "Change Worker model" })
  ).toHaveCount(0);
});

test("the account menu switches the dashboard to Chinese and back", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();

  await page
    .getByRole("button", { name: `Account menu for ${adminSessionEmail}` })
    .click();
  await page.getByRole("menuitem", { name: "简体中文" }).click();
  await expect(page.getByRole("heading", { name: "用户", level: 1 })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");
  await expect(page.getByRole("button", { name: "访客模式" })).toBeVisible();

  await page.getByRole("button", { name: `${adminSessionEmail} 的账号菜单` }).click();
  await page.getByRole("menuitem", { name: "English" }).click();
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();
});

test("⌘K finds an account by email and opens its page", async ({ page }) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.goto("/?section=audit");
  await expect(
    page.getByRole("heading", { name: "Audit log", level: 1 })
  ).toBeVisible();

  await page.keyboard.press("ControlOrMeta+k");
  const search = page.getByRole("combobox", { name: "Search accounts" });
  await expect(search).toBeFocused();
  await search.fill("owner@");
  const result = page.getByRole("option", { name: /owner@example\.com/ });
  await expect(result).toBeVisible();
  await page.keyboard.press("Enter");

  await expect(page).toHaveURL(/\?user=usr_admin_e2e$/);
  await expect(
    page
      .getByTestId("admin-user-page")
      .getByRole("heading", { name: "owner@example.com", level: 1 })
  ).toBeVisible();

  // The sidebar opens the same search, and it also goes to sections.
  await page.getByRole("button", { name: "Search accounts" }).click();
  await page.getByRole("combobox", { name: "Search accounts" }).fill("guest");
  await page.getByRole("option", { name: "Guest mode" }).click();
  await expect(
    page.getByRole("heading", { name: "Guest mode", level: 1 })
  ).toBeVisible();
});

test("the overview shows sign-ups, guest usage and the latest operations", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Overview", exact: true }).click();
  await expect(page).toHaveURL(/\?section=overview$/);
  const overview = page.getByTestId("admin-overview");
  await expect(overview).toContainText("Registered accounts");
  await expect(overview).toContainText("100");
  await expect(overview).toContainText("Not counting 20 team accounts on comma.surf");
  // New in the last 7 days: 8 + 3 + 9 + 5 + 4 + 6 + 7.
  await expect(overview).toContainText("42");
  await expect(overview.getByRole("listitem")).toHaveCount(14);
  await expect(overview).toContainText("7 of 100");
  await expect(overview).toContainText("Update user");

  await overview.getByRole("button", { name: "Open account" }).click();
  await expect(page).toHaveURL(/\?user=usr_person_e2e$/);
});

test("Billing applies a code to an account found by email, not by typed ids", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    workerlessReadyWorkspaces: ["usr_admin_e2e"],
    writes,
  });
  await page.goto("/?section=billing");
  await page.getByRole("button", { name: "Apply code" }).click();
  const drawer = page.getByRole("dialog", { name: "Apply redeem code" });
  await expect(drawer.getByRole("textbox", { name: "Billing account ID" })).toHaveCount(
    0
  );
  await expect(drawer.getByRole("button", { name: "Review command" })).toBeDisabled();

  await drawer.getByRole("textbox", { name: "Account" }).fill("owner@");
  const owner = drawer.getByRole("button", { name: /owner@example\.com/ });
  // The first read of this account's billing finds it not yet matched to the Workspace.
  await owner.click();
  await expect(drawer.getByRole("alert")).toContainText("isn't ready");
  await owner.click();
  await expect(drawer).toContainText("wsp_person_e2e");
  await expect(drawer).toContainText("billing_person_e2e");

  await drawer.getByLabel("Active code").selectOption("code_e2e");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(page, "Apply this redeem code?", "Apply the approved credit");
  await expect(page.getByRole("dialog", { name: "COMMA-INTERNAL" })).toBeVisible();
  expect(writes.at(-1)?.body).toMatchObject({
    billing_account_id: "billing_person_e2e",
    product_owner_id: "wsp_person_e2e",
    product_owner_type: "workspace",
  });
});

test("the Audit log filters by action and operator, and a user page shows its own events", async ({
  page,
}) => {
  const auditQueries: string[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    auditQueries,
    forbidden: false,
    writes: [],
  });
  await page.goto("/?section=audit");
  const table = page.getByRole("table", { name: "Admin audit events" });
  await expect(table).toContainText("Update user");

  await page.getByRole("button", { name: /Filter by action/ }).click();
  await page.getByRole("option", { name: "Create user" }).click();
  await expect(page.getByText("No event matches these filters.")).toBeVisible();
  expect(auditQueries.at(-1)).toContain("action=create_user");

  await page.getByRole("button", { name: "Clear" }).click();
  await expect(table).toContainText("Update user");
  await page
    .getByRole("textbox", { name: "Filter by operator email" })
    .fill("owner@example.com");
  await page.keyboard.press("Enter");
  await expect(table).toContainText("Update user");
  expect(auditQueries.at(-1)).toContain("actor_email=owner%40example.com");

  await page.goto("/?user=usr_admin_e2e");
  const userPage = page.getByTestId("admin-user-page");
  await userPage.getByRole("tab", { name: "Activity" }).click();
  await expect(userPage.getByText("No audit events yet")).toBeVisible();
  expect(auditQueries.at(-1)).toContain("target_type=user");
  expect(auditQueries.at(-1)).toContain("target_id=usr_admin_e2e");
});

test("a server 403 replaces the dashboard and keeps sign-out reachable", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: true,
    writes: [],
  });

  await page.goto("/");

  await expect(
    page.getByRole("heading", { name: "Admin access required" })
  ).toBeVisible();
  await expect(
    page.getByRole("complementary", { name: "Admin navigation" })
  ).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Sign out" })).toBeVisible();
});

test("one-time secrets keep their drawers locked until the command settles", async ({
  page,
}) => {
  const supportResponse = Promise.withResolvers<void>();
  const redeemCodeResponse = Promise.withResolvers<void>();
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    createRedeemCodeGate: redeemCodeResponse.promise,
    forbidden: false,
    supportSessionGate: supportResponse.promise,
    writes: [],
  });

  await page.goto("/");

  const usersTable = page.getByRole("table", { name: "Comma users" });
  await usersTable.getByRole("button", { name: "Open owner@example.com" }).click();
  const userPage = page.getByTestId("admin-user-page");
  await userPage.getByRole("button", { name: "Support session" }).click();
  let drawer = page.getByRole("dialog", {
    name: "Create support Session",
    exact: true,
  });
  await drawer.getByRole("button", { name: "Continue…" }).click();

  let confirmation = page.getByRole("dialog", {
    name: "Create support Session?",
  });
  await confirmation
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify the pending support Session secret lifecycle");
  await confirmation
    .getByRole("textbox", { name: "Type “owner@example.com” to confirm" })
    .fill("owner@example.com");
  await confirmation.getByRole("button", { name: "Confirm" }).click();
  await expect(confirmation.getByRole("button", { name: "Working…" })).toBeVisible();
  await assertPendingSecretDrawerIsLocked(page, drawer, confirmation, "Redeem codes");

  supportResponse.resolve();
  await expect(confirmation).toHaveCount(0);
  await expect(drawer).toHaveCount(0);
  await expect(
    userPage.getByText("comma_sess_support_e2e", { exact: true })
  ).toHaveCount(1);
  expect(await localStorageSnapshot(page)).not.toContain("comma_sess_support_e2e");
  await userPage.getByRole("button", { name: "Done and clear" }).click();
  await expect(
    userPage.getByText("comma_sess_support_e2e", { exact: true })
  ).toHaveCount(0);

  await page.getByRole("button", { name: "Redeem codes" }).click();
  await page.getByRole("button", { name: "New code" }).click();
  drawer = page.getByRole("dialog", { name: "New redeem code" });
  await drawer.getByRole("button", { name: "Review command" }).click();

  confirmation = page.getByRole("dialog", {
    name: "Create this redeem code?",
  });
  await confirmation
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify the pending Redeem Code secret lifecycle");
  await confirmation.getByRole("button", { name: "Confirm" }).click();
  await expect(confirmation.getByRole("button", { name: "Working…" })).toBeVisible();
  await assertPendingSecretDrawerIsLocked(page, drawer, confirmation, "Users");

  redeemCodeResponse.resolve();
  await expect(confirmation).toHaveCount(0);
  drawer = page.getByRole("dialog", { name: "Code created" });
  await expect(drawer.getByText("COMMA-NEW-ONE-TIME", { exact: true })).toHaveCount(1);
  expect(await localStorageSnapshot(page)).not.toContain("COMMA-NEW-ONE-TIME");
  await drawer.getByRole("button", { name: "Done and clear" }).click();
  await expect(page.getByRole("dialog", { name: "Code created" })).toHaveCount(0);
  await expect(page.getByText("COMMA-NEW-ONE-TIME", { exact: true })).toHaveCount(0);
});

test("a command-scoped disabled 403 keeps the Admin shell available", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    supportSessionRejection: {
      error: "disabled",
      status: 403,
    },
    writes: [],
  });

  await page.goto("/");

  const usersTable = page.getByRole("table", { name: "Comma users" });
  await usersTable.getByRole("button", { name: "Open owner@example.com" }).click();
  await page
    .getByTestId("admin-user-page")
    .getByRole("button", { name: "Support session" })
    .click();
  const drawer = page.getByRole("dialog", {
    name: "Create support Session",
    exact: true,
  });
  await drawer.getByRole("button", { name: "Continue…" }).click();

  const confirmation = page.getByRole("dialog", {
    name: "Create support Session?",
  });
  await confirmation
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify a task-local command rejection");
  await confirmation
    .getByRole("textbox", { name: "Type “owner@example.com” to confirm" })
    .fill("owner@example.com");
  await confirmation.getByRole("button", { name: "Confirm" }).click();

  await expect(confirmation).toContainText("disabled");
  await expect(drawer).toBeVisible();
  await expect(page.getByTestId("admin-app")).toBeVisible();
  await expect(page.locator("aside.admin-sidebar")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Admin access required" })
  ).toHaveCount(0);

  await confirmation.getByRole("button", { name: "Cancel" }).click();
  await drawer.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Redeem codes" }).click();
  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeVisible();
});

test("OAuth client lifecycle keeps one-time secrets ephemeral", async ({ page }) => {
  const createResponse = Promise.withResolvers<void>();
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    createOauthClientGate: createResponse.promise,
    forbidden: false,
    writes,
  });

  await page.goto("/");
  await page.getByRole("button", { name: "OAuth clients" }).click();

  const clientsTable = page.getByRole("table", { name: "OAuth clients" });
  await expect(clientsTable).toContainText("Synchronicity");
  await expect(clientsTable).toContainText("Confidential");
  await expect(clientsTable).toContainText("Active");

  await page.getByRole("button", { name: "New client" }).click();
  let drawer = page.getByRole("dialog", { name: "New OAuth client" });
  await drawer.getByRole("textbox", { name: "Client name" }).fill("Support Portal");
  await drawer
    .getByRole("textbox", { name: "Redirect URIs" })
    .fill("https://support.example.com/oauth/callback");
  const clientType = drawer.getByLabel("Client type");
  await expect(clientType.getByRole("option", { name: "Public (PKCE)" })).toHaveCount(
    1
  );
  await clientType.selectOption("confidential");
  await drawer.getByRole("button", { name: "Review command" }).click();
  const createConfirmation = page.getByRole("dialog", {
    name: "Create this OAuth client?",
  });
  await createConfirmation
    .getByRole("textbox", { name: "Reason" })
    .fill("Register the approved support portal");
  await createConfirmation.getByRole("button", { name: "Confirm" }).click();
  await expect(
    createConfirmation.getByRole("button", { name: "Working…" })
  ).toBeVisible();
  await assertPendingSecretDrawerIsLocked(page, drawer, createConfirmation, "Users");
  createResponse.resolve();
  await expect(createConfirmation).toHaveCount(0);

  drawer = page.getByRole("dialog", { name: "Client secret created" });
  await expect(
    drawer.getByText("oauth-created-secret-e2e", { exact: true })
  ).toBeVisible();
  await expect(drawer).toContainText("oauth_support_e2e");
  expect(await localStorageSnapshot(page)).not.toContain("oauth-created-secret-e2e");
  await drawer.getByRole("button", { name: "Done and clear" }).click();
  await expect(page.getByText("oauth-created-secret-e2e", { exact: true })).toHaveCount(
    0
  );
  await expect(clientsTable).toContainText("Support Portal");

  await page.getByRole("button", { name: "New client" }).click();
  drawer = page.getByRole("dialog", { name: "New OAuth client" });
  await drawer.getByRole("textbox", { name: "Client name" }).fill("Native Helper");
  await drawer
    .getByRole("textbox", { name: "Redirect URIs" })
    .fill("http://127.0.0.1:4812/callback");
  await drawer.getByLabel("Client type").selectOption("public");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Create this OAuth client?",
    "Register the approved native helper"
  );
  drawer = page.getByRole("dialog", { name: "Client created" });
  await expect(drawer).toContainText("Public (PKCE)");
  await expect(drawer).toContainText("has no client secret");
  await drawer.getByRole("button", { name: "Done" }).click();
  await expect(clientsTable).toContainText("Native Helper");

  await clientsTable
    .getByRole("row", { name: /Synchronicity/ })
    .getByRole("button", { name: "Manage" })
    .click();
  drawer = page.getByRole("dialog", { name: "Manage OAuth client" });
  await expect(drawer).toContainText("https://sync.example.com/auth/callback/oidc");
  await drawer.getByRole("button", { name: "Rotate secret" }).click();
  await confirmCommand(
    page,
    "Rotate this client secret?",
    "Rotate the bootstrap credential before handoff",
    "Synchronicity"
  );

  drawer = page.getByRole("dialog", { name: "Client secret rotated" });
  await expect(
    drawer.getByText("oauth-rotated-secret-e2e", { exact: true })
  ).toBeVisible();
  expect(await localStorageSnapshot(page)).not.toContain("oauth-rotated-secret-e2e");
  await drawer.getByRole("button", { name: "Done and clear" }).click();

  drawer = page.getByRole("dialog", { name: "Manage OAuth client" });
  await drawer.getByRole("button", { name: "Disable client" }).click();
  await confirmCommand(
    page,
    "Disable this OAuth client?",
    "Disable the integration during credential rollout",
    "Synchronicity"
  );
  await expect(drawer).toContainText("Disabled");

  await drawer.getByRole("button", { name: "Enable client" }).click();
  await confirmCommand(
    page,
    "Enable this OAuth client?",
    "Restore the integration after credential rollout"
  );
  await expect(drawer).toContainText("Active");

  const oauthWrites = writes.filter((write) =>
    write.path.startsWith("/v1/comma/admin/oauth-clients")
  );
  expect(oauthWrites.map((write) => `${write.method} ${write.path}`)).toEqual([
    "POST /v1/comma/admin/oauth-clients",
    "POST /v1/comma/admin/oauth-clients",
    "POST /v1/comma/admin/oauth-clients/oauth_sync_e2e/rotate-secret",
    "POST /v1/comma/admin/oauth-clients/oauth_sync_e2e/disable",
    "POST /v1/comma/admin/oauth-clients/oauth_sync_e2e/enable",
  ]);
  for (const write of oauthWrites) {
    expect(write.body.reason).toEqual(expect.any(String));
    expect(write.body.confirmation).toEqual(expect.any(String));
    expect(write.body.idempotency_key).toEqual(expect.any(String));
  }
});

test("a signed-out startup asks for the Session once and shows sign-in", async ({
  page,
}) => {
  let sessionProbeCount = 0;

  await page.route(`${apiBaseUrl}/v1/**`, async (route) => {
    const request = route.request();
    const headers = corsHeaders(route);
    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }
    if (
      request.method() === "GET" &&
      new URL(request.url()).pathname === "/v1/comma/auth/session"
    ) {
      sessionProbeCount += 1;
      await fulfillJson(route, { error: "unauthorized" }, 401, headers);
      return;
    }
    await fulfillJson(route, { error: "unexpected_request" }, 500, headers);
  });

  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Comma can’t continue" })).toHaveCount(
    0
  );
  expect(sessionProbeCount).toBe(1);
});

test("signs in with an emailed code and opens the dashboard", async ({ page }) => {
  let signedIn = false;
  const signIns: Array<{ body: unknown; expected: string | undefined; path: string }> =
    [];
  const session = {
    expires_at: 4_102_444_800,
    session_id: sessionId,
    user: { email: adminSessionEmail, id: "usr_admin_e2e", status: "active" },
  };
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
    async sessionProbe(route, headers) {
      await fulfillJson(
        route,
        signedIn ? session : { error: "unauthorized" },
        signedIn ? 200 : 401,
        headers
      );
    },
  });
  await page.route(`${apiBaseUrl}/v1/comma/auth/**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (request.method() === "OPTIONS" || path === "/v1/comma/auth/session") {
      await route.fallback();
      return;
    }
    const headers = corsHeaders(route);
    signIns.push({
      body: request.postDataJSON() as unknown,
      expected: request.headers()["x-comma-expected-auth-session-id"],
      path,
    });
    if (path === "/v1/comma/auth/email/login") {
      await fulfillJson(route, { challenge_id: "challenge_e2e" }, 200, headers);
      return;
    }
    if (path === "/v1/comma/auth/email/verify") {
      signedIn = true;
      await fulfillJson(route, session, 200, headers);
      return;
    }
    await fulfillJson(route, { error: "google_unavailable" }, 503, headers);
  });

  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();
  await page.getByLabel("Email", { exact: true }).fill(adminSessionEmail);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByRole("heading", { name: "Check your email" })).toBeVisible();
  await page.getByLabel("Verification code").fill("123456");
  await page.getByRole("button", { name: "Verify code" }).click();

  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();
  await expect(
    page.getByRole("button", { name: `Account menu for ${adminSessionEmail}` })
  ).toBeVisible();
  expect(signIns.filter((request) => request.path.includes("/email/"))).toEqual([
    {
      body: { email: adminSessionEmail },
      expected: "none",
      path: "/v1/comma/auth/email/login",
    },
    {
      body: expect.objectContaining({
        challenge_id: "challenge_e2e",
        client_kind: "web",
        code: "123456",
      }),
      expected: "none",
      path: "/v1/comma/auth/email/verify",
    },
  ]);
});

test("a product 409 adopts the changed Cookie Session without an error screen", async ({
  page,
}) => {
  const originalSessionId = "22222222-2222-4222-8222-222222222222";
  const replacementSessionId = "33333333-3333-4333-8333-333333333333";
  const expectedSessionIds: Array<string | undefined> = [];
  let activeSessionId = originalSessionId;

  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
    async sessionProbe(route, headers) {
      const expectedSessionId = route.request().headers()[
        "x-comma-expected-auth-session-id"
      ];
      expectedSessionIds.push(expectedSessionId);

      if (
        expectedSessionId !== "none" &&
        expectedSessionId !== "unknown" &&
        expectedSessionId !== activeSessionId
      ) {
        await fulfillJson(route, { error: "session_changed" }, 409, headers);
        return;
      }

      await fulfillJson(
        route,
        {
          expires_at: 4_102_444_800,
          session_id: activeSessionId,
          user: {
            email: adminSessionEmail,
            id: "usr_admin_e2e",
            status: "active",
          },
        },
        200,
        headers
      );
    },
  });

  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Users", level: 1 })).toBeVisible();
  expect(expectedSessionIds.at(-1)).toBe("unknown");

  // Focus no longer probes the Session; only product responses and peer hints do.
  const probesBeforeFocus = expectedSessionIds.length;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  // Give a regressed focus probe time to reach the route before asserting none ran.
  await page.waitForTimeout(250);

  // Another tab moved the shared Cookie: admin reads for the old Session get 409.
  activeSessionId = replacementSessionId;
  const adminSessionIds: Array<string | undefined> = [];
  await page.route(`${apiBaseUrl}/v1/comma/admin/**`, async (route) => {
    const expectedSessionId = route.request().headers()[
      "x-comma-expected-auth-session-id"
    ];
    adminSessionIds.push(expectedSessionId);
    if (
      route.request().method() !== "OPTIONS" &&
      expectedSessionId !== activeSessionId
    ) {
      await fulfillJson(route, { error: "session_changed" }, 409, corsHeaders(route));
      return;
    }
    await route.fallback();
  });
  expect(expectedSessionIds.length).toBe(probesBeforeFocus);

  await page.getByRole("button", { name: "Redeem codes", exact: true }).click();

  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Comma can’t continue" })).toHaveCount(
    0
  );
  expect(adminSessionIds).toContain(originalSessionId);
  // The 409 triggers a check of the old Session, then a rebind to the Cookie's.
  await expect
    .poll(() => {
      const probes = expectedSessionIds.slice(probesBeforeFocus);
      return probes.includes(originalSessionId) && probes.at(-1) === "unknown";
    })
    .toBe(true);
  await expect.poll(() => adminSessionIds.at(-1)).toBe(replacementSessionId);
  await expect(page.getByRole("heading", { name: "Comma can’t continue" })).toHaveCount(
    0
  );
});

interface AdminWrite {
  body: Record<string, unknown>;
  method: string;
  path: string;
}

interface UserRecord {
  review_login_configured?: boolean;
  admin_access: {
    allowed: boolean;
    decision: "allow" | "deny" | null;
    source: "disabled" | "domain_default" | "explicit_allow" | "explicit_deny" | "none";
  };
  created_at: number;
  email: string;
  id: string;
  login_methods: Array<
    | { email: string; method: "email_otp" | "review_code" }
    | {
        email_snapshot: string;
        email_verified: boolean;
        last_authenticated_at: number;
        linked_at: number;
        method: "google";
      }
  >;
  name: string;
  status: string;
  updated_at: number;
}

interface CodeRecord {
  code_type: string;
  display_prefix: string;
  id: string;
  package_code: string;
  package_version: string;
  status: string;
}

interface OauthClientRecord {
  confidential: boolean;
  created_at: string;
  disabled_at: string | null;
  id: string;
  name: string;
  redirect_uris: string[];
}

interface SessionRecord {
  authenticated_at: number | null;
  auth_method: "email_otp" | "google" | "ssh_public_key" | null;
  client_kind: "android" | "api" | "electron" | "web" | "ssh" | null;
  device_label: string | null;
  expires_at: number;
  id: string;
  last_seen_at: number | null;
  restricted: boolean;
  revoked_at: number | null;
  session_source: "ops_api" | "user_login";
}

async function installSignedInAdmin(
  page: Page,
  options: {
    adminRequestHeaders: Array<Record<string, string>>;
    /** Receives the query string of each Audit log read. */
    auditQueries?: string[];
    createOauthClientGate?: Promise<void>;
    createRedeemCodeGate?: Promise<void>;
    forbidden: boolean;
    freeRouterModels?: Array<{ provider: string; sku: string }>;
    sessionProbe?: (route: Route, headers: Record<string, string>) => Promise<void>;
    supportSessionGate?: Promise<void>;
    // Users whose default Workspace is already ready and has no Worker.
    workerlessReadyWorkspaces?: string[];
    supportSessionRejection?: {
      error: string;
      status: number;
    };
    writes: AdminWrite[];
  }
) {
  const users: UserRecord[] = [
    {
      admin_access: {
        allowed: true,
        decision: null,
        source: "domain_default",
      },
      created_at: 1_784_880_000,
      email: "owner@example.com",
      id: "usr_admin_e2e",
      login_methods: [
        { email: "owner@example.com", method: "email_otp" },
        {
          email_snapshot: "owner@gmail.com",
          email_verified: true,
          last_authenticated_at: 1_784_880_500,
          linked_at: 1_784_880_000,
          method: "google",
        },
      ],
      name: "Comma Owner",
      status: "active",
      updated_at: 1_784_880_500,
    },
  ];
  const codes: CodeRecord[] = [
    {
      code_type: "one_time_package",
      display_prefix: "COMMA-INTERNAL",
      id: "code_e2e",
      package_code: "comma_monthly",
      package_version: "v1",
      status: "active",
    },
  ];
  const oauthClients: OauthClientRecord[] = [
    {
      confidential: true,
      created_at: "2026-09-01T10:00:00Z",
      disabled_at: null,
      id: "oauth_sync_e2e",
      name: "Synchronicity",
      redirect_uris: ["https://sync.example.com/auth/callback/oidc"],
    },
  ];
  const auditQueries: string[] = options.auditQueries ?? [];
  const auditEvents = [
    {
      id: "audit_e2e",
      action: "update_user",
      outcome: "succeeded",
      actor: {
        type: "comma_user",
        user_id: "usr_admin_e2e",
        email: "owner@example.com",
      },
      target: { type: "user", id: "usr_person_e2e" },
      reason: "Correct an approved account name",
      error_code: null,
      created_at: 1_784_881_300,
      updated_at: 1_784_881_301,
    },
  ];
  const redemptions = new Map<string, Array<Record<string, unknown>>>([
    [
      "code_e2e",
      [
        {
          billing_account_id: "billing_e2e",
          id: "redemption_e2e",
          product_owner_id: "workspace_e2e",
          product_owner_type: "workspace",
          redeem_code_id: "code_e2e",
          source_type: "redeem_code",
          status: "applied",
        },
      ],
    ],
  ]);
  const readyWorkspaces = new Set<string>(options.workerlessReadyWorkspaces);
  const workerless = new Set<string>(options.workerlessReadyWorkspaces);
  const workspaceBillingReads = new Map<string, number>();
  let workspaceVmEnabled = true;
  const workspacePlatformModel = {
    name: "GPT-5.6 Luna",
    model: "gpt-5.6-luna",
    provider: "openai",
    scope: "global",
    reasoning_effort: null,
  };
  type WorkspaceAgentModel = {
    agent_id: string;
    role: "router" | "worker";
    source: "pinned" | "platform_default";
    model: string;
    provider: string;
    reasoning_effort: string | null;
    selection:
      | { kind: "builtin" }
      | { kind: "catalog"; model: string; reasoning_effort: string | null };
  };
  const followPlatform = (agent: WorkspaceAgentModel): WorkspaceAgentModel => ({
    ...agent,
    source: "platform_default",
    model: workspacePlatformModel.model,
    provider: workspacePlatformModel.provider,
    reasoning_effort: null,
    selection: { kind: "builtin" },
  });
  const workspaceAgentModels: Record<"router" | "worker", WorkspaceAgentModel> = {
    router: followPlatform({
      agent_id: "agent_router_e2e",
      role: "router",
    } as WorkspaceAgentModel),
    worker: {
      agent_id: "agent_worker_e2e",
      role: "worker",
      source: "pinned",
      model: "gpt-5.6-sol",
      provider: "openai",
      reasoning_effort: "high",
      selection: { kind: "catalog", model: "gpt-5.6-sol", reasoning_effort: "high" },
    },
  };
  let issuedWorkspaceCredits = 0;
  let failNextUserRead: string | undefined;
  const sessions = new Map<string, SessionRecord[]>([
    [
      "usr_person_e2e",
      [
        {
          authenticated_at: 1_784_881_100,
          auth_method: "email_otp",
          client_kind: "web",
          device_label: "Web on macOS",
          expires_at: 4_102_444_800,
          id: "sess_web_e2e",
          last_seen_at: 1_784_881_200,
          restricted: false,
          revoked_at: null,
          session_source: "user_login",
        },
        {
          authenticated_at: 1_784_881_000,
          auth_method: "email_otp",
          client_kind: "electron",
          device_label: "Comma Desktop on Windows",
          expires_at: 4_102_444_800,
          id: "sess_desktop_e2e",
          last_seen_at: 1_784_881_150,
          restricted: false,
          revoked_at: null,
          session_source: "user_login",
        },
        {
          authenticated_at: 1_784_881_000,
          auth_method: "ssh_public_key",
          client_kind: "ssh",
          device_label: null,
          expires_at: 4_102_444_800,
          id: "sess_ssh_e2e",
          last_seen_at: 1_784_881_150,
          restricted: false,
          revoked_at: null,
          session_source: "user_login",
        },
        {
          authenticated_at: 1_784_881_000,
          auth_method: "google",
          client_kind: "android",
          device_label: null,
          expires_at: 4_102_444_800,
          id: "sess_android_e2e",
          last_seen_at: 1_784_881_150,
          restricted: false,
          revoked_at: null,
          session_source: "user_login",
        },
      ],
    ],
  ]);

  await page.addInitScript(() => {
    localStorage.setItem("comma.apiBaseUrl", "https://salix.comma.surf");
    localStorage.removeItem("comma.sessionToken");
    localStorage.removeItem("comma.userEmail");
    localStorage.removeItem("comma.userAdmin");
  });

  await page.context().addCookies([
    {
      httpOnly: true,
      name: "comma_session",
      sameSite: "Lax",
      secure: false,
      url: apiBaseUrl,
      value: "comma_sess_admin_e2e",
    },
  ]);

  let freeRouterPolicy = {
    models: options.freeRouterModels ?? [],
    revision: 0,
  };
  let guestTenantCount = 0;
  let guestPolicy: {
    enabled: boolean;
    salix_tenant_id: string | null;
    daily_creation_limit: number;
    tenant_concurrency: number;
    session_ttl_seconds: number;
    pow_difficulty: number;
    revision: number;
    created_today: number;
  } = {
    enabled: false,
    salix_tenant_id: null,
    daily_creation_limit: 100,
    tenant_concurrency: 4,
    session_ttl_seconds: 86_400,
    pow_difficulty: 14,
    revision: 0,
    created_today: 7,
  };

  await page.route(`${apiBaseUrl}/v1/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = corsHeaders(route);
    const method = request.method();

    if (method === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }

    if (url.pathname.startsWith("/v1/comma/admin/")) {
      expect(request.url().startsWith(`${apiBaseUrl}/v1/comma/admin/`)).toBe(true);
      options.adminRequestHeaders.push(request.headers());
      if (options.forbidden) {
        await fulfillJson(route, { error: "forbidden" }, 403, headers);
        return;
      }
      if (method !== "GET") {
        options.writes.push({
          body: request.postDataJSON() as Record<string, unknown>,
          method,
          path: url.pathname,
        });
      }
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/auth/session") {
      if (options.sessionProbe) {
        await options.sessionProbe(route, headers);
        return;
      }

      await fulfillJson(
        route,
        {
          expires_at: 4_102_444_800,
          session_id: sessionId,
          user: {
            email: adminSessionEmail,
            id: "usr_admin_e2e",
            status: "active",
          },
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/audit-events") {
      const action = url.searchParams.get("action");
      const actor = url.searchParams.get("actor_email");
      const targetId = url.searchParams.get("target_id");
      auditQueries.push(url.search);
      await fulfillJson(
        route,
        {
          data: auditEvents.filter(
            (event) =>
              (!action || event.action === action) &&
              (!actor || event.actor.email === actor) &&
              (!targetId || event.target.id === targetId)
          ),
          has_more: false,
          next_cursor: null,
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/lookup") {
      const query = (url.searchParams.get("q") ?? "").trim().toLowerCase();
      const data = users
        .filter((user) => user.email.startsWith(query) || user.id === query)
        .map((user) => ({
          match: user.id === query ? "user_id" : "email",
          user,
          workspace: null,
        }));
      await fulfillJson(route, { data }, 200, headers);
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/stats/users") {
      await fulfillJson(
        route,
        {
          registered_total: 120,
          registered_team: 20,
          team_email_domain: "comma.surf",
          new_by_day: Array.from({ length: 14 }, (_, index) => ({
            date: `2026-10-${String(index + 1).padStart(2, "0")}`,
            count: [3, 5, 2, 0, 7, 4, 6, 8, 3, 9, 5, 4, 6, 7][index],
          })),
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/oauth-clients") {
      await fulfillJson(route, { data: oauthClients }, 200, headers);
      return;
    }

    if (`${method} ${url.pathname}` === "POST /v1/comma/admin/oauth-clients") {
      const body = request.postDataJSON() as {
        confidential: boolean;
        name: string;
        redirect_uris: string[];
      };
      const created: OauthClientRecord = {
        confidential: body.confidential,
        created_at: "2026-09-03T10:00:00Z",
        disabled_at: null,
        id: "oauth_support_e2e",
        name: body.name,
        redirect_uris: body.redirect_uris,
      };
      await options.createOauthClientGate;
      oauthClients.unshift(created);
      await fulfillJson(
        route,
        body.confidential
          ? { ...created, client_secret: "oauth-created-secret-e2e" }
          : created,
        201,
        headers
      );
      return;
    }

    const oauthLifecycleMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/oauth-clients\/([^/]+)\/(rotate-secret|disable|enable)$/
    );
    if (method === "POST" && oauthLifecycleMatch) {
      const client = oauthClients.find((entry) => entry.id === oauthLifecycleMatch[1])!;
      const action = oauthLifecycleMatch[2];
      if (action === "disable") client.disabled_at = "2026-09-03T10:05:00Z";
      if (action === "enable") client.disabled_at = null;
      await fulfillJson(
        route,
        action === "rotate-secret"
          ? { ...client, client_secret: "oauth-rotated-secret-e2e" }
          : client,
        200,
        headers
      );
      return;
    }

    if (
      `${method} ${url.pathname}` === "GET /v1/comma/admin/compute/agent-vmm/overview"
    ) {
      await fulfillJson(
        route,
        {
          total: 1,
          ready: 0,
          needs_attention: 1,
          disabled: 0,
          revoked: 0,
          enrolling: 0,
          draining: 0,
          disconnected_or_stale: 1,
          lease_expiring: 0,
          unknown_outcome: 0,
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/compute/agent-vmm/nodes") {
      await fulfillJson(
        route,
        { data: [agentVmmNode(false)], has_more: false, next_cursor: null },
        200,
        headers
      );
      return;
    }

    if (
      `${method} ${url.pathname}` ===
      "GET /v1/comma/admin/compute/agent-vmm/nodes/registration-e2e"
    ) {
      await fulfillJson(route, agentVmmNode(true), 200, headers);
      return;
    }

    if (
      `${method} ${url.pathname}` ===
      "POST /v1/comma/admin/compute/agent-vmm/commands/create_shell_workload/environment-e2e"
    ) {
      const body = route.request().postDataJSON();
      expect(body.tenant_id).toBe("tenant-e2e");
      expect(body.expected_revision).toBe(3);
      expect(body.reason).toBe("Create an isolated shell for validation");
      await fulfillJson(
        route,
        {
          accepted: true,
          action: "create_shell_workload",
          target: "environment:environment-e2e",
          result_revision: 3,
        },
        202,
        headers
      );
      return;
    }

    if (
      `${method} ${url.pathname}` ===
      "POST /v1/comma/admin/compute/agent-vmm/commands/disable_agent_vmm_registration/registration-e2e"
    ) {
      await fulfillJson(
        route,
        {
          accepted: true,
          action: "disable_agent_vmm_registration",
          target: "registration:registration-e2e",
          result_revision: 8,
        },
        202,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/users") {
      const search = url.searchParams.get("query")?.toLowerCase();
      await fulfillJson(
        route,
        {
          data: search
            ? users.filter((user) => user.email.toLowerCase().includes(search))
            : users,
          has_more: false,
          next_cursor: null,
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "POST /v1/comma/admin/users") {
      const body = request.postDataJSON() as Record<string, string>;
      const created: UserRecord = {
        admin_access: {
          allowed: body.admin_access === "allow",
          decision:
            body.admin_access === "allow" || body.admin_access === "deny"
              ? body.admin_access
              : null,
          source:
            body.admin_access === "allow"
              ? "explicit_allow"
              : body.admin_access === "deny"
                ? "explicit_deny"
                : "none",
        },
        created_at: 1_784_881_000,
        email: body.email ?? "",
        id: "usr_person_e2e",
        login_methods: [
          {
            email: body.email ?? "",
            method: "email_otp",
          },
        ],
        name: body.name ?? "",
        status: body.status || "active",
        updated_at: 1_784_881_000,
      };
      users.push(created);
      await fulfillJson(route, created, 201, headers);
      return;
    }

    const userMatch = url.pathname.match(/^\/v1\/comma\/admin\/users\/([^/]+)$/);
    if (userMatch) {
      const user = users.find((entry) => entry.id === userMatch[1]);
      if (!user) {
        await fulfillJson(route, { error: "not_found" }, 404, headers);
        return;
      }
      if (method === "GET" && failNextUserRead === user.id) {
        failNextUserRead = undefined;
        await fulfillJson(route, { error: "workspace_unavailable" }, 503, headers);
        return;
      }
      if (method === "PATCH") {
        const body = request.postDataJSON() as Record<string, string>;
        if ("review_login_code" in body) {
          if (
            body.review_login_code !== null &&
            user.admin_access.decision !== "deny"
          ) {
            await fulfillJson(
              route,
              { error: "review_login_requires_admin_denial" },
              400,
              headers
            );
            return;
          }
          user.review_login_configured = body.review_login_code !== null;
          user.login_methods[0] = {
            email: user.email,
            method: user.review_login_configured ? "review_code" : "email_otp",
          };
        }
        user.name = body.name ?? user.name;
        user.status = body.status ?? user.status;
        user.updated_at += 1;
      }
      await fulfillJson(route, user, 200, headers);
      return;
    }

    const accessMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/admin-access$/
    );
    if (method === "PUT" && accessMatch) {
      const user = users.find((entry) => entry.id === accessMatch[1])!;
      const body = request.postDataJSON() as { decision: "allow" | "deny" };
      user.admin_access = {
        allowed: body.decision === "allow",
        decision: body.decision,
        source: body.decision === "allow" ? "explicit_allow" : "explicit_deny",
      };
      await fulfillJson(route, user, 200, headers);
      return;
    }

    const sessionListMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/sessions$/
    );
    if (method === "GET" && sessionListMatch) {
      // The server filters and sorts before it pages; the cursor here is an offset.
      // A fixed time after every fixture's last use and before its expiry.
      const now = 1_784_890_000;
      const status = url.searchParams.get("status") ?? "all";
      const client = url.searchParams.get("client_kind") ?? "all";
      const sort = url.searchParams.get("sort") ?? "created_at";
      const rows = (sessions.get(sessionListMatch[1]!) ?? [])
        .filter((session) => {
          const value = session.revoked_at
            ? "revoked"
            : session.expires_at <= now
              ? "expired"
              : "active";
          return (
            (status === "all" || value === status) &&
            (client === "all" || (session.client_kind ?? "unknown") === client)
          );
        })
        .toSorted((a, b) =>
          sort === "last_seen_at"
            ? (b.last_seen_at ?? 0) - (a.last_seen_at ?? 0)
            : (b.authenticated_at ?? 0) - (a.authenticated_at ?? 0)
        );
      const offset = Number(url.searchParams.get("cursor") ?? 0);
      const limit = Number(url.searchParams.get("limit") ?? 50);
      const hasMore = offset + limit < rows.length;
      await fulfillJson(
        route,
        {
          data: rows.slice(offset, offset + limit),
          has_more: hasMore,
          next_cursor: hasMore ? String(offset + limit) : null,
        },
        200,
        headers
      );
      return;
    }

    const sessionRevokeMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/sessions\/([^/]+)\/revoke$/
    );
    if (method === "POST" && sessionRevokeMatch) {
      const session = (sessions.get(sessionRevokeMatch[1]!) ?? []).find(
        (entry) => entry.id === sessionRevokeMatch[2]!
      );
      if (!session) {
        await fulfillJson(route, { error: "not_found" }, 404, headers);
        return;
      }
      session.revoked_at ??= 1_784_881_300;
      await fulfillJson(route, { revoked: true, session_id: session.id }, 200, headers);
      return;
    }

    const sessionRevokeAllMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/sessions\/revoke-all$/
    );
    if (method === "POST" && sessionRevokeAllMatch) {
      let revokedCount = 0;
      for (const session of sessions.get(sessionRevokeAllMatch[1]!) ?? []) {
        if (session.revoked_at === null) {
          session.revoked_at = 1_784_881_400;
          revokedCount += 1;
        }
      }
      await fulfillJson(route, { revoked_count: revokedCount }, 200, headers);
      return;
    }

    const supportMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/support-sessions$/
    );
    if (method === "POST" && supportMatch) {
      const body = request.postDataJSON() as Record<string, unknown>;
      if (options.supportSessionRejection) {
        await fulfillJson(
          route,
          { error: options.supportSessionRejection.error },
          options.supportSessionRejection.status,
          headers
        );
        return;
      }
      await options.supportSessionGate;
      failNextUserRead = supportMatch[1]!;
      await fulfillJson(
        route,
        {
          expires_at: 4_102_444_800,
          id: "support_session_e2e",
          interaction_budget_remaining: body.budget,
          restricted: true,
          token: "comma_sess_support_e2e",
          tool_allowlist: [],
        },
        201,
        headers
      );
      return;
    }

    const workspaceMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/workspaces$/
    );
    if (method === "GET" && workspaceMatch) {
      const userId = workspaceMatch[1]!;

      if (!readyWorkspaces.has(userId)) {
        await fulfillJson(route, { workspace: null, billing: null }, 200, headers);
        return;
      }

      const completedReads = workspaceBillingReads.get(userId) ?? 0;
      workspaceBillingReads.set(userId, completedReads + 1);

      await fulfillJson(
        route,
        {
          workspace: {
            id: "wsp_person_e2e",
            name: "Person Workspace",
            status: "ready",
            tenant_id: "tnt_person_e2e",
            group_id: "grp_person_e2e",
            billing_account_id: "billing_person_e2e",
            cloud_vm: {
              workspace_id: "wsp_person_e2e",
              enabled: workspaceVmEnabled,
              convergence_status: "succeeded",
            },
            created_at: 1_784_881_000,
            updated_at: 1_784_881_500,
          },
          billing: {
            account_id: "billing_person_e2e",
            account_status: completedReads === 0 ? "identity_mismatch" : "active",
            current_credits: completedReads === 0 ? 0 : 1200 + issuedWorkspaceCredits,
            active_grants:
              completedReads === 0
                ? []
                : [
                    {
                      id: "grant_person_e2e",
                      package_code: "comma_monthly",
                      package_version: "v1",
                      remaining_credits: 1200,
                      valid_from: "2026-07-01T00:00:00Z",
                      expires_at: "2026-08-01T00:00:00Z",
                      source_type: "redeem_code",
                      source_id: "redemption_person_e2e",
                    },
                    ...(issuedWorkspaceCredits > 0
                      ? [
                          {
                            id: "grant_admin_e2e",
                            package_code: "comma_monthly",
                            package_version: "v1",
                            remaining_credits: issuedWorkspaceCredits,
                            valid_from: "2026-07-28T08:00:00Z",
                            expires_at: "2099-08-01T00:00:00Z",
                            source_type: "manual_adjustment",
                            source_id: "comma_admin:wsp_person_e2e",
                          },
                        ]
                      : []),
                  ],
            has_more: false,
          },
        },
        200,
        headers
      );
      return;
    }
    if (method === "POST" && workspaceMatch) {
      readyWorkspaces.add(workspaceMatch[1]!);
      await fulfillJson(
        route,
        {
          status: "ready",
          workspace: { id: "wsp_person_e2e", status: "ready" },
        },
        200,
        headers
      );
      return;
    }

    const workspaceAgentModelsMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/workspaces\/agent-models$/
    );
    if (method === "GET" && workspaceAgentModelsMatch) {
      if (!readyWorkspaces.has(workspaceAgentModelsMatch[1]!)) {
        await fulfillJson(route, { error: "workspace_unavailable" }, 503, headers);
        return;
      }

      await fulfillJson(
        route,
        {
          workspace_id: "wsp_person_e2e",
          response_metadata: { version: 2 },
          agents: workerless.has(workspaceAgentModelsMatch[1]!)
            ? { router: workspaceAgentModels.router, worker: null }
            : { ...workspaceAgentModels, extra_role: {} },
          workers: {
            items: [
              { ...workspaceAgentModels.worker, extra_metadata: {} },
              {
                agent_id: "runtime-worker",
                name: "Codex Worker",
                role: "worker",
                source: "runtime_default",
                model: null,
                provider: null,
                reasoning_effort: null,
                runtime: { kind: "connected", provider: "codex" },
              },
            ],
            next_cursor: null,
          },
          platform_defaults: {
            router: { ...workspacePlatformModel, extra_metadata: {} },
            worker: workspacePlatformModel,
            extra_role: {},
          },
        },
        200,
        headers
      );
      return;
    }

    if (method === "PUT" && url.pathname.endsWith("/workspaces/wsp_person_e2e/vm")) {
      workspaceVmEnabled = (request.postDataJSON() as { enabled: boolean }).enabled;
      await fulfillJson(
        route,
        {
          workspace_id: "wsp_person_e2e",
          enabled: workspaceVmEnabled,
          convergence_status: "pending",
        },
        202,
        headers
      );
      return;
    }

    const workspaceAgentModelUpdateMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/workspaces\/agent-models\/(router|worker)$/
    );
    if (method === "PUT" && workspaceAgentModelUpdateMatch) {
      const role = workspaceAgentModelUpdateMatch[2] as "router" | "worker";
      const body = request.postDataJSON() as {
        model: { kind: string; model: string } | null;
      };
      if (body.model?.kind === "catalog") {
        workspaceAgentModels[role] = {
          ...workspaceAgentModels[role],
          source: "pinned",
          model: body.model.model,
          selection: {
            kind: "catalog",
            model: body.model.model,
            reasoning_effort: null,
          },
        };
      } else if (body.model === null) {
        workspaceAgentModels[role] = followPlatform(workspaceAgentModels[role]);
      } else {
        await fulfillJson(
          route,
          { error: "invalid_workspace_agent_model" },
          400,
          headers
        );
        return;
      }
      await fulfillJson(route, workspaceAgentModels[role], 200, headers);
      return;
    }

    const workspaceCreditsMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/users\/([^/]+)\/workspace-credits$/
    );
    if (method === "POST" && workspaceCreditsMatch) {
      const body = request.postDataJSON() as Record<string, string>;
      issuedWorkspaceCredits = 100;
      await fulfillJson(
        route,
        {
          manual_grant: {
            id: "manual_grant_admin_e2e",
            billing_account_id: "billing_person_e2e",
            package_code: body.package_code,
            package_version: body.package_version,
            source_type: "manual_adjustment",
            source_id: "comma_admin:wsp_person_e2e",
            source_event_id: "audit_admin_grant_e2e",
            operator_snapshot: {
              id: "usr_admin_e2e",
              type: "comma_admin_user",
              reason: body.reason,
            },
            valid_from: "2026-07-28T08:00:00Z",
            expires_at: body.expires_at,
            credit_grant_id: "grant_admin_e2e",
            status: "issued",
          },
          grant: {
            id: "grant_admin_e2e",
            billing_account_id: "billing_person_e2e",
            remaining_credits: 100,
            valid_from: "2026-07-28T08:00:00Z",
            expires_at: body.expires_at,
            status: "active",
          },
          idempotent: false,
        },
        201,
        headers
      );
      return;
    }

    if (url.pathname === "/v1/comma/admin/billing/free-router-models") {
      if (method === "PUT") {
        const body = request.postDataJSON() as typeof freeRouterPolicy;
        if (body.revision !== freeRouterPolicy.revision) {
          await fulfillJson(route, { error: "billing_policy_conflict" }, 409, headers);
          return;
        }
        freeRouterPolicy = { models: body.models, revision: body.revision + 1 };
      }
      await fulfillJson(route, freeRouterPolicy, 200, headers);
      return;
    }

    if (`${method} ${url.pathname}` === "POST /v1/comma/admin/guest-mode/tenant") {
      const body = request.postDataJSON() as { revision: number };
      if (body.revision !== guestPolicy.revision) {
        await fulfillJson(route, { error: "guest_policy_conflict" }, 409, headers);
        return;
      }
      guestTenantCount += 1;
      guestPolicy = {
        ...guestPolicy,
        salix_tenant_id: `tenant_guest_e2e_${guestTenantCount}`,
        revision: body.revision + 1,
      };
      await fulfillJson(route, guestPolicy, 200, headers);
      return;
    }

    if (url.pathname === "/v1/comma/admin/guest-mode") {
      if (method === "PUT") {
        const body = request.postDataJSON() as typeof guestPolicy;
        if (body.revision !== guestPolicy.revision) {
          await fulfillJson(route, { error: "guest_policy_conflict" }, 409, headers);
          return;
        }
        if (body.enabled && !guestPolicy.salix_tenant_id) {
          await fulfillJson(route, { error: "guest_tenant_required" }, 422, headers);
          return;
        }
        guestPolicy = {
          ...guestPolicy,
          enabled: body.enabled,
          daily_creation_limit: body.daily_creation_limit,
          tenant_concurrency: body.tenant_concurrency,
          session_ttl_seconds: body.session_ttl_seconds,
          pow_difficulty: body.pow_difficulty,
          revision: body.revision + 1,
        };
      }
      await fulfillJson(route, guestPolicy, 200, headers);
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/billing/redeem-codes") {
      await fulfillJson(route, { data: codes }, 200, headers);
      return;
    }

    if (
      `${method} ${url.pathname}` === "GET /v1/comma/admin/billing/package-versions"
    ) {
      await fulfillJson(
        route,
        {
          data: [
            {
              grant_credits: 100,
              grant_period: "month",
              id: "package_e2e",
              kind: "one_time",
              package_code: "comma_monthly",
              package_name: "Comma Monthly",
              status: "active",
              surface: "comma",
              version: "v1",
            },
          ],
        },
        200,
        headers
      );
      return;
    }

    if (`${method} ${url.pathname}` === "POST /v1/comma/admin/billing/redeem-codes") {
      const body = request.postDataJSON() as Record<string, string>;
      await options.createRedeemCodeGate;
      const created: CodeRecord & { code: string } = {
        code: "COMMA-NEW-ONE-TIME",
        code_type: "one_time_package",
        display_prefix: "COMMA-NEW",
        id: "code_new_e2e",
        package_code: body.package_code ?? "",
        package_version: body.package_version ?? "",
        status: "active",
      };
      codes.unshift(created);
      await fulfillJson(route, created, 201, headers);
      return;
    }

    if (
      `${method} ${url.pathname}` === "POST /v1/comma/admin/billing/redeem-codes/apply"
    ) {
      const body = request.postDataJSON() as Record<string, string>;
      const redemption = {
        billing_account_id: body.billing_account_id,
        id: "redemption_new_e2e",
        product_owner_id: body.product_owner_id,
        product_owner_type: body.product_owner_type,
        redeem_code_id: body.id,
        source_type: "redeem_one_time",
        status: "applied",
      };
      const codeId = body.id ?? "";
      redemptions.set(codeId, [redemption, ...(redemptions.get(codeId) ?? [])]);
      await fulfillJson(route, { idempotent: false, redemption }, 201, headers);
      return;
    }

    const disableMatch = url.pathname.match(
      /^\/v1\/comma\/admin\/billing\/redeem-codes\/([^/]+)\/disable$/
    );
    if (method === "POST" && disableMatch) {
      const code = codes.find((entry) => entry.id === disableMatch[1])!;
      code.status = "disabled";
      await fulfillJson(route, code, 200, headers);
      return;
    }

    if (`${method} ${url.pathname}` === "GET /v1/comma/admin/billing/redemptions") {
      const codeId = url.searchParams.get("redeem_code_id") || "";
      await fulfillJson(route, { data: redemptions.get(codeId) ?? [] }, 200, headers);
      return;
    }

    await fulfillJson(
      route,
      { error: `unexpected_request:${method}:${url.pathname}` },
      500,
      headers
    );
  });
}

/** Reviews an audited command: gives the reason and, for a guarded command, types the target's name. */
async function confirmCommand(
  page: Page,
  title: string,
  reason: string,
  typed?: string
) {
  const confirmation = page.getByRole("dialog", { name: title });
  await confirmation.getByRole("textbox", { name: "Reason" }).fill(reason);
  if (typed !== undefined) {
    await confirmation
      .getByRole("textbox", { name: `Type “${typed}” to confirm` })
      .fill(typed);
  }
  await confirmation.getByRole("button", { name: "Confirm" }).click();
  await expect(confirmation).toHaveCount(0);
}

async function assertPendingSecretDrawerIsLocked(
  page: Page,
  drawer: Locator,
  confirmation: Locator,
  navigationLabel: string
) {
  await expect(drawer).toBeVisible();
  await expect(
    drawer.getByRole("button", {
      exact: true,
      includeHidden: true,
      name: "Close",
    })
  ).toHaveCount(0);

  await page.keyboard.press("Escape");
  await expect(confirmation).toBeVisible();
  await expect(drawer).toBeVisible();

  await drawer.locator(".admin-drawer-dismiss").click({ force: true });
  await expect(confirmation).toBeVisible();
  await expect(drawer).toBeVisible();

  const navigation = page
    .locator("button.admin-nav-button")
    .filter({ hasText: navigationLabel });
  const navigationBlocked = await navigation.click({ timeout: 500 }).then(
    () => false,
    () => true
  );
  expect(navigationBlocked).toBe(true);
  await expect(confirmation).toBeVisible();
  await expect(drawer).toBeVisible();
}

async function localStorageSnapshot(page: Page) {
  return page.evaluate(() => JSON.stringify({ ...localStorage }));
}

function agentVmmNode(withEnvironments: boolean) {
  return {
    id: "registration-e2e",
    device_id: "host-e2e",
    group_id: "group-e2e",
    status: "unknown",
    issue: "observation_stale",
    updated_at: "2026-09-01T10:00:00Z",
    registration: {
      status: "ready",
      desired_enabled: true,
      revision: 7,
      policy_revision: 2,
    },
    installation: null,
    connection: {
      status: "stale",
      last_observed_at: "2026-09-01T09:58:00Z",
      binding_count: 1,
    },
    work: { allocations: 1, workloads: 1, runtimes: 1 },
    operations: { active: 0, unknown_outcome: 0 },
    ...(withEnvironments
      ? {
          environments: [
            {
              id: "environment-e2e",
              owner_type: "project",
              owner_id: "project-e2e",
              desired_state: "ready",
              observed_state: "ready",
              generation: 1,
              revision: 3,
              binding_status: "available",
              allocations: 1,
              workloads: 1,
              runtimes: 1,
              updated_at: "2026-09-01T10:00:00Z",
            },
          ],
        }
      : {}),
  };
}

function corsHeaders(route: Route) {
  const requestHeaders = route.request().headers();
  const origin = requestHeaders.origin;
  return {
    "access-control-allow-credentials": "true",
    "access-control-allow-headers":
      requestHeaders["access-control-request-headers"] ??
      "content-type,x-comma-expected-auth-session-id,x-comma-session-lifecycle-version,x-comma-session-transport",
    "access-control-allow-methods": "GET,POST,PATCH,PUT,OPTIONS",
    ...(origin ? { "access-control-allow-origin": origin } : {}),
    "cache-control": "no-store",
    "content-type": "application/json",
    vary: "origin",
  };
}

async function fulfillJson(
  route: Route,
  body: unknown,
  status: number,
  headers: Record<string, string>
) {
  await route.fulfill({
    body: JSON.stringify(body),
    headers,
    status,
  });
}
