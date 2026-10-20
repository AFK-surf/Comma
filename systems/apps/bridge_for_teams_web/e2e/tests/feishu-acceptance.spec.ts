import { test, expect, type Page } from "@playwright/test";

// End-to-end acceptance of the Feishu binding bot half against the
// REAL running dashboard (:4101) + Salix in the same BEAM. Auth via the guarded
// /dev/login bypass. Drives the Settings API, the React Agent Swarms list and
// the React Connections page of the new Agent Swarm.
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

  // (2) New project → Connections: the Feishu section offers the org's bot app
  // in its app picker (no credential inputs, no "no bot app" prompt).
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

  await page.goto(
    `/orgs/${ORG_SLUG}/projects/${projId}/connections?provider=feishu`,
  );
  const feishu = page
    .getByRole("main")
    .getByRole("region", { name: "Feishu", exact: true });
  // The route note also says "Connect a Feishu app above."
  // Swarm creation returns before its group finishes provisioning. Exercise
  // the offered retry while it prepares, then require the actual app picker.
  await expect(async () => {
    const messaging = page.getByRole("region", {
      name: "Messaging",
      exact: true,
    });
    if (
      await messaging
        .getByText("Agent Swarm is still preparing. Retry shortly.")
        .isVisible()
    ) {
      await messaging
        .getByRole("button", { name: "Retry", exact: true })
        .click();
    }
    await expect(
      feishu.getByRole("heading", {
        name: "Connect a Feishu app",
        exact: true,
      }),
    ).toBeVisible({ timeout: 1_000 });
    // A second without the heading only sends the block round again.
  }).toPass();
  await expect(
    feishu.getByText(
      "No organization Feishu app has the group bot enabled yet.",
    ),
  ).toHaveCount(0);
  // The seeded org may hold other apps; this one is among the choices.
  await feishu.getByRole("button", { name: /Feishu app$/ }).click();
  await expect(
    page.getByRole("option", { name: "E2E Bot App" }).first(),
  ).toBeVisible();
  await page.keyboard.press("Escape");
  // Salix sources the secrets from the org app: nothing secret is asked here.
  await expect(feishu.locator('input[type="password"]')).toHaveCount(0);
});
