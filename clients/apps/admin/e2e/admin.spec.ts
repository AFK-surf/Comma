import { expect, test, type Locator, type Page, type Route } from "@playwright/test";

const apiBaseUrl = "http://127.0.0.1:65535";
const sessionId = "11111111-1111-4111-8111-111111111111";
const adminSessionEmail = "operator-with-a-very-long-name@example.com";

test("Billing saves free Router models and reloads the persisted list", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes,
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Redeem codes", exact: true }).click();
  const panel = page.getByRole("region", { name: "Free Router models", exact: true });
  await expect(panel.getByText("No models are free under this policy.")).toBeVisible();
  await panel.getByRole("textbox", { name: "Provider", exact: true }).fill("openai");
  await panel.getByRole("textbox", { name: "Model SKU" }).fill("gpt-5.6-luna");
  await panel.getByRole("button", { name: "Add model" }).click();
  await panel.getByRole("textbox", { name: /^Reason/ }).fill("Offer free Router calls");
  await panel.getByRole("button", { name: "Save free Router models" }).click();
  await confirmCommand(
    page,
    "Save free Router models?",
    "update-free-router-models:comma"
  );
  await expect(panel).toContainText("Saved. New Router calls use this policy.");
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
  await page.getByRole("button", { name: "Redeem codes", exact: true }).click();
  await panel.getByRole("button", { name: "Remove gpt-5.6-luna" }).click();
  await panel.getByRole("textbox", { name: /^Reason/ }).fill("End free Router offer");
  await panel.getByRole("button", { name: "Save free Router models" }).click();
  await confirmCommand(
    page,
    "Save free Router models?",
    "update-free-router-models:comma"
  );
  expect(writes.at(-1)).toMatchObject({ body: { models: [], revision: 1 } });
  await panel.getByRole("button", { name: "Reload", exact: true }).click();
  await expect(panel.getByText("No models are free under this policy.")).toBeVisible();
});

test("Models saves a platform template allowlist and an empty selected list", async ({
  page,
}) => {
  const writes: AdminWrite[] = [];
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes,
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Models", exact: true }).click();
  const panel = page.getByRole("region", { name: "Model selection policy" });
  await expect(page.getByRole("heading", { name: "Models", level: 1 })).toBeVisible();
  await expect(
    panel.getByRole("radio", { name: "All platform templates" })
  ).toBeChecked();

  await panel.getByRole("radio", { name: "Selected templates only" }).check();
  await panel.getByRole("textbox", { name: "Search templates" }).fill("gpt-6");
  await panel
    .getByRole("checkbox", { name: "Allow GPT-6 Sol (platform-gpt-6-sol)" })
    .check();
  await panel
    .getByRole("textbox", { name: /^Reason/ })
    .fill("Limit new Comma model choices");
  await panel.getByRole("button", { name: "Save model choices" }).click();
  await confirmCommand(
    page,
    "Save model choices?",
    "update-model-selection-policy:comma"
  );
  expect(writes.at(-1)).toMatchObject({
    method: "PUT",
    path: "/v1/comma/admin/model-selection-policy",
    body: {
      mode: "selected",
      allowed_template_ids: ["platform-gpt-6-sol"],
      revision: 0,
      reason: "Limit new Comma model choices",
    },
  });

  await page.reload();
  await expect(
    panel.getByRole("checkbox", { name: "Allow GPT-6 Sol (platform-gpt-6-sol)" })
  ).toBeChecked();
  await panel
    .getByRole("checkbox", { name: "Allow GPT-6 Sol (platform-gpt-6-sol)" })
    .uncheck();
  await panel
    .getByRole("textbox", { name: /^Reason/ })
    .fill("Pause new platform choices");
  await panel.getByRole("button", { name: "Save model choices" }).click();
  await confirmCommand(
    page,
    "Save model choices?",
    "update-model-selection-policy:comma"
  );
  expect(writes.at(-1)).toMatchObject({
    body: { mode: "selected", allowed_template_ids: [], revision: 1 },
  });
  await expect(panel.getByText("0 selected.", { exact: false })).toBeVisible();
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

  await tenant.getByRole("textbox", { name: /^Reason/ }).fill("Start guest trials");
  await tenant.getByRole("button", { name: "Create new guest tenant" }).click();
  await expect(
    page.getByRole("dialog", { name: "Create new guest tenant?" })
  ).toContainText("Existing guest workspaces stay in their current tenant.");
  await confirmCommand(page, "Create new guest tenant?", "create-guest-tenant:comma");
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
  await policy.getByRole("textbox", { name: /^Reason/ }).fill("Open guest trials");
  await policy.getByRole("button", { name: "Save guest mode" }).click();
  await confirmCommand(page, "Save guest mode?", "update-guest-policy:comma");
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

test("Models scrolls as one page when the policy form is taller than the viewport", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    writes: [],
  });
  await page.setViewportSize({ width: 1280, height: 480 });
  await page.goto("/?section=models");

  const panel = page.getByRole("region", { name: "Model selection policy" });
  await panel.getByRole("radio", { name: "Selected templates only" }).check();
  const save = panel.getByRole("button", { name: "Save model choices" });
  await expect(save).not.toBeInViewport();

  await panel.getByRole("heading", { name: "User choices" }).hover();
  await page.mouse.wheel(0, 2_000);
  await expect(save).toBeInViewport();
  await expect(
    page.getByRole("heading", { name: "Models", level: 1 })
  ).toBeInViewport();
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

test("Redeem codes scrolls as one page when the free Router model list is long", async ({
  page,
}) => {
  await installSignedInAdmin(page, {
    adminRequestHeaders: [],
    forbidden: false,
    freeRouterModels: Array.from({ length: 40 }, (_, index) => ({
      provider: "openai",
      sku: `gpt-e2e-${index}`,
    })),
    writes: [],
  });
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/?section=billing");

  const panel = page.getByRole("region", { name: "Free Router models", exact: true });
  await expect(panel.getByRole("button", { name: "Remove gpt-e2e-39" })).toBeVisible();
  const codesTable = page.getByRole("table", { name: "Redeem codes" });
  const codeRecords = page
    .locator(".admin-table-card")
    .filter({ has: page.getByRole("heading", { name: "Code records" }) });
  await expect(codesTable).toBeAttached();

  const pageScroll = page
    .getByTestId("admin-billing-scroll")
    .locator(":scope > .comma-scroll-area__viewport");
  const overflow = await pageScroll.evaluate(
    (viewport) => viewport.scrollHeight - viewport.clientHeight
  );
  expect(overflow).toBeGreaterThan(0);

  await codesTable.getByRole("button", { name: "Manage" }).scrollIntoViewIfNeeded();
  await expect(codesTable.getByRole("button", { name: "Manage" })).toBeInViewport();
  await expect(
    page.getByRole("heading", { name: "Redeem codes", level: 1 })
  ).toBeInViewport();
  const cardBox = await codeRecords.boundingBox();
  const tableBox = await codesTable.boundingBox();
  expect(cardBox).not.toBeNull();
  expect(tableBox).not.toBeNull();
  expect(cardBox!.height).toBeGreaterThan(tableBox!.height);
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
    .getByRole("textbox", { name: "Reason" })
    .fill("Create an isolated shell for validation");
  await drawer
    .getByRole("button", { name: "Create Shell workload", exact: true })
    .click();
  await confirmCommand(
    page,
    "Create Shell workload",
    "create_shell_workload:environment-e2e:3"
  );
  await expect(page.getByText(/was accepted/)).toBeVisible();
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Drain for planned maintenance");
  await drawer.getByRole("button", { name: "Disable / drain" }).click();
  await confirmCommand(
    page,
    "Disable and drain registration",
    "disable_agent_vmm_registration:registration-e2e:7"
  );
  await expect(page.getByText(/was accepted/)).toBeVisible();
  await drawer.getByRole("button", { name: "Close", exact: true }).click();
});

test("the standalone dashboard runs audited User and Billing operations", async ({
  page,
}) => {
  test.setTimeout(75_000);

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
  await expect(page.getByRole("button", { name: "Audited operations" })).toBeVisible();
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

  await page.getByRole("button", { name: "Audited operations" }).click();
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

  await usersTable.getByRole("button", { name: "Manage" }).click();
  drawer = page.getByRole("dialog", { name: "Manage user" });
  await expect(drawer).toContainText("owner@gmail.com");
  await expect(drawer).toContainText("Verified");
  await drawer.getByRole("button", { name: "Close", exact: true }).click();

  await page.getByRole("button", { name: "New user" }).click();
  drawer = page.getByRole("dialog", { name: "New user" });
  await drawer.getByRole("textbox", { name: "Email" }).fill("person@example.com");
  await drawer.getByRole("textbox", { name: "Display name" }).fill("Person");
  await drawer.getByLabel("Admin access").selectOption("allow");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Create an approved support-managed account");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(page, "Create this user?", "create-user:person@example.com");

  drawer = page.getByRole("dialog", { name: "Manage user" });
  await expect(drawer).toContainText("person@example.com");
  await expect(drawer).toContainText("Explicit allow");
  await expect(drawer).toContainText("Email OTP");
  await expect(drawer).toContainText("Not linked");
  await expect(drawer).toContainText("Edit account");
  await expect(drawer).toContainText("Admin access");
  await expect(drawer).toContainText("Support session");
  await expect(drawer).toContainText("Workspace & billing");

  await openTask(drawer, "Edit account");
  await drawer.getByRole("textbox", { name: "Display name" }).fill("Person Updated");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Correct the display name");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(page, "Edit account?", "update-user:usr_person_e2e");
  await expect(drawer).toContainText("Updated person@example.com.");

  await openTask(drawer, "Admin access");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Remove temporary Admin access");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Change Admin access?",
    "admin-access:usr_person_e2e:deny"
  );
  await expect(drawer).toContainText("Explicit deny");

  await openTask(drawer, "Sessions & devices");
  await expect(drawer.getByText("Web on macOS")).toBeVisible();
  await expect(drawer.getByText("Comma Desktop on Windows")).toBeVisible();
  await expect(drawer.getByText(/Reported Web · Email OTP/)).toBeVisible();
  await expect(drawer.getByText("Comma SSH", { exact: true })).toBeVisible();
  await expect(drawer.getByText(/Reported SSH · SSH public key/)).toBeVisible();
  await expect(drawer.getByText("Comma Android app", { exact: true })).toBeVisible();
  await expect(drawer.getByText(/Reported Android · Google/)).toBeVisible();

  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Remove a stale browser Session");
  const webSessionCard = drawer
    .locator("article.admin-session-card")
    .filter({ hasText: "Web on macOS" });
  await webSessionCard.getByRole("button", { name: "Revoke" }).click();
  await confirmCommand(page, "Revoke this Session?", "revoke-session:sess_web_e2e");
  await expect(drawer).toContainText("Revoked Web on macOS.");

  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("End all remaining Sessions");
  await drawer.getByRole("button", { name: "Revoke all" }).click();
  await confirmCommand(
    page,
    "Revoke all Sessions?",
    "revoke-all-sessions:usr_person_e2e"
  );
  await expect(drawer).toContainText("Revoked 3 active Sessions.");
  await drawer.getByRole("button", { name: "Back" }).click();

  await openTask(drawer, "Support session");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Investigate a reported account issue");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Create support Session?",
    "support-session:usr_person_e2e"
  );
  await expect(drawer.getByText("comma_sess_support_e2e")).toBeVisible();
  await expect(
    drawer.getByRole("heading", { name: "Record couldn’t be loaded" })
  ).toHaveCount(0);
  expect(await localStorageSnapshot(page)).not.toContain("comma_sess_support_e2e");
  await drawer.getByRole("button", { name: "Done and clear" }).click();
  await expect(drawer.getByText("comma_sess_support_e2e")).toHaveCount(0);
  await expect(
    drawer.getByRole("heading", { name: "Record couldn’t be loaded" })
  ).toBeVisible();
  await drawer.getByRole("button", { name: "Retry" }).click();
  await expect(drawer.getByText("Workspace & billing")).toBeVisible();

  await openTask(drawer, "Workspace & billing");
  await expect(drawer).toContainText("No default Workspace");
  await drawer.getByRole("button", { name: "Ensure default Workspace" }).click();
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Ensure the default Workspace exists");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Ensure default Workspace?",
    "default-workspace:usr_person_e2e"
  );
  await expect(drawer).toContainText("wsp_person_e2e");

  await openTask(drawer, "Workspace & billing");
  await expect(drawer).toContainText("Person Workspace");
  await expect(drawer).toContainText("Tenant ID");
  await expect(drawer).toContainText("tnt_person_e2e");
  await expect(drawer).toContainText("Agent group ID");
  await expect(drawer).toContainText("grp_person_e2e");
  await expect(drawer).toContainText("billing_person_e2e");
  await expect(drawer.getByRole("heading", { name: "Agent models" })).toBeVisible();
  await expect(drawer).toContainText("gpt-5.6-luna");
  await expect(drawer).toContainText("gpt-5.6-sol");
  const vmSection = drawer.getByRole("region", { name: "Cloud VM", exact: true });
  await expect(
    vmSection.getByRole("combobox", { name: "Cloud VM setting" })
  ).toHaveValue("enabled");
  await vmSection.screenshot({
    path: test.info().outputPath("workspace-cloud-vm.png"),
  });
  for (const setting of ["disabled", "enabled"]) {
    await vmSection
      .getByRole("combobox", { name: "Cloud VM setting" })
      .selectOption(setting);
    await vmSection
      .getByRole("textbox", { name: "Reason" })
      .fill(`Set shared VM ${setting}`);
    await vmSection.getByRole("button", { name: "Review Cloud VM change" }).click();
    await confirmCommand(
      page,
      setting === "enabled" ? "Enable Cloud VM?" : "Disable Cloud VM?",
      `workspace-vm:wsp_person_e2e:${setting === "enabled" ? "enable" : "disable"}`
    );
    await expect(vmSection).toContainText("Cloud VM setting saved.");
    await expect(vmSection).toContainText("pending");
  }
  expect(
    writes
      .filter((write) => write.path.endsWith("/workspaces/wsp_person_e2e/vm"))
      .map((write) => write.body.enabled)
  ).toEqual([false, true]);

  await drawer.getByRole("button", { name: "Change Worker model" }).click();
  const modelPane = drawer.getByRole("region", { name: "Change Worker model" });
  await expect(modelPane.locator('option[value="template_terra"]')).toHaveText(
    "GPT-5.6 Terra — US endpoint"
  );
  await expect(modelPane.locator('option[value="template_terra_eu"]')).toHaveText(
    "GPT-5.6 Terra — EU endpoint"
  );
  await modelPane
    .getByRole("combobox", { name: "Worker model" })
    .selectOption("template_terra");
  await modelPane
    .getByRole("textbox", { name: "Reason" })
    .fill("Use the approved lower-latency Worker model");
  await modelPane.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Change Worker model?",
    "workspace-agent-model:usr_person_e2e:worker:template_terra"
  );
  await expect(drawer).toContainText(
    "Worker model changed to US endpoint — gpt-5.6-terra."
  );
  await expect(drawer).toContainText("gpt-5.6-terra");
  await expect(drawer).toContainText(
    "The Billing account does not belong to this Workspace."
  );
  await expect(
    drawer.getByRole("button", { name: "Apply redeem code" })
  ).toBeDisabled();
  await expect(drawer.getByRole("button", { name: "Issue credits" })).toBeDisabled();
  await drawer.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(drawer).toContainText("comma_monthly@v1");
  await expect(drawer.getByText("1,200")).toHaveCount(2);

  await drawer.getByRole("button", { name: "Issue credits" }).click();
  const creditPane = drawer.getByRole("region", { name: "Issue Workspace credits" });
  await expect(creditPane).toContainText("Person Workspace");
  await expect(creditPane).toContainText("100 credits");
  await expect(page.getByRole("dialog")).toHaveCount(1);
  await creditPane
    .getByRole("textbox", { name: "Reason" })
    .fill("Issue the approved direct Workspace credit");
  await creditPane.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Issue these credits?",
    "issue-workspace-credits:wsp_person_e2e:comma_monthly:v1"
  );
  await expect(creditPane).toHaveCount(0);
  await expect(drawer).toContainText("Issued 100 credits.");
  await expect(drawer.getByText("1,300")).toBeVisible();

  await drawer.getByRole("button", { name: "Apply redeem code" }).click();

  drawer = page.getByRole("dialog", { name: "Apply redeem code" });
  await expect(drawer).toContainText("Person Workspace");
  await expect(drawer).toContainText("wsp_person_e2e");
  await expect(drawer).toContainText("billing_person_e2e");
  await expect(drawer.getByRole("textbox", { name: "Billing account ID" })).toHaveCount(
    0
  );
  await expect(drawer.getByRole("textbox", { name: "Owner ID" })).toHaveCount(0);
  await drawer.getByLabel("Active code").selectOption("code_e2e");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Apply the approved Workspace credit");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Apply this redeem code?",
    "apply-redeem-code:billing_person_e2e"
  );

  drawer = page.getByRole("dialog", { name: "COMMA-INTERNAL" });
  await expect(
    drawer.getByRole("table", { name: "Redemptions for code" })
  ).toContainText("billing_person_e2e");

  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Retire the completed support code");
  await drawer.getByRole("button", { name: "Disable code" }).click();
  await confirmCommand(
    page,
    "Disable this redeem code?",
    "disable-redeem-code:code_e2e"
  );
  await expect(drawer).toContainText("disabled");
  await drawer.getByRole("button", { name: "Close", exact: true }).click();

  await expect(page.getByRole("table", { name: "Redeem codes" })).toContainText(
    "COMMA-INTERNAL"
  );

  await page.getByRole("button", { name: "New code" }).click();
  drawer = page.getByRole("dialog", { name: "New redeem code" });
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Issue an approved support credit");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Create this redeem code?",
    "create-redeem-code:comma_monthly:v1"
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
      template_id: "template_terra",
      reason: "Use the approved lower-latency Worker model",
    })
  );
  expect(modelWrite?.body.agent_id).toBeUndefined();
  expect(modelWrite?.body.workspace_id).toBeUndefined();
  expect(modelWrite?.body.tenant_id).toBeUndefined();
  expect(modelWrite?.body.group_id).toBeUndefined();
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
  await usersTable.getByRole("button", { name: "Manage" }).click();
  let drawer = page.getByRole("dialog", { name: "Manage user" });
  await openTask(drawer, "Support session");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify the pending support Session secret lifecycle");
  await drawer.getByRole("button", { name: "Review command" }).click();

  let confirmation = page.getByRole("dialog", {
    name: "Create support Session?",
  });
  await confirmation
    .getByRole("textbox", { name: "Confirmation value" })
    .fill("support-session:usr_admin_e2e");
  await confirmation.getByRole("button", { name: "Confirm" }).click();
  await expect(confirmation.getByRole("button", { name: "Working…" })).toBeVisible();
  await assertPendingSecretDrawerIsLocked(page, drawer, confirmation, "Redeem codes");

  supportResponse.resolve();
  await expect(confirmation).toHaveCount(0);
  await expect(drawer.getByText("comma_sess_support_e2e", { exact: true })).toHaveCount(
    1
  );
  expect(await localStorageSnapshot(page)).not.toContain("comma_sess_support_e2e");
  await drawer.getByRole("button", { name: "Done and clear" }).click();
  await expect(drawer.getByText("comma_sess_support_e2e", { exact: true })).toHaveCount(
    0
  );
  await drawer.getByRole("button", { name: "Close", exact: true }).click();

  await page.getByRole("button", { name: "Redeem codes" }).click();
  await page.getByRole("button", { name: "New code" }).click();
  drawer = page.getByRole("dialog", { name: "New redeem code" });
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify the pending Redeem Code secret lifecycle");
  await drawer.getByRole("button", { name: "Review command" }).click();

  confirmation = page.getByRole("dialog", {
    name: "Create this redeem code?",
  });
  await confirmation
    .getByRole("textbox", { name: "Confirmation value" })
    .fill("create-redeem-code:comma_monthly:v1");
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
  await usersTable.getByRole("button", { name: "Manage" }).click();
  const drawer = page.getByRole("dialog", { name: "Manage user" });
  await openTask(drawer, "Support session");
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Verify a task-local command rejection");
  await drawer.getByRole("button", { name: "Review command" }).click();

  const confirmation = page.getByRole("dialog", {
    name: "Create support Session?",
  });
  await confirmation
    .getByRole("textbox", { name: "Confirmation value" })
    .fill("support-session:usr_admin_e2e");
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
  await expect(clientsTable).toContainText("active");

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
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Register the approved support portal");
  await drawer.getByRole("button", { name: "Review command" }).click();
  const createConfirmation = page.getByRole("dialog", {
    name: "Create this OAuth client?",
  });
  await createConfirmation
    .getByRole("textbox", { name: "Confirmation value" })
    .fill("create-oauth-client:Support Portal");
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
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Register the approved native helper");
  await drawer.getByRole("button", { name: "Review command" }).click();
  await confirmCommand(
    page,
    "Create this OAuth client?",
    "create-oauth-client:Native Helper"
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
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Rotate the bootstrap credential before handoff");
  await drawer.getByRole("button", { name: "Rotate secret" }).click();
  await confirmCommand(
    page,
    "Rotate this client secret?",
    "rotate-oauth-client-secret:oauth_sync_e2e"
  );

  drawer = page.getByRole("dialog", { name: "Client secret rotated" });
  await expect(
    drawer.getByText("oauth-rotated-secret-e2e", { exact: true })
  ).toBeVisible();
  expect(await localStorageSnapshot(page)).not.toContain("oauth-rotated-secret-e2e");
  await drawer.getByRole("button", { name: "Done and clear" }).click();

  drawer = page.getByRole("dialog", { name: "Manage OAuth client" });
  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Disable the integration during credential rollout");
  await drawer.getByRole("button", { name: "Disable client" }).click();
  await confirmCommand(
    page,
    "Disable this OAuth client?",
    "disable-oauth-client:oauth_sync_e2e"
  );
  await expect(drawer).toContainText("disabled");

  await drawer
    .getByRole("textbox", { name: "Reason" })
    .fill("Restore the integration after credential rollout");
  await drawer.getByRole("button", { name: "Enable client" }).click();
  await confirmCommand(
    page,
    "Enable this OAuth client?",
    "enable-oauth-client:oauth_sync_e2e"
  );
  await expect(drawer).toContainText("active");

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

test("an exhausted Session recovery ticket renews without an error screen", async ({
  page,
}) => {
  let sessionProbeCount = 0;
  await page.addInitScript(
    ({ canonicalApiOrigin }) => {
      const storageKey = `comma.session-lifecycle.v1:${encodeURIComponent(
        canonicalApiOrigin
      )}`;
      localStorage.setItem(
        storageKey,
        JSON.stringify({
          canonicalApiOrigin,
          cookieAuthorityId: "exhausted-cookie-authority",
          cookieGeneration: 0,
          coordinationRevision: 2,
          kind: "recovering",
          schemaVersion: 1,
          ticket: {
            attemptsStarted: 2,
            deadlineAtEpochMs: Date.now() - 1_000,
            expectation: { kind: "unknown_rebind" },
            maxAttempts: 2,
            progress: {
              phase: "exhausted",
              problem: "session_probe_unavailable",
            },
            ticketId: "exhausted-recovery-ticket",
          },
          writeNonce: "exhausted-write-nonce",
        })
      );
    },
    { canonicalApiOrigin: apiBaseUrl }
  );

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
  admin_access: {
    allowed: boolean;
    decision: "allow" | "deny" | null;
    source: "disabled" | "domain_default" | "explicit_allow" | "explicit_deny" | "none";
  };
  created_at: number;
  email: string;
  id: string;
  login_methods: Array<
    | { email: string; method: "email_otp" }
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
    createOauthClientGate?: Promise<void>;
    createRedeemCodeGate?: Promise<void>;
    forbidden: boolean;
    freeRouterModels?: Array<{ provider: string; sku: string }>;
    sessionProbe?: (route: Route, headers: Record<string, string>) => Promise<void>;
    supportSessionGate?: Promise<void>;
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
  const readyWorkspaces = new Set<string>();
  const workspaceBillingReads = new Map<string, number>();
  let workspaceVmEnabled = true;
  const workspaceModelOptions = [
    {
      template_id: "template_luna",
      name: "GPT-5.6 Luna",
      model: "gpt-5.6-luna",
      provider: "openai",
      scope: "global",
      reasoning_effort: "high",
    },
    {
      template_id: "template_sol",
      name: "GPT-5.6 Sol",
      model: "gpt-5.6-sol",
      provider: "openai",
      scope: "global",
      reasoning_effort: "high",
    },
    {
      template_id: "template_terra",
      name: "US endpoint",
      model: "gpt-5.6-terra",
      model_display_name: "GPT-5.6 Terra",
      provider: "openai",
      scope: "global",
      reasoning_effort: "high",
    },
    {
      template_id: "template_terra_eu",
      name: "EU endpoint",
      model: "gpt-5.6-terra",
      model_display_name: "GPT-5.6 Terra",
      provider: "openai",
      scope: "global",
      reasoning_effort: "high",
    },
  ];
  const workspaceAgentModels: Record<
    "router" | "worker",
    {
      agent_id: string;
      role: "router" | "worker";
      template_id: string;
      template_name: string;
      model: string;
      provider: string;
      reasoning_effort: string | null;
    }
  > = {
    router: {
      agent_id: "agent_router_e2e",
      role: "router" as const,
      template_id: "template_luna",
      template_name: "GPT-5.6 Luna",
      model: "gpt-5.6-luna",
      provider: "openai",
      reasoning_effort: null,
    },
    worker: {
      agent_id: "agent_worker_e2e",
      role: "worker" as const,
      template_id: "template_sol",
      template_name: "GPT-5.6 Sol",
      model: "gpt-5.6-sol",
      provider: "openai",
      reasoning_effort: "high",
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
  let modelSelectionPolicy: {
    mode: "all" | "selected";
    allowed_template_ids: string[];
    revision: number;
  } = { mode: "all", allowed_template_ids: [], revision: 0 };
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
      await fulfillJson(
        route,
        {
          data: auditEvents,
          has_more: false,
          next_cursor: null,
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
      const exactEmail = url.searchParams.get("email");
      await fulfillJson(
        route,
        {
          data: exactEmail ? users.filter((user) => user.email === exactEmail) : users,
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
      await fulfillJson(
        route,
        {
          data: sessions.get(sessionListMatch[1]!) ?? [],
          has_more: false,
          next_cursor: null,
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
          agents: { ...workspaceAgentModels, extra_role: {} },
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
          worker_default_template_id: null,
          platform_defaults: {
            router: { ...workspaceModelOptions[0], extra_metadata: {} },
            worker: workspaceModelOptions[1],
            extra_role: {},
          },
          available_models: workspaceModelOptions.map((model) => ({
            ...model,
            extra_metadata: {},
          })),
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
      const body = request.postDataJSON() as { template_id: string };
      const selected = workspaceModelOptions.find(
        (model) => model.template_id === body.template_id
      );
      if (!selected) {
        await fulfillJson(route, { error: "invalid_model_template" }, 400, headers);
        return;
      }

      workspaceAgentModels[role] = {
        ...workspaceAgentModels[role],
        template_id: selected.template_id,
        template_name: selected.name,
        model: selected.model,
        provider: selected.provider,
        reasoning_effort: selected.reasoning_effort,
      };
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

    if (
      `${method} ${url.pathname}` ===
      "GET /v1/comma/admin/model-selection-policy/templates"
    ) {
      await fulfillJson(
        route,
        {
          data: [
            {
              template_id: "platform-gpt-6-sol",
              name: "GPT-6 Sol",
              model: "gpt-6-sol",
              model_vendor: "openai",
              provider: "openrouter",
            },
            {
              template_id: "platform-claude-sonnet",
              name: "Claude Sonnet",
              model: "claude-sonnet",
              model_vendor: "anthropic",
              provider: "anthropic",
            },
          ],
        },
        200,
        headers
      );
      return;
    }

    if (url.pathname === "/v1/comma/admin/model-selection-policy") {
      if (method === "PUT") {
        const body = request.postDataJSON() as typeof modelSelectionPolicy;
        if (body.revision !== modelSelectionPolicy.revision) {
          await fulfillJson(
            route,
            { error: "model_selection_policy_conflict" },
            409,
            headers
          );
          return;
        }
        modelSelectionPolicy = {
          mode: body.mode,
          allowed_template_ids: body.allowed_template_ids,
          revision: body.revision + 1,
        };
      }
      await fulfillJson(route, modelSelectionPolicy, 200, headers);
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

async function openTask(drawer: Locator, taskName: string) {
  const card = drawer.locator("article.admin-task-card").filter({ hasText: taskName });
  await card.getByRole("button", { name: "Open" }).click();
}

async function confirmCommand(page: Page, title: string, expected: string) {
  const confirmation = page.getByRole("dialog", { name: title });
  await confirmation
    .getByRole("textbox", { name: "Confirmation value" })
    .fill(expected);
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
