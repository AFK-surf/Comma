import { test, expect, type Page } from "@playwright/test";

// End-to-end acceptance of the Feishu binding bot half against the
// REAL running dashboard (:4101) + Salix in the same BEAM. Auth via the guarded
// /dev/login bypass. Drives the Settings API, the React Agent Swarms list and
// the actual LiveView project UI (not LiveViewTest).
const EMAIL = process.env.E2E_USER_EMAIL || "e2e@example.com";
const ORG_SLUG = "e2e";

const stableAppId = (suffix: string) =>
  `cli_e2e_accept_${suffix.replace(/[^a-z0-9_]/gi, "_")}`;
const uniq = () =>
  Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);

// Organization pages are the React dashboard, which carries the session's
// CSRF token in its page.
const SPA_PAGE = `/orgs/${ORG_SLUG}`;

async function login(page: Page) {
  await page.goto(
    `/dev/login?email=${encodeURIComponent(EMAIL)}&to=${SPA_PAGE}`,
  );
  await expect(page).toHaveURL(new RegExp(`${SPA_PAGE}$`));
  await expect(page.locator('meta[name="csrf-token"]')).toHaveCount(1);
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

  // (1) Settings → Integrations registers a bot-enabled app through the API
  // the React page uses. The write-only secret + verification token fan out
  // to Salix's tenant store (no Feishu API call here).
  await page.goto(SPA_PAGE);
  const token = await page
    .locator('meta[name="csrf-token"]')
    .getAttribute("content");
  const response = await page.request.post(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/settings/integrations/feishu/apps`,
    {
      headers: { "x-csrf-token": token || "" },
      data: {
        display_name: "E2E Bot App",
        app_id: appId,
        app_secret: "e2e-bot-secret",
        verification_token: "e2e-vtok",
        bot_enabled: true,
      },
    },
  );
  expect(response.ok(), await response.text()).toBe(true);
  const body = await response.text();
  expect(body).not.toContain("e2e-bot-secret");
  const { data } = JSON.parse(body);
  // the seeded org may already hold other apps
  expect(data.apps).toContainEqual(
    expect.objectContaining({
      app_id: appId,
      bot_enabled: true,
      app_secret_configured: true,
      verification_token_configured: true,
    }),
  );

  // (2) New project → integrations: the provider list opens focused Feishu setup
  // with a binding select (no credential inputs, no "no bot binding" prompt).
  await page.goto(`/orgs/${ORG_SLUG}/projects`);
  const projName = `feishu-acc-${uniq()}`;
  await page.getByRole("button", { name: "New Agent Swarm" }).click();
  const npf = page.getByRole("dialog", { name: "New Agent Swarm" });
  await expect(npf).toBeVisible();
  await npf.getByLabel("Name").fill(projName);
  await npf.getByLabel("Slug").fill(projName);
  await npf.getByRole("button", { name: "Create Agent Swarm" }).click();
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
