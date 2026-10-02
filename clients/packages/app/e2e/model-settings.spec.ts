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
    agents: { router: Json; workers: Json[] };
    polled?: boolean;
    resetAnswered?: boolean;
    refuseModel?: string | undefined;
  }
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
    if (path === "/v1/comma/model-catalog") return respond(catalog);
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [{ id: workspaceId, group_id: "group", name: "Workspace" }],
      });
    if (path === `${base}/agent-models`)
      return respond({
        workspace_id: workspaceId,
        agents: { router: state.agents.router },
        workers: { items: state.agents.workers, next_cursor: null },
      });
    const agent = path.match(/\/agents\/([^/]+)(\/model)?$/);
    if (agent) {
      const id = agent[1]!;
      const all = [state.agents.router, ...state.agents.workers];
      const target = all.find((entry) => entry.agent_id === id)!;
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
    agents: { router, workers: [] },
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
    .getByRole("button", { name: "Copy code and open sign-in page", exact: true })
    .click();
  await (await signInPage).close();
  expect(popups).toBe(1);
  await expect(
    page.getByText("GitHub Copilot · GitHub Copilot Business subscription", {
      exact: true,
    })
  ).toBeVisible({ timeout: 15_000 });
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

test("chooses Agent models by family, gates pay-per-use, and renames", async ({
  page,
}, testInfo) => {
  const state = {
    refuseModel: undefined as string | undefined,
    profiles: [
      structuredClone(codexProfile) as Json,
      {
        id: "profile-key",
        credential_kind: "provider_api_key",
        source: "openrouter",
        name: "Team router",
        key_hint: "sk-…or42",
        disabled: false,
        status: "active",
        version: "v1",
      },
    ],
    agents: {
      router: { ...router },
      workers: [
        {
          agent_id: "coder",
          name: "Coder",
          role: "worker",
          selection: {
            kind: "catalog",
            model: "gpt-5.5",
            reasoning_effort: "high",
            allow_paid: false,
          },
        },
        {
          // An external runtime reports its own model and no selection.
          agent_id: "vm-codex",
          name: "VM Codex",
          role: "worker",
          source: "agent_config",
          model: "gpt-5.5",
          reasoning_effort: "high",
          runtime: { kind: "compute", provider: "codex" },
        },
        {
          // A compute runtime on its own sign-in: its plan's models only.
          agent_id: "vm-claude",
          name: "VM Claude",
          role: "worker",
          runtime: { kind: "compute", provider: "claude" },
          selection: {
            kind: "runtime",
            model: "claude-opus-5",
            reasoning_effort: "low",
          },
        },
        {
          // Kept to a profile that has since been removed.
          agent_id: "pinned",
          name: "Pinned",
          role: "worker",
          selection: {
            kind: "catalog",
            model: "gpt-5.5",
            reasoning_effort: null,
            allow_paid: false,
            profile_id: "profile-gone",
          },
        },
        {
          // A private template chosen before the catalog existed.
          agent_id: "legacy",
          name: "Legacy",
          role: "worker",
          template_id: "tmpl-old",
          model_display_name: "Old GPT",
          selection: { kind: "template", template_id: "tmpl-old" },
        },
      ],
    },
  };
  const writes = await mockBackend(page, state);
  await openModels(page);

  await expect(page.getByRole("button", { name: "Router", exact: true })).toContainText(
    "Comma built-in (recommended)"
  );
  const coder = page.getByRole("button", { name: "Coder", exact: true });
  await expect(coder).toContainText("GPT-5.5");
  await expect(coder).toContainText("high");
  await expect(coder).toContainText("Automatic");

  // One panel: models under their families, efforts beside them.
  const putSelection = () =>
    writes.filter((write) => write.method === "PUT").at(-1)?.body;
  await coder.click();
  const panel = page.getByRole("dialog", { name: "Coder", exact: true });
  await expect(panel.getByRole("group", { name: "Sonnet" })).toBeVisible();
  // A new model waits for its effort; the effort saves both.
  const before = writes.length;
  await panel.getByRole("button", { name: "Opus 5", exact: true }).click();
  await expect(
    panel.getByRole("button", { name: "high", exact: true })
  ).toHaveAttribute("aria-pressed", "false");
  expect(writes.length).toBe(before);
  await panel.getByRole("button", { name: "high", exact: true }).click();
  await page.screenshot({ path: testInfo.outputPath("model-menu.png") });
  await expect
    .poll(() => writes.at(-1))
    .toEqual({
      method: "PUT",
      path: `/v1/comma/workspaces/${workspaceId}/agents/coder/model`,
      body: {
        selection: {
          kind: "catalog",
          model: "claude-opus-5",
          reasoning_effort: "high",
          allow_paid: false,
          profile_id: null,
        },
      },
    });
  // Only an API key serves Opus 5 here, so subscriptions-only cannot run it.
  const warning = page.getByText(/No enabled subscription serves this model/);
  await expect(warning).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath("pay-per-use-warning.png") });

  // The account: automatic with pay-per-use allowed, then kept to one key.
  await coder.click();
  await panel.getByRole("button", { name: "Account", exact: true }).click();
  const accounts = page.getByRole("dialog", { name: "Account", exact: true });
  await accounts.getByText("Allow pay-per-use (API keys)", { exact: true }).click();
  await page.screenshot({ path: testInfo.outputPath("account-panel.png") });
  // Nothing in the account panel spills past its edge.
  const fits = await accounts.evaluate(
    (element) => element.scrollWidth <= element.clientWidth
  );
  expect(fits).toBe(true);
  await expect.poll(putSelection).toEqual({
    selection: {
      kind: "catalog",
      model: "claude-opus-5",
      reasoning_effort: "high",
      allow_paid: true,
      profile_id: null,
    },
  });
  await expect(warning).toHaveCount(0);

  await accounts.getByRole("button", { name: /Team router/ }).click();
  await expect.poll(putSelection).toEqual({
    selection: {
      kind: "catalog",
      model: "claude-opus-5",
      reasoning_effort: "high",
      allow_paid: true,
      profile_id: "profile-key",
    },
  });
  // Choosing an account closes its panel; a click outside closes the picker.
  await page.mouse.click(5, 5);
  await expect(panel).toHaveCount(0);
  await expect(coder).toContainText("Team router");
  // The trigger is named for the Agent and describes its current choice.
  await expect(coder).toHaveAccessibleDescription(/Opus 5/);

  // A refused choice leaves the page on what the server holds.
  state.refuseModel = "claude-sonnet-4-5";
  await coder.click();
  await panel.getByRole("button", { name: "Sonnet 4.5", exact: true }).click();
  await panel.getByRole("button", { name: "high", exact: true }).click();
  await page.mouse.click(5, 5);
  await expect(coder).toContainText("Opus 5");
  await expect(page.getByText("Something went wrong. Try again.")).toBeVisible();
  // A later choice that succeeds shows, even after the refused one reloaded.
  state.refuseModel = undefined;
  await coder.click();
  await panel.getByRole("button", { name: "Sonnet 4.5", exact: true }).click();
  await panel.getByRole("button", { name: "low", exact: true }).click();
  await page.mouse.click(5, 5);
  await expect(coder).toContainText("Sonnet 4.5");

  // The runtime sets VM Codex's model, so the page shows it without a picker.
  await expect(page.getByText("GPT-5.5 · high", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "VM Codex", exact: true })).toHaveCount(
    0
  );
  // A compute Worker picks among its runtime's models, with no account.
  const vmClaude = page.getByRole("button", { name: "VM Claude", exact: true });
  await expect(vmClaude).toContainText("Opus 5");
  await vmClaude.click();
  const vmPanel = page.getByRole("dialog", { name: "VM Claude", exact: true });
  await expect(vmPanel.getByRole("button", { name: "GPT-5.5" })).toHaveCount(0);
  await expect(vmPanel.getByRole("button", { name: "Account" })).toHaveCount(0);
  await vmPanel.getByRole("button", { name: "high", exact: true }).click();
  await expect.poll(putSelection).toEqual({
    selection: { kind: "runtime", model: "claude-opus-5", reasoning_effort: "high" },
  });
  await page.screenshot({ path: testInfo.outputPath("runtime-worker.png") });
  await page.mouse.click(5, 5);
  await expect(vmPanel).toHaveCount(0);

  // A pin to a removed profile says so instead of reading as automatic.
  await expect(page.getByRole("button", { name: "Pinned", exact: true })).toContainText(
    "Removed profile"
  );
  await expect(
    page.getByText(/The profile this Agent keeps to is off, removed/)
  ).toBeVisible();
  // An earlier template choice still loads and stays selected until replaced.
  await expect(page.getByRole("button", { name: "Legacy", exact: true })).toContainText(
    "Old GPT (earlier setting)"
  );

  await page.getByRole("button", { name: "Rename Coder", exact: true }).click();
  await page.getByRole("textbox", { name: "Name", exact: true }).fill("Builder");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Builder", exact: true })
  ).toBeVisible();
  expect(writes.at(-1)).toEqual({
    method: "PATCH",
    path: `/v1/comma/workspaces/${workspaceId}/agents/coder`,
    body: { name: "Builder" },
  });
});

test("resets Codex quota, re-authorizes a subscription, and serves TokenDance models", async ({
  page,
}, testInfo) => {
  const state = {
    profiles: [
      {
        ...structuredClone(codexProfile),
        quota: {
          ...structuredClone(codexProfile.quota),
          reset_credits: { available_count: 2 },
        },
      } as Json,
      {
        // What one-click TokenDance saves: a Custom key on its gateway.
        id: "profile-tokendance",
        credential_kind: "provider_api_key",
        source: "custom",
        name: "TokenDance",
        key_hint: "td-…9f2c",
        models: ["claude-sonnet-4-5", "video-model"],
        connection: {
          endpoint: "https://tokendance.space/gateway/v1/chat/completions",
          protocol: "openai_completions",
        },
        disabled: false,
        status: "active",
        version: "v1",
      },
      {
        // A sign-in that expired cannot reset until it is renewed.
        ...structuredClone(codexProfile),
        id: "profile-expired",
        name: "expired@example.com",
        email: "expired@example.com",
        status: "expired",
        quota: {
          ...structuredClone(codexProfile.quota),
          reset_credits: { available_count: 2 },
        },
      } as Json,
    ],
    agents: { router, workers: [] },
  };
  const writes = await mockBackend(page, state);
  await openModels(page);

  await page
    .getByRole("button", { name: "Actions for expired@example.com", exact: true })
    .click();
  await expect(
    page.getByRole("menuitem", { name: "Reset quota (2 resets left)", exact: true })
  ).toBeDisabled();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);

  // The fix sits on the row: an expired plan offers to re-authorize, and a
  // Codex plan running low (8% weekly, resets left) offers to reset.
  // Each row action names its profile.
  await expect(
    page.getByRole("button", { name: "Re-authorize expired@example.com", exact: true })
  ).toBeVisible();
  await expect(
    page.getByRole("button", {
      name: "Reset quota for member@example.com",
      exact: true,
    })
  ).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("row-actions.png") });

  // Reset: confirm, retry an unconfirmed attempt with the same request id.
  const actions = page.getByRole("button", {
    name: "Actions for member@example.com",
    exact: true,
  });
  await actions.click();
  await page
    .getByRole("menuitem", { name: "Reset quota (2 resets left)", exact: true })
    .click();
  const dialog = page.getByRole("dialog", { name: /^Reset quota for / });
  await dialog.getByRole("button", { name: "Reset quota", exact: true }).click();
  await expect(dialog).toContainText("The reset could not be confirmed.");
  await dialog.getByRole("button", { name: "Reset quota", exact: true }).click();
  await expect(dialog).toContainText("Quota reset confirmed.");
  await page.screenshot({ path: testInfo.outputPath("reset-quota.png") });
  const resets = writes.filter((write) => write.path.endsWith("/quota/reset"));
  expect(resets).toHaveLength(2);
  expect(resets[0]!.body).toEqual(resets[1]!.body);
  expect(resets[0]!.body).toMatchObject({ version: "v1" });
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await actions.click();
  await expect(
    page.getByRole("menuitem", { name: "Reset quota (1 reset left)", exact: true })
  ).toBeVisible();

  // Re-authorize renews the same account instead of adding another.
  await page.getByRole("menuitem", { name: "Re-authorize", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Re-authorize member@example.com" })
  ).toBeVisible();
  // Renewing has nothing to fill in: its sign-in starts at once.
  await expect(
    page.getByRole("status", { name: "Device code", exact: true })
  ).toHaveText("ABCD-1234");
  await page.screenshot({ path: testInfo.outputPath("reauthorize.png") });
  expect(writes).toContainEqual({
    method: "POST",
    path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts/oauth`,
    body: {
      provider: "codex",
      mode: "device",
      account_id: "profile-codex",
      version: "v1-reset",
    },
  });
  // Back to the list; the first match is the sidebar entry.
  await page.getByRole("button", { name: "Model & API", exact: true }).last().click();

  // A TokenDance profile serves the catalog models it listed, under its own name.
  await expect(
    page.getByText("TokenDance · API key · td-…9f2c", { exact: true })
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Actions for TokenDance", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "View models", exact: true }).click();
  await expect(page.getByText("Sonnet 4.5", { exact: true })).toBeVisible();
  await expect(page.getByText("Opus 5", { exact: true })).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath("tokendance-models.png") });

  // A profile changed elsewhere: the reset says so, reloads, and the retry
  // uses the current version.
  state.profiles[0]!.version = "v7";
  await page.getByRole("button", { name: "Model & API", exact: true }).last().click();
  await actions.click();
  await page
    .getByRole("menuitem", { name: "Reset quota (1 reset left)", exact: true })
    .click();
  await dialog.getByRole("button", { name: "Reset quota", exact: true }).click();
  await expect(dialog).toContainText("This profile changed elsewhere.");
  await dialog.getByRole("button", { name: "Reset quota", exact: true }).click();
  await expect(dialog).toContainText("Quota reset confirmed.");
  expect(
    writes.filter((write) => write.path.endsWith("/quota/reset")).at(-1)?.body
  ).toMatchObject({ version: "v7" });
});

test("connects Ollama by listing its models, and an Agent can run one", async ({
  page,
}, testInfo) => {
  const state = {
    profiles: [] as Json[],
    agents: {
      router,
      workers: [{ agent_id: "coder", name: "Coder", role: "worker" }],
    },
  };
  const writes = await mockBackend(page, state);
  await openModels(page);

  await page.getByRole("button", { name: "Add profile", exact: true }).click();
  await page
    .getByRole("region", { name: "Local & custom", exact: true })
    .getByRole("button", { name: "Ollama", exact: true })
    .click();
  // Ollama speaks Chat Completions and needs no key.
  await expect(page.getByRole("button", { name: "Protocol" })).toHaveCount(0);
  await page
    .getByRole("textbox", { name: "Base URL", exact: true })
    .fill("https://ollama.example.com/v1");
  await page.screenshot({ path: testInfo.outputPath("ollama-connect.png") });
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(page.getByText("Ollama", { exact: true })).toBeVisible();
  // The first profile says nothing else is needed.
  await expect(
    page.getByText("Profile added. Agents use it automatically.", { exact: true })
  ).toBeVisible();
  expect(writes).toContainEqual({
    method: "POST",
    path: `/v1/comma/workspaces/${workspaceId}/model-discovery`,
    body: { base_url: "https://ollama.example.com/v1", protocol: "chat_completions" },
  });
  // A key-less profile serving the listed ids an endpoint may take.
  expect(writes.at(-1)).toEqual({
    method: "POST",
    path: `/v1/comma/workspaces/${workspaceId}/subscription-accounts`,
    body: {
      credential_kind: "provider_api_key",
      source: "custom",
      base_url: "https://ollama.example.com/v1",
      protocol: "chat_completions",
      models: ["llama3.2:3b"],
      // Named for its tile: a Custom profile would otherwise read "Custom".
      name: "Ollama",
    },
  });

  // Its model is not in the catalog, yet the Agent can choose it.
  await page.getByRole("button", { name: "Coder", exact: true }).click();
  const panel = page.getByRole("dialog", { name: "Coder", exact: true });
  // Models outside the catalog share one group.
  await panel
    .getByRole("group", { name: "Custom" })
    .getByRole("button", { name: "llama3.2:3b", exact: true })
    .click();
  await expect
    .poll(() => writes.at(-1)?.body)
    .toEqual({
      selection: {
        kind: "catalog",
        model: "llama3.2:3b",
        reasoning_effort: null,
        allow_paid: false,
        profile_id: null,
      },
    });
  await page.screenshot({ path: testInfo.outputPath("ollama-model.png") });
});
