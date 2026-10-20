import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_models_e2e";

const catalog = {
  sources: {
    openai: { name: "OpenAI", kind: "api_key" },
    anthropic: { name: "Anthropic", kind: "api_key" },
    openrouter: { name: "OpenRouter", kind: "api_key" },
    codex: { name: "ChatGPT", kind: "subscription" },
    claude: { name: "Claude", kind: "subscription" },
    "github-copilot": { name: "GitHub Copilot", kind: "subscription" },
    "cloudflare-ai-gateway": {
      name: "Cloudflare AI Gateway",
      kind: "api_key",
      endpoint_required: true,
      protocols: ["chat_completions", "responses", "anthropic"],
    },
    custom: {
      name: "Custom",
      kind: "api_key",
      endpoint_required: true,
      protocols: ["chat_completions", "responses", "anthropic"],
    },
  },
  models: [
    {
      id: "gpt-5.5",
      name: "GPT-5.5",
      family: "GPT",
      vendor: "openai",
      efforts: ["low", "high"],
      routes: {
        openai: { model: "gpt-5.5", protocol: "responses" },
        codex: { model: "gpt-5.5", protocol: "responses" },
        openrouter: { model: "openai/gpt-5.5", protocol: "chat_completions" },
        // Copilot sends Chat Completions, so it cannot run this one.
        "github-copilot": { model: "gpt-5.5", protocol: "responses" },
      },
    },
    {
      id: "claude-opus-5",
      name: "Opus 5",
      family: "Opus",
      vendor: "anthropic",
      efforts: ["low", "high"],
      routes: {
        anthropic: { model: "claude-opus-5", protocol: "anthropic" },
        claude: { model: "claude-opus-5", protocol: "anthropic" },
        openrouter: { model: "anthropic/claude-opus-5", protocol: "anthropic" },
        "github-copilot": { model: "claude-opus-5", protocol: "anthropic" },
      },
    },
    {
      id: "claude-sonnet-4-5",
      name: "Sonnet 4.5",
      family: "Sonnet",
      vendor: "anthropic",
      efforts: ["low", "high"],
      routes: {
        openrouter: { model: "anthropic/claude-sonnet-4.5", protocol: "anthropic" },
      },
    },
  ],
};

const codexProfile = {
  id: "profile-codex",
  credential_kind: "subscription_oauth",
  source: "codex",
  provider: "codex",
  name: "member@example.com",
  email: "member@example.com",
  disabled: false,
  status: "active",
  version: "v1",
  quota: {
    plan_type: "pro",
    windows: [
      { period: "5h", remaining_percent: 62, reset_at: "2027-01-01T03:00:00Z" },
      { period: "week", remaining_percent: 8, reset_at: "2027-01-05T00:00:00Z" },
    ],
  },
};

// Gemini reports one window per model, more than a row can meter.
const geminiProfile = {
  id: "profile-gemini",
  credential_kind: "subscription_oauth",
  source: "gemini",
  provider: "gemini",
  name: "id:gemini-subject",
  email: "id:gemini-subject",
  disabled: false,
  status: "active",
  version: "v1",
  quota: {
    windows: Array.from({ length: 12 }, (_, index) => ({
      period: "5h",
      model: `gemini-model-${index}`,
      remaining_percent: 50,
      reset_at: "2027-01-01T03:00:00Z",
    })),
  },
};

type Json = Record<string, unknown>;

/**
 * A stand-in for the profile and agent endpoints: it keeps their state, records
 * every write, and answers in the contract's shapes.
 */
async function mockBackend(
  page: Page,
  state: {
    profiles: Json[];
    agents: { router: Json };
    polled?: boolean;
    resetAnswered?: boolean;
    refuseModel?: string | undefined;
    refuseProfileWrite?: boolean;
  },
  modelCatalog: { sources: unknown; models: unknown[] } = catalog
) {
  const writes: { method: string; path: string; body: unknown }[] = [];
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "models@example.com",
    token: "comma_test_session",
    userId: "usr_models",
  });
  const handle = async (route: Route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const headers = {
      "access-control-allow-origin": req.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "content-type": "application/json",
    };
    const respond = (body: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(body) });
    if (req.method() === "OPTIONS") return route.fulfill({ headers, status: 204 });
    const body = req.postData() ? (req.postDataJSON() as Json) : undefined;
    if (req.method() !== "GET") writes.push({ method: req.method(), path, body });
    const base = `/v1/comma/workspaces/${workspaceId}`;
    if (path === "/v1/comma/model-catalog") return respond(modelCatalog);
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [{ id: workspaceId, group_id: "group", name: "Workspace" }],
      });
    if (path === `${base}/agent-models`)
      return respond({
        workspace_id: workspaceId,
        agents: { router: state.agents.router },
        task_model: { selection: { kind: "builtin" } },
        task_place: { place: { kind: "salix" } },
      });
    const agent = path.match(/\/agents\/([^/]+)(\/model)?$/);
    if (agent) {
      const target = state.agents.router;
      // A model no profile can serve is refused, as the backend does.
      if (agent[2] && (body!.selection as Json).model === state.refuseModel)
        return respond({ error: "invalid_model_configuration" }, 400);
      if (agent[2]) target.selection = body!.selection;
      else target.name = body!.name;
      return respond(target);
    }
    if (path === `${base}/subscription-accounts/oauth` && body?.provider === "claude")
      return respond({
        id: "attempt-1",
        url: "https://example.com/authorize",
        expires_at: "2099-01-01T00:00:00Z",
        mode: "callback",
      });
    if (path === `${base}/subscription-accounts/oauth`)
      return respond({
        id: "attempt-1",
        url: "https://example.com/device",
        expires_at: "2099-01-01T00:00:00Z",
        mode: "device",
        user_code: "ABCD-1234",
        interval: 5,
      });
    if (path === `${base}/subscription-accounts/oauth/attempt-1` && body?.code) {
      const account = {
        id: "profile-claude",
        credential_kind: "subscription_oauth",
        source: "claude",
        name: "pasted@example.com",
        email: "pasted@example.com",
        disabled: false,
        status: "active",
        version: "v1",
        quota: { plan_type: "max", windows: [] },
      };
      state.profiles.push(account);
      return respond(account);
    }
    if (path === `${base}/subscription-accounts/oauth/attempt-1`) {
      // The first poll finds the reader still approving the device code.
      if (!state.polled) {
        state.polled = true;
        return respond({ status: "pending", interval: 5 });
      }
      const account = {
        id: "profile-copilot",
        credential_kind: "subscription_oauth",
        source: "github-copilot",
        name: "octo@example.com",
        email: "octo@example.com",
        disabled: false,
        status: "active",
        version: "v1",
        quota: { plan_type: "business", windows: [] },
      };
      state.profiles.push(account);
      return respond(account);
    }
    if (path === `${base}/model-discovery`)
      return respond({
        base_url: body!.base_url,
        provider: "openai",
        protocol: body!.protocol,
        truncated: false,
        data: [
          { id: "llama3.2:3b", name: "llama3.2:3b", supports_images: false },
          { id: "x".repeat(201), name: "too long", supports_images: false },
        ],
      });
    if (path === `${base}/subscription-accounts`) {
      // Without the view the backend lists only what older apps can parse.
      if (req.method() === "GET")
        return new URL(req.url()).searchParams.get("view") === "profiles"
          ? respond({ accounts: state.profiles, next: "" })
          : respond({ error: "legacy_view" }, 400);
      const account = {
        id: `profile-${state.profiles.length + 1}`,
        credential_kind: "provider_api_key",
        source: body!.source,
        name: body!.name ?? "OpenRouter",
        key_hint: body!.api_key ? "sk-…or42" : null,
        ...(body!.models
          ? {
              models: body!.models,
              connection: { endpoint: body!.base_url, protocol: "openai_completions" },
            }
          : {}),
        disabled: false,
        status: "active",
        version: "v1",
      };
      state.profiles.push(account);
      return respond(account, 201);
    }
    const reset = path.match(/\/subscription-accounts\/([^/]+)\/quota\/reset$/);
    if (reset) {
      // The first reset is lost on the way back, so the reader retries it.
      if (!state.resetAnswered) {
        state.resetAnswered = true;
        return respond({ error: "unavailable" }, 503);
      }
      const index = state.profiles.findIndex((entry) => entry.id === reset[1]);
      // A profile changed elsewhere refuses a reset made against its old version.
      if (state.profiles[index]!.version !== body!.version)
        return respond({ error: "conflict" }, 409);
      state.profiles[index] = {
        ...state.profiles[index],
        version: `${body!.version as string}-reset`,
        quota: {
          ...(state.profiles[index]!.quota as Json),
          reset_credits: { available_count: 1 },
        },
      };
      return respond({
        outcome: "reset",
        account: state.profiles[index],
        quota_refreshed: true,
      });
    }
    const profile = path.match(/\/subscription-accounts\/([^/]+)$/);
    if (profile) {
      const index = state.profiles.findIndex((entry) => entry.id === profile[1]);
      if (req.method() === "DELETE") {
        state.profiles.splice(index, 1);
        return respond({ deleted: true });
      }
      if (state.refuseProfileWrite) return respond({ error: "conflict" }, 409);
      const { version: _version, ...patch } = body!;
      state.profiles[index] = { ...state.profiles[index], ...patch, version: "v2" };
      return respond(state.profiles[index]);
    }
    return respond({ error: "not_found" }, 404);
  };
  await page
    .context()
    .route("https://example.com/device", (route) =>
      route.fulfill({ body: "Provider sign-in" })
    );
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, handle);
  await page.route(`${apiBaseUrl}/v1/comma/model-catalog`, handle);
  return writes;
}

const openModels = async (page: Page) => {
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
};

const router = { agent_id: "router", name: "Router", role: "router" };

test("adds, switches off and removes profiles, and shows subscription quota", async ({
  page,
}, testInfo) => {
  const state = {
    profiles: [
      structuredClone(codexProfile) as Json,
      structuredClone(geminiProfile) as Json,
    ],
    agents: { router },
  };
  const writes = await mockBackend(page, state);
  await openModels(page);

  // Per-model windows neither break the list nor show as an account meter,
  // and a subject id is not shown as the profile's name.
  await expect(page.getByRole("button", { name: /^5h · / })).toHaveCount(1);
  await expect(page.getByText("id:gemini-subject")).toHaveCount(0);

  await expect(
    page.getByText("OpenAI · ChatGPT Pro subscription", { exact: true })
  ).toBeVisible();
  const fiveHour = page.getByRole("button", { name: "5h · 62% left", exact: true });
  await expect(page.getByRole("button", { name: "Weekly · 8% left" })).toBeVisible();
  await fiveHour.hover();
  const tooltip = page.getByRole("tooltip");
  await expect(tooltip).toContainText("5h quota · resets");
  await expect(tooltip).toContainText("62% left");
  await page.screenshot({ path: testInfo.outputPath("profiles.png") });

  // An API key: pick the provider, paste a key; it is named for the provider.
  await page.getByRole("button", { name: "Add profile", exact: true }).click();
  await page.screenshot({ path: testInfo.outputPath("provider-picker.png") });
  const gateways = page.getByRole("region", { name: "Gateways", exact: true });
  await gateways.getByRole("button", { name: "OpenRouter", exact: true }).click();
  await expect(page.getByRole("radio")).toHaveCount(0);
  await page
    .getByRole("textbox", { name: "API key", exact: true })
    .fill("sk-or-secret-42");
  await expect(page.getByRole("textbox", { name: "Profile name" })).toHaveCount(0);
  // Enter connects.
  await page.getByRole("textbox", { name: "API key", exact: true }).press("Enter");
  await expect(
    page.getByText("OpenRouter · API key · sk-…or42", { exact: true })
  ).toBeVisible();
  expect(writes.at(-1)).toEqual({
    method: "POST",
    path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts`,
    body: {
      credential_kind: "provider_api_key",
      source: "openrouter",
      api_key: "sk-or-secret-42",
      name: "OpenRouter",
    },
  });
  expect(
    await page.evaluate(() => JSON.stringify(localStorage) + document.cookie)
  ).not.toContain("sk-or-secret-42");

  // A gateway on the reader's own endpoint speaks the protocol chosen for it.
  await page.getByRole("button", { name: "Add profile", exact: true }).click();
  await page
    .getByRole("region", { name: "Gateways", exact: true })
    .getByRole("button", { name: "Cloudflare AI Gateway", exact: true })
    .click();
  await page
    .getByRole("textbox", { name: "Base URL", exact: true })
    .fill("https://gateway.ai.cloudflare.com/v1/acct/gw/anthropic");
  await page.getByRole("button", { name: /Protocol$/ }).click();
  await page.getByRole("option", { name: "Anthropic Messages", exact: true }).click();
  await page.getByRole("textbox", { name: "API key", exact: true }).fill("cf-secret");
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await expect
    .poll(() => writes.at(-1)?.body)
    .toEqual({
      credential_kind: "provider_api_key",
      source: "cloudflare-ai-gateway",
      api_key: "cf-secret",
      name: "Cloudflare AI Gateway",
      base_url: "https://gateway.ai.cloudflare.com/v1/acct/gw/anthropic",
      protocol: "anthropic",
    });

  // A provider with both offers two buttons; its plan signs in at once.
  await page.getByRole("button", { name: "Add profile", exact: true }).click();
  await page
    .getByRole("region", { name: "Model labs", exact: true })
    .getByRole("button", { name: "Anthropic", exact: true })
    .click();
  await expect(page.getByRole("button", { name: /^API key/ })).toBeVisible();
  await page.getByRole("button", { name: /^Sign in with Claude/ }).click();
  // Typing waits for "Finish sign-in"; a pasted callback address finishes
  // the sign-in without another press.
  const codeField = page.getByRole("textbox", { name: "Sign-in code", exact: true });
  await codeField.fill("abcdefghijklmnopqrstuvwxyz");
  await page.waitForTimeout(300);
  expect(writes.some((write) => write.path.endsWith("/oauth/attempt-1"))).toBe(false);
  await codeField.fill("");
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.evaluate(
    (text) => navigator.clipboard.writeText(text),
    "https://console.anthropic.com/oauth/code/callback?code=abc123&state=s"
  );
  await codeField.focus();
  await page.keyboard.press("ControlOrMeta+V");
  await expect(
    page.getByText("pasted@example.com", { exact: true }).first()
  ).toBeVisible();
  expect(writes).toContainEqual(
    expect.objectContaining({
      path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts/oauth/attempt-1`,
    })
  );

  // A subscription-only provider goes straight to sign-in, here a device code.
  await page.getByRole("button", { name: "Add profile", exact: true }).click();
  // The code shows before any page opens; only the button opens one.
  let popups = 0;
  page.on("popup", () => (popups += 1));
  await page
    .getByRole("region", { name: "Gateways", exact: true })
    .getByRole("button", { name: "GitHub Copilot", exact: true })
    .click();
  await expect(
    page.getByRole("status", { name: "Device code", exact: true })
  ).toHaveText("ABCD-1234");
  expect(popups).toBe(0);
  // One press copies the code and opens the sign-in page.
  const signInPage = page.waitForEvent("popup");
  await page
    .getByRole("button", {
      name: "Copy code and continue to GitHub Copilot",
      exact: true,
    })
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe("ABCD-1234");
  const authorizationPage = await signInPage;
  await expect(authorizationPage).toHaveURL("https://example.com/device");
  await authorizationPage.close();
  expect(popups).toBe(1);
  await expect(
    page.getByText("GitHub Copilot · GitHub Copilot Business subscription", {
      exact: true,
    })
  ).toBeVisible();
  expect(writes).toContainEqual({
    method: "POST",
    path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts/oauth`,
    body: { provider: "github-copilot", mode: "device" },
  });
  await page
    .getByRole("button", { name: "Actions for octo@example.com", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "View models", exact: true }).click();
  await expect(page.getByText("Opus 5", { exact: true })).toBeVisible();
  await expect(page.getByText("GPT-5.5", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Model & API", exact: true }).last().click();

  // A profile's name is one field, asked in a dialog from its actions menu.
  await page
    .getByRole("button", { name: "Actions for octo@example.com", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click();
  const renameProfile = page.getByRole("dialog", {
    name: "Rename profile",
    exact: true,
  });
  const profileName = renameProfile.getByRole("textbox", {
    name: "Profile name",
    exact: true,
  });
  await expect(profileName).toHaveValue("octo@example.com");
  await profileName.fill("Octo work");
  await profileName.press("Enter");
  await expect(renameProfile).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Actions for Octo work", exact: true })
  ).toBeVisible();
  expect(writes.at(-1)).toMatchObject({
    method: "PATCH",
    path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts/profile-copilot`,
    body: { version: "v1", name: "Octo work" },
  });

  // Off keeps the credential but serves nothing.
  await page
    .getByRole("switch", { name: "Use OpenRouter", exact: true })
    .press("Space");
  await expect
    .poll(() => writes.at(-1)?.body)
    .toEqual({ version: "v1", disabled: true });
  await expect(page.getByRole("switch", { name: "Use OpenRouter" })).not.toBeChecked();

  await page
    .getByRole("button", { name: "Actions for OpenRouter", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Remove", exact: true }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Remove", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Actions for OpenRouter", exact: true })
  ).toHaveCount(0);
  expect(writes.at(-1)).toMatchObject({ method: "DELETE", body: { version: "v2" } });
});
