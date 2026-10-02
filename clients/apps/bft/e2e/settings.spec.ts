import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const cli = {
  api_base_url: "https://bft.example",
  config_path: "~/.bridge-for-teams/cli.json",
  install_command: 'curl -fsSL "https://bft.example/v1/cli/install.sh" | sh',
  login_command: 'bft auth login --url "https://bft.example" --output text',
  sessions: [
    {
      id: "s-1",
      client_name: "bft CLI",
      device: "mei-mbp",
      created_at: "2026-09-20T00:00:00Z",
      last_seen_at: "2026-09-30T00:00:00Z",
      expires_at: "2026-12-30T00:00:00Z",
    },
  ],
  sessions_truncated: true,
};

const general = (slug = "acme", name = "Acme Robotics") => ({
  organization: { name, slug, icon: null, default_locale: null },
  locale_options: [
    { value: "en", label: "English" },
    { value: "zh_Hans", label: "中文（简体）" },
  ],
  cli,
});

const models = {
  catalog_status: "ok",
  catalog: [
    { template_id: "t-sonnet", label: "Claude Sonnet", model: "sonnet", name: null },
    { template_id: "t-opus", label: "Claude Opus", model: "opus", name: null },
  ],
  allowed_template_ids: ["t-sonnet"],
  default_template_id: "t-sonnet",
  default_router_template_id: null,
  default_options: {
    router: [
      { value: "t-sonnet", label: "Claude Sonnet" },
      { value: "t-opus", label: "Claude Opus" },
    ],
    worker: [
      { value: "t-sonnet", label: "Claude Sonnet" },
      { value: "t-opus", label: "Claude Opus" },
    ],
  },
  platform_defaults: { router: { label: "Claude Haiku" }, worker: null },
};

const sso = {
  connection: null,
  feishu_app: null,
  redirect_uri: "https://bft.example/auth/callback",
  providers: ["generic_oidc", "feishu"],
  roles: ["admin", "member"],
  provisioning_policies: ["jit", "existing_identity"],
  default_feishu_scope: "contact:user.base:readonly",
};

const signal = (override: string | null = null) => ({
  status: "ok",
  override_e164: override,
  platform_e164: "+15550100",
  effective_e164: override ?? "+15550100",
});

const integrations = {
  oauth: {
    status: "ok",
    apps: [
      {
        provider: "linear",
        label: "Linear",
        client_id: null,
        client_secret_configured: false,
        source: null,
        configured: false,
        setup_href: "https://linear.app/settings/api/applications/new",
      },
    ],
    waiting_members: { names: ["Priya Raman"], truncated: false },
  },
  composio: {
    status: "unavailable",
    enabled: false,
    api_key_configured: false,
    base_url: null,
    source: null,
  },
  signal: signal(),
  feishu: {
    apps: [
      {
        id: "fa-1",
        app_id: "cli_a1",
        display_name: "Acme Feishu",
        sso_enabled: true,
        bot_enabled: true,
        app_secret_configured: true,
        verification_token_configured: true,
        encrypt_key_configured: false,
        routes: [],
      },
    ],
    apps_truncated: false,
    routes_status: "unavailable",
    projects: [{ id: "p-1", name: "Support Desk" }],
    projects_truncated: false,
    redirect_uri: "https://bft.example/auth/callback",
    scope_cards: [
      { id: "combined", title: "SSO + group bot", description: null, json: "{}" },
    ],
    optional_scopes: [],
  },
};

const pages: Record<string, unknown> = {
  "/orgs/acme/settings/general": general(),
  "/orgs/acme/settings/models": models,
  "/orgs/acme/settings/models/templates": { templates: [] },
  "/orgs/acme/settings/models/accounts": { accounts: [], next: null },
  "/orgs/acme/settings/sso": sso,
  "/orgs/acme/settings/integrations": integrations,
};

type Reply = { status: number; body: unknown };

async function openSettings(
  page: Page,
  path: string,
  write?: (request: RecordedRequest) => Reply | undefined,
  reads: Record<string, unknown> = {}
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.method !== "GET") return write?.(request);
    if (request.path === "/orgs/acme/context") return ok(context);
    const data = reads[request.path] ?? pages[request.path];
    return data ? ok(data) : write?.(request);
  });
  await page.goto(path);
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("each Settings page renders from its submenu entry", async ({ page }) => {
  await openSettings(page, "/orgs/acme/settings");
  await expect(page.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Organization name" })).toHaveValue(
    "Acme Robotics"
  );
  await expect(page.getByText("Showing the newest 1 sessions.")).toBeVisible();

  const submenu = page.getByRole("navigation", { name: "Organization navigation" });
  await submenu.getByRole("link", { name: "AI models" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "AI models" })
  ).toBeVisible();
  await expect(page.getByRole("checkbox", { name: "Claude Sonnet" })).toBeChecked();
  await expect(page.getByRole("checkbox", { name: "Claude Opus" })).not.toBeChecked();
  // Private templates and organization accounts are sections of the page.
  await expect(page.getByRole("heading", { name: "Private templates" })).toBeVisible();
  await expect(page.getByText("No organization accounts yet.")).toBeVisible();

  await submenu.getByRole("link", { name: "Single sign-on" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Single sign-on" })
  ).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Issuer URL" })).toBeVisible();
  // Switching to Feishu swaps the fields on the client.
  await page.getByRole("button", { name: /Provider/ }).click();
  await page.getByRole("option", { name: "Feishu" }).click();
  await expect(page.getByRole("textbox", { name: "Issuer URL" })).toHaveCount(0);
  await expect(
    page.getByText("No Feishu app is enabled for sign-in yet.")
  ).toBeVisible();

  await submenu.getByRole("link", { name: "Integrations" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Integrations" })
  ).toBeVisible();
  await expect(page.getByText("1 member is waiting for an OAuth app")).toBeVisible();
  await expect(page.locator("#composio")).toContainText("Couldn't reach the runtime");
  // An unverified route lookup offers no connect form.
  await expect(page.locator("#feishu")).toContainText(
    "Could not verify the Agent Swarm routes."
  );
  await expect(page.getByRole("button", { name: "Connect" })).toHaveCount(0);
});

test("a Signal save sends the CSRF token and shows the returned section", async ({
  page,
}) => {
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/integrations",
    (request) =>
      request.path === "/orgs/acme/settings/integrations/signal"
        ? ok(signal("+15550123"))
        : undefined
  );
  const section = page.locator("#signal");
  await section
    .getByRole("textbox", { name: "Organization number" })
    .fill(" +15550123 ");
  await section.getByRole("button", { name: "Save" }).click();
  await expect(section.getByRole("status")).toHaveText("Saved");
  await expect(section.locator("dd").first()).toHaveText("+15550123");
  expect(writes(requests)).toEqual([
    {
      method: "PUT",
      path: "/orgs/acme/settings/integrations/signal",
      search: "",
      csrf,
      body: { number: "+15550123" },
    },
  ]);
});

test("a refused default model is shown under its field", async ({ page }) => {
  const requests = await openSettings(page, "/orgs/acme/settings/models", () => ({
    status: 422,
    body: {
      ok: false,
      error: {
        code: "default_model_not_allowed",
        message: "The default model must be one of the allowed models.",
        details: { fields: ["default_template_id"] },
      },
    },
  }));
  await page.getByRole("button", { name: /Worker$/ }).click();
  await page.getByRole("option", { name: "Claude Opus" }).click();
  await page.getByRole("button", { name: "Save" }).click();

  const message = "The default model must be one of the allowed models.";
  // Once under the Worker select and once beside Save.
  await expect(page.getByText(message)).toHaveCount(2);
  expect(writes(requests)).toEqual([
    {
      method: "PUT",
      path: "/orgs/acme/settings/models",
      search: "",
      csrf,
      body: {
        allowed_template_ids: ["t-sonnet"],
        default_template_id: "t-opus",
        default_router_template_id: null,
      },
    },
  ]);
});

test("allowlist IDs missing from the catalog are not saved back", async ({ page }) => {
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/models",
    () => ok(models),
    {
      "/orgs/acme/settings/models": {
        ...models,
        allowed_template_ids: ["t-sonnet", "t-retired"],
        default_template_id: null,
      },
    }
  );
  // Clearing the only box shown means "all models".
  const sonnet = page.getByRole("checkbox", { name: "Claude Sonnet" });
  // The styled box covers the input; click its label like a user does.
  await page.locator(".bft-checklist").getByText("Claude Sonnet").click();
  await expect(sonnet).not.toBeChecked();
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved");
  expect(writes(requests).map((request) => request.body)).toEqual([
    {
      allowed_template_ids: [],
      default_template_id: null,
      default_router_template_id: null,
    },
  ]);
});

test("an icon over the server's data URL limit is refused on the client", async ({
  page,
}) => {
  await openSettings(page, "/orgs/acme/settings");
  const upload = page.locator('input[type="file"]');
  const tooLarge = "Choose an image of 374 KB or less.";
  // 375 KB encodes to 512,000 base64 characters; the data URL prefix tips it over.
  await upload.setInputFiles({
    name: "icon.png",
    mimeType: "image/png",
    buffer: Buffer.alloc(375 * 1024),
  });
  await expect(page.getByText(tooLarge)).toBeVisible();
  await upload.setInputFiles({
    name: "icon.png",
    mimeType: "image/png",
    buffer: Buffer.alloc(374 * 1024),
  });
  await expect(page.getByText(tooLarge)).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Remove", exact: true })).toBeVisible();
});

const feishuRoute = (connect_id: string, disabled: boolean) => ({
  project_id: "p-1",
  project_name: "Support Desk",
  salix_group_id: "g-1",
  connect_id,
  disabled,
  href: "/orgs/acme/projects/p-1/integrations",
});

test("only a Feishu bot app without routes offers to connect", async ({ page }) => {
  const app = integrations.feishu.apps[0]!;
  await openSettings(page, "/orgs/acme/settings/integrations", undefined, {
    "/orgs/acme/settings/integrations": {
      ...integrations,
      feishu: {
        ...integrations.feishu,
        routes_status: "ok",
        projects: [...integrations.feishu.projects, { id: "p-2", name: "Ops" }],
        projects_truncated: true,
        apps: [
          {
            ...app,
            id: "fa-1",
            app_id: "cli_active",
            routes: [feishuRoute("c-1", false)],
          },
          {
            ...app,
            id: "fa-2",
            app_id: "cli_disabled",
            routes: [feishuRoute("c-2", true)],
          },
          { ...app, id: "fa-3", app_id: "cli_free", routes: [] },
        ],
      },
    },
  });
  const feishu = page.locator("#feishu");
  await expect(
    feishu.getByRole("button", { name: "Disable the route to Support Desk" })
  ).toHaveCount(1);
  // Salix keeps an app on its Agent Swarm while a route exists, even disabled.
  await expect(feishu.getByRole("button", { name: "Connect" })).toHaveCount(1);
  await expect(
    feishu
      .locator("li")
      .filter({ hasText: "cli_free" })
      .getByRole("button", { name: "Connect" })
  ).toBeVisible();
  await expect(
    feishu.getByText("Showing routes for the first 2 Agent Swarms.")
  ).toBeVisible();
});

test("the retired Feishu tab address opens its Integrations section", async ({
  page,
}) => {
  // One column: Feishu is the last section, below the fold.
  await page.setViewportSize({ width: 900, height: 700 });
  await openSettings(page, "/orgs/acme/settings/feishu");
  await expect(page).toHaveURL(/\/orgs\/acme\/settings\/integrations#feishu$/);
  await expect(
    page.getByRole("heading", { level: 1, name: "Integrations" })
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { level: 2, name: "Feishu" })
  ).toBeInViewport();
  await expect(
    page.getByRole("heading", { level: 2, name: "OAuth apps" })
  ).not.toBeInViewport();
});

test("changing the slug moves to the new address", async ({ page }) => {
  const renamed = { ...context, org: { ...context.org, slug: "acme-labs" } };
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme-labs/context") return ok(renamed);
    if (request.path === "/orgs/acme/settings/general" && request.method === "GET") {
      return ok(general());
    }
    if (request.path === "/orgs/acme/settings/general") return ok(general("acme-labs"));
    if (request.path === "/orgs/acme-labs/settings/general")
      return ok(general("acme-labs"));
    return undefined;
  });
  await page.goto("/orgs/acme/settings");
  await page.getByRole("textbox", { name: "Slug" }).fill("acme-labs");
  await page.getByRole("button", { name: "Save" }).click();

  await expect(page).toHaveURL(/\/orgs\/acme-labs\/settings$/);
  await expect(page.getByRole("textbox", { name: "Slug" })).toHaveValue("acme-labs");
  expect(writes(requests)).toEqual([
    {
      method: "PATCH",
      path: "/orgs/acme/settings/general",
      search: "",
      csrf,
      body: { slug: "acme-labs" },
    },
  ]);
  // The org context of the new slug is loaded for the shell.
  expect(requests.some((request) => request.path === "/orgs/acme-labs/context")).toBe(
    true
  );
});

test("a member who reaches Settings sees the forbidden state", async ({ page }) => {
  await injectCsrfToken(page);
  await routeApi(page, (request) =>
    request.path === "/orgs/acme/context"
      ? ok(context)
      : {
          status: 403,
          body: {
            ok: false,
            error: {
              code: "forbidden",
              message: "Only organization admins can manage settings.",
              details: {},
            },
          },
        }
  );
  await page.goto("/orgs/acme/settings/sso");
  await expect(page.getByRole("heading", { name: "Admins only" })).toBeVisible();
});
