import { test, expect, type Locator, type Page } from "@playwright/test";

// End-to-end coverage of the Salix admin dashboard, driven through the real
// LiveView UI on :4000/dash. Auth is the system-wide admin token pasted into the
// login form (no OIDC/dev-login bypass). Run serially: later tests reuse the
// tenant/template/group/agent created by earlier ones (persisted server-side).
const TOKEN = process.env.SALIX_API_TOKEN || "e2e-admin-token";
const uniq = () =>
  Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);

// Shared state carried across the serial suite.
let groupName = "";
let groupUrl = "";
let templateName = "";
let templateId = "";
let agentUrl = "";

async function expectLiveViewConnected(page: Page) {
  const root = page.locator("[data-phx-main]").first();
  await expect(root).toBeVisible();
  await expect(root).toHaveClass(/(^|\s)phx-connected(\s|$)/);
}

async function login(page: Page) {
  await page.goto("/dash/login");
  await page.locator('input[name="token"]').fill(TOKEN);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/dash$/);
  await expectLiveViewConnected(page);
}

async function gotoDashboard(page: Page, path: string) {
  await page.goto(path);
  await expectLiveViewConnected(page);
}

async function clickAndExpectVisible(trigger: Locator, target: Locator) {
  await expect(trigger).toBeVisible();
  await trigger.click();
  await expect(target).toBeVisible();
}

test("rejects an invalid admin token", async ({ page }) => {
  await page.goto("/dash/login");
  await page.locator('input[name="token"]').fill("definitely-wrong-token");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByText("Invalid admin token.")).toBeVisible();
});

test.describe("authenticated", () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("login lands on the app shell", async ({ page }) => {
    const sidebar = page.locator("aside");
    await expect(sidebar.getByText("Salix Admin")).toBeVisible();
    await expect(sidebar.getByRole("link", { name: "Tenants" })).toBeVisible();
    // `exact` so "Agents" doesn't also match the "Initial Agents" nav link.
    await expect(
      sidebar.getByRole("link", { name: "Agents", exact: true }),
    ).toBeVisible();
  });

  test("tenant switcher keeps long tenant names inside the sidebar", async ({
    page,
  }) => {
    const name = `Long Organization ${uniq()} with a customer name that should truncate in the switcher`;
    await gotoDashboard(page, "/dash/tenants");

    const form = page.locator("#new-tenant form");
    await clickAndExpectVisible(
      page.getByRole("button", { name: "New tenant" }),
      form,
    );
    await form.locator('input[name="name"]').fill(name);
    await form.locator('button[type="submit"]').click();
    await expect(page.getByRole("heading", { name })).toBeVisible();

    const sidebar = page.locator("aside");
    const menu = page.locator("#tenant-switcher-menu");
    const trigger = page.locator("#tenant-switcher > div.cursor-pointer");
    await expect(trigger).toHaveCount(1);
    await trigger.click();
    await expect(menu).toBeVisible();
    await expect(menu.getByRole("link", { name })).toBeVisible();

    const sidebarBox = await sidebar.boundingBox();
    const menuBox = await menu.boundingBox();
    expect(sidebarBox).not.toBeNull();
    expect(menuBox).not.toBeNull();
    expect(menuBox!.x).toBeGreaterThanOrEqual(sidebarBox!.x - 0.5);
    expect(menuBox!.x + menuBox!.width).toBeLessThanOrEqual(
      sidebarBox!.x + sidebarBox!.width + 0.5,
    );
  });

  test("cluster page renders stats", async ({ page }) => {
    await gotoDashboard(page, "/dash/cluster");
    await expect(page.getByRole("heading", { name: "Cluster" })).toBeVisible();
    await expect(page.getByText("Active nodes")).toBeVisible();
  });

  test("create a tenant and an API key", async ({ page }) => {
    const name = `Acme ${uniq()}`;
    await gotoDashboard(page, "/dash/tenants");

    const form = page.locator("#new-tenant form");
    await clickAndExpectVisible(
      page.getByRole("button", { name: "New tenant" }),
      form,
    );
    await form.locator('input[name="name"]').fill(name);
    await form.locator('button[type="submit"]').click();

    // Lands on the tenant detail page.
    await expect(page).toHaveURL(/\/dash\/tenants\/.+/);
    await expect(page.getByRole("heading", { name })).toBeVisible();

    // Mint an API key — the raw key is shown once in a banner.
    const keyForm = page.locator("form[phx-submit=create-key]");
    await keyForm.locator('input[name="name"]').fill("ci-key");
    await keyForm.locator('button[type="submit"]').click();
    await expect(page.getByText("New key (copy now)")).toBeVisible();
  });

  test("create a template and preserve credentials when editing its alias", async ({
    page,
  }) => {
    templateName = `Tmpl ${uniq()}`;
    await gotoDashboard(page, "/dash/templates/new");

    const form = page.locator("#template-form");
    await form
      .getByLabel("Configuration alias", { exact: true })
      .fill(templateName);
    await form.getByLabel("Model ID", { exact: true }).fill("mock-model");
    await form
      .getByLabel("API key", { exact: true })
      .fill("e2e-template-secret");
    await form.locator("#advanced-options > summary").click();
    await form
      .getByLabel("Extra provider parameters")
      .fill('{"custom":{"region":"test"}}');
    await form
      .getByRole("button", { name: "Save template", exact: true })
      .click();
    await expect(page).toHaveURL(/\/dash\/templates\/(?!new$).+/);
    templateId = new URL(page.url()).pathname.split("/").pop()!;
    await expect(
      page.getByRole("heading", { name: "mock-model", exact: true }),
    ).toBeVisible();
    await expect(form.getByLabel("API key", { exact: true })).toHaveValue("");
    await expect(form.getByLabel("API key", { exact: true })).toHaveAttribute(
      "placeholder",
      /Configured/,
    );

    templateName += " edited";
    await form
      .getByLabel("Configuration alias", { exact: true })
      .fill(templateName);
    const dialogHandled = new Promise<void>((resolve) =>
      page.once("dialog", async (dialog) => {
        expect(dialog.message()).toContain("Discard unsaved template changes");
        await dialog.dismiss();
        resolve();
      }),
    );
    await form.getByRole("link", { name: "Cancel", exact: true }).click();
    await dialogHandled;
    await expect(
      form.getByLabel("Configuration alias", { exact: true }),
    ).toHaveValue(templateName);
    await form
      .getByRole("button", { name: "Save template", exact: true })
      .click();
    await expect(
      page.getByText("Template saved.", { exact: true }),
    ).toBeVisible();
    await expect(form.getByLabel("API key", { exact: true })).toHaveValue("");
    await expect(form.getByLabel("API key", { exact: true })).toHaveAttribute(
      "placeholder",
      /Configured/,
    );
    await form.locator("#advanced-options > summary").click();
    await expect(form.getByLabel("Extra provider parameters")).toHaveValue(
      /"region": "test"/,
    );
    await page
      .getByRole("link", { name: "← Model catalog", exact: true })
      .click();
    await page
      .getByLabel("Search configurations", { exact: true })
      .fill(templateName);
    await expect(
      page
        .locator("#global-templates")
        .getByText(templateName, { exact: true }),
    ).toBeVisible();
  });

  test("create an agent group", async ({ page }) => {
    groupName = `Group ${uniq()}`;
    await gotoDashboard(page, "/dash/groups");

    const form = page.locator("#new-group form");
    await clickAndExpectVisible(
      page.getByRole("button", { name: "New group" }),
      form,
    );
    await form.locator('input[name="name"]').fill(groupName);
    await form.locator('button[type="submit"]').click();

    await expect(page).toHaveURL(/\/dash\/groups\/.+/);
    await expect(
      page.getByRole("link", { name: "OAuth", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: "Router", exact: true }),
    ).toBeVisible();
    await expect(
      page
        .getByRole("main")
        .getByRole("link", { name: "Connectors", exact: true }),
    ).toBeVisible();
    groupUrl = page.url();
  });

  test("mint a group connector credential", async ({ page }) => {
    expect(groupUrl, "group test must run first").not.toBe("");

    await gotoDashboard(page, new URL(groupUrl).pathname + "?tab=connectors");
    const form = page.locator("#group-connector-token-form");
    await form.locator('input[name="name"]').fill(`Mac ${uniq()}`);
    await form.locator('input[name="alias"]').fill("mac");
    await form.locator('button[type="submit"]').click();

    await expect(
      page.getByText(
        "This connector credential is shown only once. Copy it now.",
      ),
    ).toBeVisible();
    await expect(page.getByText("salix-connect --server")).toBeVisible();
    await expect(page.getByText("SALIX_CONNECTOR_TOKEN=")).toBeVisible();
  });

  test("create an agent in the group", async ({ page }) => {
    expect(groupName, "group test must run first").not.toBe("");
    expect(templateName, "template test must run first").not.toBe("");

    await gotoDashboard(page, "/dash/agents/new");
    const form = page.locator("form[phx-submit=create]");
    const agentName = `Agent ${uniq()}`;
    await form.locator('input[name="name"]').fill(agentName);
    await form
      .locator('select[name="group_id"]')
      .selectOption({ label: groupName });
    const models = form.locator('select[name="template_id"]');
    await expect(models.locator(`option[value="${templateId}"]`)).toHaveText(
      `mock-model — ${templateName}`,
    );
    await models.selectOption(templateId);
    await form.locator('button[type="submit"]').click();

    // Lands on the agent detail page.
    await expect(page).toHaveURL(/\/dash\/agents\/.+/);
    await expect(page.getByRole("heading", { name: agentName })).toBeVisible();
    agentUrl = page.url();
  });

  test("agent detail keeps long IDs and actions inside the header", async ({ page }) => {
    expect(agentUrl).not.toBe("");
    for (const width of [1440, 1024, 768, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await gotoDashboard(page, new URL(agentUrl).pathname);
      const header = page.getByRole("heading").first().locator("../../..");
      const id = header.locator("p.font-mono");
      await expect(id).toContainText(new URL(agentUrl).pathname.split("/").pop()!);
      const bounds = await header.boundingBox();
      expect(bounds).not.toBeNull();
      for (const name of ["Sessions", "Group conversations", "Files", "Wake", "Cancel", "Delete"]) {
        const action = header.getByRole(/Sessions|Group conversations|Files/.test(name) ? "link" : "button", { name, exact: true });
        const box = await action.boundingBox();
        expect(box!.x).toBeGreaterThanOrEqual(bounds!.x);
        expect(box!.x + box!.width).toBeLessThanOrEqual(bounds!.x + bounds!.width + 1);
        expect(await action.evaluate(el => el.scrollHeight <= el.clientHeight + 1 && el.scrollWidth <= el.clientWidth + 1)).toBe(true);
        await action.focus();
        await expect(action).toBeFocused();
      }
      expect(await id.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
    }
  });

  test("subscription import remains usable in short windows", async ({ page }) => {
    for (const [width, height] of [[1440, 900], [1024, 600], [768, 450], [390, 450]]) {
      await page.setViewportSize({ width, height });
      await gotoDashboard(page, "/dash/account-pool");
      const open = page.getByRole("button", { name: "Import", exact: true });
      await open.click();
      const panel = page.locator("#subscription-dialog-container");
      await expect(panel).toBeVisible();
      const box = await panel.boundingBox();
      expect(box!.y).toBeGreaterThanOrEqual(0);
      expect(box!.y + box!.height).toBeLessThanOrEqual(height);
      await expect(panel.getByRole("heading", { name: "Import credentials" })).toBeInViewport();
      const close = panel.getByRole("button", { name: "Close", exact: true });
      await close.focus();
      await expect(close).toBeFocused();
      const submit = panel.getByRole("button", { name: "Import subscription", exact: true });
      await submit.scrollIntoViewIfNeeded();
      await expect(submit).toBeInViewport();
      await submit.focus();
      await page.keyboard.press("Tab");
      expect(await panel.evaluate(el => el.contains(document.activeElement))).toBe(true);
      await panel.getByLabel("Or paste credential JSON").fill("not-json");
      await submit.click();
      await expect(panel.getByRole("alert")).toBeVisible();
      await submit.scrollIntoViewIfNeeded();
      await expect(submit).toBeInViewport();
      await page.keyboard.press("Escape");
      await expect(panel).toHaveCount(0);
      await open.click();
      await expect(panel).toBeVisible();
      await page.mouse.click(5, 5);
      await expect(panel).toHaveCount(0);
      await open.click();
      await close.click();
      await expect(panel).toHaveCount(0);
    }
  });

  test("default modal keeps its existing desktop behavior", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await gotoDashboard(page, "/dash/groups");
    await page.getByRole("button", { name: "New group", exact: true }).click();
    const panel = page.locator("#new-group-container");
    await expect(panel).toBeVisible();
    expect(await panel.evaluate(el => getComputedStyle(el).maxHeight)).toBe("none");
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
  });

  test("talk in a group conversation", async ({ page }) => {
    expect(groupUrl, "group test must run first").not.toBe("");
    expect(agentUrl, "agent test must run first").not.toBe("");

    // Conversations are group-level IM containers. The agent page can link here,
    // but the dashboard must not recreate the old agent-bound conversation route.
    await gotoDashboard(
      page,
      new URL(groupUrl).pathname + "?tab=conversations",
    );
    const createForm = page.locator("#group-conversation-form");
    await createForm.locator('input[name="title"]').fill(`Chat ${uniq()}`);
    await createForm.locator('button[type="submit"]').click();

    // On the conversation page, send a message and see it in the transcript.
    await expect(page).toHaveURL(
      /\/dash\/groups\/.+tab=conversations&conversation_id=.+/,
    );
    const msg = `hello from e2e ${uniq()}`;
    const sendForm = page.locator("form[phx-submit=send-conversation]");
    await sendForm.locator('input[name="text"]').fill(msg);
    await sendForm.locator('button[type="submit"]').click();
    await expect(
      page.locator("#conversation-messages").getByText(msg),
    ).toBeVisible();
  });

  test("oauth provider apps render", async ({ page }) => {
    await gotoDashboard(page, "/dash/oauth");
    await expect(
      page.getByRole("heading", { name: "OAuth provider apps" }),
    ).toBeVisible();
    // At least one provider card with a save form is present.
    await expect(page.locator("form[phx-submit=save]").first()).toBeVisible();
  });

  test("IM config saves a JSON document", async ({ page }) => {
    await gotoDashboard(page, "/dash/im-config");
    const form = page.locator("form[phx-submit=save]");
    await form
      .locator('textarea[name="config"]')
      .fill('{"slack":{"bot_token":"xoxb-e2e"}}');
    await form.locator('button[type="submit"]').click();
    await expect(page.getByText("IM config saved.")).toBeVisible();
  });

  test("logout returns to the login form", async ({ page }) => {
    await page.getByRole("link", { name: "Sign out" }).click();
    await expect(page).toHaveURL(/\/dash\/login$/);
    await expect(page.locator('input[name="token"]')).toBeVisible();
  });
});
