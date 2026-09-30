import { test, expect, type Page } from "@playwright/test";

// End-to-end acceptance of the Feishu binding bot half against the
// REAL running dashboard (:4101) + Salix in the same BEAM. Auth via the guarded
// /dev/login bypass. Drives the actual LiveView UI (not LiveViewTest).
const EMAIL = process.env.E2E_USER_EMAIL || "e2e@example.com";
const ORG_SLUG = "e2e";

const stableAppId = (suffix: string) =>
  `cli_e2e_accept_${suffix.replace(/[^a-z0-9_]/gi, "_")}`;
const uniq = () =>
  Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);

async function login(page: Page) {
  // Land on a LiveView page: the organization Overview is the React dashboard.
  await page.goto(
    `/dev/login?email=${encodeURIComponent(EMAIL)}&to=/orgs/${ORG_SLUG}/projects`,
  );
  await expect(page).toHaveURL(new RegExp(`/orgs/${ORG_SLUG}/projects$`));
  await expectLiveViewConnected(page);
}

async function gotoDashboard(page: Page, path: string) {
  await page.goto(path);
  await expectLiveViewConnected(page);
}

async function expectLiveViewConnected(page: Page) {
  const liveViewRoot = page.locator("[data-phx-main]").first();
  await expect(liveViewRoot).toBeVisible();
  await expect(liveViewRoot).toHaveClass(/(^|\s)phx-connected(\s|$)/);
}

test("Feishu bot-half: register a bot binding, then the project card offers it", async ({
  page,
}, testInfo) => {
  await login(page);
  const appId = stableAppId(
    `${process.env.GITHUB_RUN_ID || "local"}_${testInfo.repeatEachIndex}`,
  );

  // (1) Feishu apps tab — register a bot-enabled app. The write-only secret +
  // verification token fan out to Salix's tenant store (no Feishu API call here).
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings/feishu`);
  const form = page.locator("#feishu-binding-form");
  await expect(form).toBeVisible();
  await form
    .locator('input[name="feishu_binding[display_name]"]')
    .fill("E2E Bot App");
  await form.locator('input[name="feishu_binding[app_id]"]').fill(appId);
  await form
    .locator('input[name="feishu_binding[app_secret]"]')
    .fill("e2e-bot-secret");
  await form
    .locator('input[name="feishu_binding[verification_token]"]')
    .fill("e2e-vtok");
  await form
    .locator('input[type="checkbox"][name="feishu_binding[bot_enabled]"]')
    .check();

  // reveal toggle: a client-only Show/Hide button flips the secret input
  // between password and text (it can only ever show what's typed this session).
  const secret = form.locator('input[name="feishu_binding[app_secret]"]');
  await expect(secret).toHaveAttribute("type", "password");
  await secret.locator("xpath=following-sibling::button[1]").click();
  await expect(secret).toHaveAttribute("type", "text");

  await form.locator('button[type="submit"]').click();
  await expect(page.getByText("Feishu app saved.")).toBeVisible();
  // scope to this app's row (the seeded org may already hold other bindings)
  const bindingRow = page.locator("#feishu-bindings tr", { hasText: appId });
  await expect(bindingRow).toBeVisible();
  await expect(bindingRow).toContainText("Bot");

  // (2) New project → integrations: the provider list opens focused Feishu setup
  // with a binding select (no credential inputs, no "no bot binding" prompt).
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projName = `feishu-acc-${uniq()}`;
  await page.locator("#new-project-button").click();
  const npf = page.locator("#new-project-form");
  await expect(npf).toBeVisible();
  await npf.locator('input[name="project[name]"]').fill(projName);
  await npf.locator('input[name="project[slug]"]').fill(projName);
  await npf.locator('button[type="submit"]').click();
  const row = page.locator("#projects").getByText(projName).first();
  await expect(row).toBeVisible();
  await row.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);
  const projId = page.url().match(/projects\/([0-9a-f-]+)/)![1];

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projId}/integrations`,
  );
  await page
    .locator("#integration-provider-feishu")
    .getByRole("button", { name: "Configure" })
    .click();
  const connectForm = page.locator(
    "#integration-setup-panel #create-feishu-connect-form",
  );
  await expect(connectForm).toBeVisible();
  const appSelect = connectForm.locator(
    'select[name="feishu_connect[app_id]"]',
  );
  await expect(appSelect).toBeVisible();
  await expect(
    connectForm.locator('input[name="feishu_connect[app_secret]"]'),
  ).toHaveCount(0);
  await expect(
    page.getByText("No org Feishu app has bot enabled yet"),
  ).toHaveCount(0);
});
