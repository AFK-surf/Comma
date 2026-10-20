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

const catalogModel = (model: string, label: string, vendor: string) => ({
  key: `catalog:${model}`,
  choice: { kind: "catalog", model },
  label,
  vendor,
});
const sonnet = catalogModel("claude-sonnet-4-6", "Claude Sonnet", "anthropic");
const opus = catalogModel("claude-opus-4-8", "Claude Opus", "anthropic");
const gpt = catalogModel("gpt-5.5", "GPT-5.5", "openai");

const models = {
  catalog_status: "ok",
  catalog: [sonnet, opus, gpt],
  allowed_models: [sonnet],
  default_router_model: null,
  default_task_model: sonnet,
  default_options: { router: [sonnet, opus], task: [sonnet, opus] },
  platform_defaults: {
    router: { label: "Claude Haiku", model_icon: null },
    task: null,
  },
};

const sso = {
  connection: null,
  feishu_app: null,
  redirect_uri: "https://bft.example/auth/callback",
  providers: ["generic_oidc", "feishu", "lark"],
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
    projects_shown: 1,
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
  // Organization accounts are a section of the page.
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
  // An unverified route lookup is said, not shown as "no routes".
  await expect(page.locator("#feishu")).toContainText(
    "Could not read the Agent Swarm routes."
  );
});

test("choosing Lark saves its own App ID and a write-only App Secret", async ({
  page,
}) => {
  const feishuConnection = {
    provider: "feishu",
    issuer: null,
    client_id: "cli_feishu",
    client_secret_configured: true,
    allowed_domains: [],
    default_role: "member",
    provider_config: {
      scope: "contact:user.base:readonly",
      provisioning_policy: "jit",
    },
  };
  const larkConnection = {
    ...feishuConnection,
    provider: "lark",
    client_id: "cli_lark_app",
    provider_config: {
      scope: "contact:user.email:readonly",
      provisioning_policy: "jit",
    },
  };
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/sso",
    (request) =>
      request.method === "PUT" && request.path === "/orgs/acme/settings/sso"
        ? ok({ ...sso, connection: larkConnection })
        : undefined,
    { "/orgs/acme/settings/sso": { ...sso, connection: feishuConnection } }
  );
  await expect(page.getByRole("textbox", { name: "Feishu scopes" })).toHaveValue(
    "contact:user.base:readonly"
  );

  await page.getByRole("button", { name: /Provider/ }).click();
  await page.getByRole("option", { name: "Lark" }).click();
  // Nothing of the Feishu connection carries over to the Lark fields.
  const appId = page.getByRole("textbox", { name: "App ID" });
  const secret = page.getByRole("textbox", { name: "App Secret" });
  const scopes = page.getByRole("textbox", { name: "Lark scopes" });
  await expect(appId).toHaveValue("");
  await expect(scopes).toHaveValue("");
  await expect(secret).toHaveAttribute("type", "password");
  await expect(page.getByText("Write-only. It is never shown again.")).toBeVisible();
  await expect(
    page.getByText("add this address to the redirect URLs", { exact: false })
  ).toBeVisible();
  await expect(page.getByLabel("Redirect URI", { exact: true })).toHaveText(
    "https://bft.example/auth/callback"
  );

  await appId.fill(" cli_lark_app ");
  await secret.fill("test-only-lark-secret");
  await scopes.fill("contact:user.email:readonly");
  await page.getByRole("button", { name: "Save", exact: true }).click();

  await expect(
    page.getByText("Configured. Leave blank to keep the current value.")
  ).toBeVisible();
  await expect(secret).toHaveValue("");
  await expect(appId).toHaveValue("cli_lark_app");
  expect(writes(requests)).toMatchObject([
    {
      method: "PUT",
      path: "/orgs/acme/settings/sso",
      body: {
        provider: "lark",
        client_id: "cli_lark_app",
        client_secret: "test-only-lark-secret",
        default_role: "member",
        provider_config: {
          scope: "contact:user.email:readonly",
          provisioning_policy: "jit",
        },
      },
    },
  ]);
});

test("a Signal number change sends the CSRF token and shows the returned number", async ({
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
  await expect(section.getByText("Platform number")).toBeVisible();
  await section.getByRole("button", { name: "Change Signal number" }).click();
  const dialog = page.getByRole("dialog", { name: "Signal number" });
  await dialog
    .getByRole("textbox", { name: "Organization number" })
    .fill(" +15550123 ");
  await dialog.getByRole("button", { name: "Save", exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(section.getByText("+15550123")).toBeVisible();
  await expect(section.getByText("Your organization's number")).toBeVisible();
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

test("each OAuth app and Composio say whether they work and whose credentials run", async ({
  page,
}) => {
  const linear = integrations.oauth.apps[0]!;
  const oauth = {
    ...integrations.oauth,
    apps: [
      linear,
      {
        ...linear,
        provider: "notion",
        label: "Notion",
        source: "default",
        configured: true,
      },
      {
        ...linear,
        provider: "github",
        label: "GitHub",
        client_id: "gh-client",
        client_secret_configured: true,
        source: "org",
        configured: true,
      },
    ],
  };
  const composio = { ...integrations.composio, status: "ok" };
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/integrations",
    (request) =>
      request.path === "/orgs/acme/settings/integrations/composio"
        ? ok({ ...composio, enabled: true, api_key_configured: true, source: "org" })
        : undefined,
    { "/orgs/acme/settings/integrations": { ...integrations, oauth, composio } }
  );
  const rows = page.locator("#oauth").getByRole("listitem");
  await expect(rows.filter({ hasText: "Linear" })).toContainText("Not set up");
  // The platform's app already works: its own app is offered, with nothing to remove.
  const notion = rows.filter({ hasText: "Notion" });
  await expect(notion).toContainText("Ready");
  await expect(notion).toContainText("Platform's shared app");
  await expect(
    notion.getByRole("button", { name: "Use your own Notion OAuth app" })
  ).toBeVisible();
  await expect(notion.getByRole("button", { name: /Remove/ })).toHaveCount(0);
  const github = rows.filter({ hasText: "GitHub" });
  await expect(github).toContainText("Your organization's app · Client ID gh-client");
  await expect(
    github.getByRole("button", { name: "Remove GitHub OAuth app" })
  ).toBeVisible();

  const section = page.locator("#composio");
  await expect(section).toContainText("Not set up");
  await section.getByRole("button", { name: "Set up Composio" }).click();
  const dialog = page.getByRole("dialog", { name: "Composio" });
  await dialog.getByRole("textbox", { name: "API key" }).fill("test-only-composio-key");
  await dialog.getByRole("button", { name: "Save", exact: true }).click();
  await expect(dialog).not.toBeVisible();
  // A first setup is saved turned on.
  expect(writes(requests)).toMatchObject([
    { method: "PUT", body: { api_key: "test-only-composio-key", enabled: true } },
  ]);
  await expect(section).toContainText("Your organization's key");
  await expect(
    section.getByRole("button", { name: "Remove Composio settings" })
  ).toBeVisible();
});

test("a refused default model is shown under its field", async ({ page }) => {
  const requests = await openSettings(page, "/orgs/acme/settings/models", () => ({
    status: 422,
    body: {
      ok: false,
      error: {
        code: "default_model_not_allowed",
        message: "The default model must be one of the allowed models.",
        details: { fields: ["default_task_model"] },
      },
    },
  }));
  await expect(
    page.getByText(
      "Tasks of an Agent Swarm without its own default Task model run this model."
    )
  ).toBeVisible();
  await page.getByRole("button", { name: /Default Task model$/ }).click();
  await page.getByRole("option", { name: "Claude Opus" }).click();
  await page.getByRole("button", { name: "Save" }).click();

  const message = "The default model must be one of the allowed models.";
  // Once under the Task model select and once beside Save.
  await expect(page.getByText(message)).toHaveCount(2);
  expect(writes(requests)).toEqual([
    {
      method: "PUT",
      path: "/orgs/acme/settings/models",
      search: "",
      csrf,
      body: {
        allowed_models: [sonnet.choice],
        default_task_model: opus.choice,
        default_router_model: null,
      },
    },
  ]);
});

test("the filter narrows the allowlist and keeps hidden models checked", async ({
  page,
}) => {
  const requests = await openSettings(page, "/orgs/acme/settings/models", () =>
    ok({ ...models, allowed_models: [sonnet, gpt] })
  );
  await page.getByRole("searchbox", { name: "Filter models" }).fill("OpenAI");
  await expect(page.getByRole("checkbox", { name: "Claude Sonnet" })).toHaveCount(0);
  // The styled box covers the input; click its label like a user does.
  await page.locator(".bft-checklist").getByText("GPT-5.5").click();
  await expect(page.getByRole("checkbox", { name: "GPT-5.5" })).toBeChecked();
  await page.getByRole("searchbox", { name: "Filter models" }).fill("nothing");
  await expect(page.getByText("No models match this filter.")).toBeVisible();
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved");
  // Sonnet, hidden by the filter, is saved as well.
  expect(writes(requests).map((request) => request.body)).toEqual([
    {
      allowed_models: [sonnet.choice, gpt.choice],
      default_task_model: sonnet.choice,
      default_router_model: null,
    },
  ]);
});

const served = (
  option: ReturnType<typeof catalogModel>,
  served_by: string | null,
  plans: string[] = [],
  key_sources: string[] = []
) => ({ ...option, served_by, plans, key_sources });

/** The pay-per-use choice of a model, as the server offers it. */
const paid = (option: ReturnType<typeof catalogModel>, key_sources: string[]) => ({
  ...served(option, "api_key", [], key_sources),
  key: `${option.key}+paid`,
  choice: { ...option.choice, allow_paid: true },
});

test("allowed models are grouped by the account that serves them", async ({ page }) => {
  // Tall enough for the Task model options to open below their field.
  await page.setViewportSize({ width: 1280, height: 1400 });
  const astra = served(
    catalogModel("gpt-6-astra", "GPT-6 Astra", "openai"),
    "subscription",
    ["codex"],
    ["OpenRouter"]
  );
  const sol = served(
    catalogModel("gpt-6.1-sol", "GPT-6.1 Sol", "openai"),
    "subscription",
    ["codex"]
  );
  const astraPaid = paid(catalogModel("gpt-6-astra", "GPT-6 Astra", "openai"), [
    "OpenRouter",
  ]);
  const claude = paid(sonnet, ["OpenRouter"]);
  const old = served(catalogModel("gpt-4", "GPT-4", "openai"), null);
  const offered = [astra, sol, astraPaid, claude, old];
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/models",
    () => ok({ ...models, allowed_models: [] }),
    {
      "/orgs/acme/settings/models": {
        ...models,
        servable_status: "ok",
        catalog: offered,
        allowed_models: [],
        default_options: { router: offered, task: offered },
      },
    }
  );

  // Any served model is allowed until an admin narrows the list.
  await expect(
    page.getByRole("radio", { name: /Any model your accounts serve/ })
  ).toBeChecked();
  await expect(page.getByRole("checkbox", { name: "GPT-6 Astra" })).toHaveCount(0);
  await page.getByText("Only the models I select").click();

  // A subscription and pay-per-use keys are separate choices of a model.
  const codex = page.getByRole("button", { name: "Hide Codex subscription" });
  await expect(codex).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Hide Pay-per-use: OpenRouter" })
  ).toBeVisible();
  await expect(page.getByRole("checkbox", { name: "GPT-6 Astra" })).toHaveCount(2);
  await expect(page.getByText("Also available pay-per-use: OpenRouter")).toBeVisible();
  // A model no account serves is out of sight until asked for.
  await expect(page.getByRole("checkbox", { name: "GPT-4" })).toHaveCount(0);
  await page.getByRole("button", { name: "Show 1 model no account serves" }).click();
  await expect(page.getByRole("checkbox", { name: "GPT-4" })).toBeDisabled();

  // Search ignores case, spaces and punctuation, and finds sources too.
  const search = page.getByRole("searchbox", { name: "Filter models" });
  await search.fill("gpt6 astra");
  await expect(page.getByRole("checkbox", { name: "GPT-6.1 Sol" })).toHaveCount(0);
  await search.fill("sol 6.1");
  await expect(page.getByRole("checkbox", { name: "GPT-6.1 Sol" })).toBeVisible();
  await search.fill("openrouter");
  await expect(page.getByRole("checkbox", { name: "Claude Sonnet" })).toBeVisible();
  await expect(page.getByRole("checkbox", { name: "GPT-6.1 Sol" })).toHaveCount(0);
  await search.fill("");

  await expect(page.getByRole("button", { name: "Save" })).toBeDisabled();
  await page
    .getByRole("checkbox", { name: "Select every model in Codex subscription" })
    // The styled box covers the input and takes the click, like a user's.
    .check({ force: true });
  await expect(page.getByText("2 of 2 selected")).toBeVisible();
  await page.getByRole("checkbox", { name: "Claude Sonnet" }).check({ force: true });

  // The Task model default lists only models an account serves, by source.
  await page.getByRole("button", { name: /Default Task model$/ }).click();
  await expect(page.getByRole("option", { name: "GPT-4" })).toHaveCount(0);
  await page.getByRole("option", { name: "Claude Sonnet" }).click();
  await page.getByRole("button", { name: "Save" }).click();

  // The pay-per-use choice is saved as one, for the list and the default alike.
  expect(writes(requests).map((request) => request.body)).toEqual([
    {
      allowed_models: [astra.choice, sol.choice, claude.choice],
      default_task_model: claude.choice,
      default_router_model: null,
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
  href: "/orgs/acme/projects/p-1/connections?provider=feishu",
});

test("a Feishu bot app lists its routes read-only, each linking the swarm's Connections", async ({
  page,
}) => {
  const app = integrations.feishu.apps[0]!;
  await openSettings(page, "/orgs/acme/settings/integrations", undefined, {
    "/orgs/acme/settings/integrations": {
      ...integrations,
      feishu: {
        ...integrations.feishu,
        routes_status: "ok",
        projects_shown: 2,
        projects_truncated: true,
        apps: [
          {
            ...app,
            id: "fa-1",
            app_id: "cli_routed",
            display_name: "Routed bot",
            routes: [feishuRoute("c-1", false), feishuRoute("c-2", true)],
          },
          {
            ...app,
            id: "fa-2",
            app_id: "cli_free",
            display_name: "Free bot",
            routes: [],
          },
        ],
      },
    },
  });
  const feishu = page.locator("#feishu");
  const routes = feishu.getByRole("list", { name: "Agent Swarm routes of Routed bot" });
  await expect(routes.getByRole("listitem")).toHaveCount(2);
  await expect(routes.getByText("Active")).toBeVisible();
  await expect(routes.getByText("Disabled")).toBeVisible();
  for (const link of await routes.getByRole("link", { name: "Support Desk" }).all()) {
    await expect(link).toHaveAttribute(
      "href",
      "/orgs/acme/projects/p-1/connections?provider=feishu"
    );
  }
  await expect(
    feishu.getByText(
      "Not connected to an Agent Swarm yet. Connect it on the Agent Swarm's Connections page."
    )
  ).toBeVisible();
  // Routes are connected and disabled on the swarm's Connections page only.
  await expect(feishu.getByRole("button", { name: /^Connect$|^Disable/ })).toHaveCount(
    0
  );
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

test("typed input stays when newer settings arrive, with a notice to reload", async ({
  page,
}) => {
  let name = "Acme Robotics";
  let held: Promise<void> | null = null;
  await injectCsrfToken(page);
  await routeApi(page, async (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/settings/general") {
      const value = name;
      if (held) await held;
      return ok(general("acme", value));
    }
    const data = pages[request.path];
    return data ? ok(data) : undefined;
  });
  await page.goto("/orgs/acme/settings");
  const nameField = page.getByRole("textbox", { name: "Name" });
  const slug = page.getByRole("textbox", { name: "Slug" });
  await expect(nameField).toHaveValue("Acme Robotics");

  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await nav.getByRole("link", { name: "AI models" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "AI models" })
  ).toBeVisible();
  name = "Acme Labs";
  const { promise, resolve } = Promise.withResolvers<void>();
  held = promise;
  await nav.getByRole("link", { name: "General" }).click();

  // The cached settings show; the user starts typing before the newer ones arrive.
  await expect(nameField).toHaveValue("Acme Robotics");
  await slug.fill("acme-x");
  resolve();
  await expect(
    page.getByText("These settings changed elsewhere.", { exact: false })
  ).toBeVisible();
  await expect(slug).toHaveValue("acme-x");
  await expect(nameField).toHaveValue("Acme Robotics");

  await page.getByRole("button", { name: "Reload" }).click();
  await expect(nameField).toHaveValue("Acme Labs");
  await expect(slug).toHaveValue("acme");
  await expect(
    page.getByText("These settings changed elsewhere.", { exact: false })
  ).toHaveCount(0);
});

test("X app setup shows deployment settings and saves write-only client credentials", async ({
  page,
}) => {
  const xApp = {
    provider: "x",
    label: "X",
    client_id: null,
    client_secret_configured: false,
    source: null,
    configured: false,
    setup_href: "https://console.x.com",
    setup_config: {
      app_name: "Comma Bridge for Teams",
      callback_url: "https://salix.example/v1/oauth/x/callback",
      website_url: "https://bft.example",
    },
  };
  const oauth = { ...integrations.oauth, apps: [xApp] };
  const requests = await openSettings(
    page,
    "/orgs/acme/settings/integrations",
    (request) => {
      if (
        request.method === "PUT" &&
        request.path === "/orgs/acme/settings/integrations/oauth/x"
      )
        return ok({
          ...oauth,
          apps: [
            {
              ...xApp,
              client_id: "x-client",
              client_secret_configured: true,
              configured: true,
            },
          ],
        });
      return undefined;
    },
    { "/orgs/acme/settings/integrations": { ...integrations, oauth } }
  );
  await page.getByRole("button", { name: "Set up X OAuth app" }).click();
  const dialog = page.getByRole("dialog", { name: "X OAuth app" });
  await expect(
    dialog.getByRole("link", { name: "Open X developer settings" })
  ).toHaveAttribute("href", "https://console.x.com");
  await expect(dialog.getByLabel("Redirect URI", { exact: true })).toHaveText(
    xApp.setup_config.callback_url
  );
  await dialog.getByRole("textbox", { name: "Client ID" }).fill("x-client");
  const secret = dialog.getByRole("textbox", { name: "Client secret" });
  await expect(secret).toHaveAttribute("type", "password");
  await secret.fill("test-only-x-secret");
  await dialog.getByRole("button", { name: "Save", exact: true }).click();
  await expect(dialog).not.toBeVisible();
  expect(writes(requests)).toMatchObject([
    {
      method: "PUT",
      body: { client_id: "x-client", client_secret: "test-only-x-secret" },
    },
  ]);
  await page.getByRole("button", { name: "Edit X OAuth app" }).click();
  await expect(
    page.getByRole("dialog").getByRole("textbox", { name: "Client secret" })
  ).toHaveValue("");
});
