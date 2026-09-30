import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

/** Row actions live in a labelled overflow menu now, not bare icon buttons. */
const rowAction = async (page: Page, name: string, action: string) => {
  await page.getByRole("button", { name: `Actions for ${name}`, exact: true }).click();
  await page.getByRole("menuitem", { name: action, exact: true }).click();
};

const chooseModel = async (
  page: Page,
  trigger: string,
  vendor: string,
  model: string,
  source = "Platform billing"
) => {
  await page.getByRole("button", { name: trigger, exact: true }).click();
  await page
    .getByRole("menu", { name: trigger, exact: true })
    .getByRole("group", { name: source, exact: true })
    .getByRole("menuitem", { name: vendor, exact: true })
    .click();
  await page
    .getByRole("menu", { name: vendor, exact: true })
    .getByRole("menuitem", { name: model, exact: true })
    .click();
};

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_byok_e2e";

test("shows runtime model sources without offering ineffective template choices", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "runtime-models@example.com",
    token: "comma_test_session",
    userId: "usr_runtime_models",
  });
  const template = {
    template_id: "platform",
    name: "Platform Worker",
    model: "deepseek-flash",
    provider: "openai",
    model_vendor: "deepseek",
    scope: "global",
    reasoning_effort: "medium",
  };
  const internal = (id: string, role: string, name: string) => ({
    agent_id: id,
    name,
    role,
    source: "platform_default",
    template_id: template.template_id,
    template_name: template.name,
    model: template.model,
    provider: template.provider,
  });
  const runtimeProvider = "codex";
  const external = (id: string, name: string, kind: string, model: string | null) => ({
    agent_id: id,
    name,
    role: "worker",
    source: model ? "agent_config" : "runtime_default",
    model,
    provider: null,
    reasoning_effort: model ? "high" : null,
    runtime: { kind, provider: runtimeProvider },
  });
  const writes: string[] = [];
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
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
    const respond = (body: unknown) =>
      route.fulfill({ headers, body: JSON.stringify(body) });
    if (req.method() === "OPTIONS") return route.fulfill({ headers, status: 204 });
    if (req.method() === "PUT") writes.push(path);
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [{ id: workspaceId, group_id: "group", name: "Workspace" }],
      });
    if (path.endsWith("/model-templates")) return respond({ data: [] });
    if (path.endsWith("/subscription-accounts"))
      return respond({ accounts: [], next: "" });
    if (path.endsWith("/agent-models"))
      return respond({
        workspace_id: workspaceId,
        agents: {
          router: internal("router", "router", "Router"),
          worker: internal("worker", "worker", "Worker"),
        },
        workers: {
          items: [
            external("local-default", "Local Codex", "connected", null),
            external(
              "local-configured",
              "Configured Codex",
              "connected",
              "gpt-local-codex"
            ),
            external(
              "compute-configured",
              "Configured Compute",
              "compute",
              "gpt-compute-codex"
            ),
            internal("compute-inherited", "worker", "Inherited Compute"),
          ],
          next_cursor: null,
        },
        worker_default_template_id: null,
        platform_defaults: { router: template, worker: template },
        available_models: [template],
      });
    return respond({ data: [] });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(
    page.getByText("Follow Codex runtime default", { exact: true })
  ).toBeVisible();
  await expect(page.getByText("gpt-local-codex · high", { exact: true })).toBeVisible();
  await expect(
    page.getByText("gpt-compute-codex · high", { exact: true })
  ).toBeVisible();
  for (const name of ["Local Codex", "Configured Codex", "Configured Compute"]) {
    await expect(page.getByRole("button", { name, exact: true })).toHaveCount(0);
  }
  await page.getByRole("button", { name: "Inherited Compute", exact: true }).click();
  await expect(
    page.getByRole("menu", { name: "Inherited Compute", exact: true })
  ).toBeVisible();
  expect(writes).toEqual([]);
});

test("connects from Add model and presents Qwen as a BYOK vendor without a protocol choice", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "tokendance@example.com",
    token: "comma_test_session",
    userId: "usr_tokendance",
  });
  const global = {
    template_id: "global",
    name: "Comma Standard",
    model: "default",
    provider: "openai",
    model_vendor: "openai",
    scope: "global",
  };
  let saved: Record<string, unknown> | undefined;
  let authorized = false;
  const saves: Record<string, unknown>[] = [];
  const cancellations: unknown[] = [];
  await page.exposeFunction("tokenDanceStatusForTest", () =>
    authorized
      ? {
          status: "complete",
          models: {
            base_url: "https://tokendance.space/gateway/v1",
            provider: "openai",
            protocol: "responses",
            truncated: false,
            data: [
              {
                id: "qwen3.8-max",
                name: "Qwen3.8 Max",
                vendor: "qwen",
                supports_images: false,
              },
            ],
          },
        }
      : { status: "pending" }
  );
  await page.exposeFunction(
    "saveTokenDanceForTest",
    (input: Record<string, unknown>) => {
      saves.push(input);
      saved = {
        ...global,
        template_id: "private",
        name: input.name,
        model: input.model,
        scope: "tenant",
        model_display_name: "Qwen3.8 Max",
        model_vendor: "qwen",
        protocol: "responses",
        base_url: "https://tokendance.space/gateway/v1",
        has_api_key: true,
        max_tokens: input.maxTokens,
        context_tokens: input.contextTokens,
        supports_images: false,
      };
      return { ok: true };
    }
  );
  await page.exposeFunction("cancelTokenDanceForTest", (input: unknown) => {
    cancellations.push(input);
    return { ok: true };
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
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
    if (req.method() === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    if (path === "/v1/comma/workspaces") {
      await respond({
        data: [{ id: workspaceId, group_id: "group", name: "Workspace" }],
      });
      return;
    }
    if (path.endsWith("/model-discovery")) {
      await respond({ error: "model_discovery_no_account" }, 400);
      return;
    }
    if (path.endsWith("/model-templates")) {
      await respond({ data: saved ? [saved] : [] });
      return;
    }
    if (path.endsWith("/subscription-accounts")) {
      await respond({ accounts: [], next: "" });
      return;
    }
    if (path.endsWith("/agent-models")) {
      const agent = (role: string) => ({
        agent_id: role,
        name: role === "router" ? "Router" : "Worker",
        role,
        source: "platform_default",
        template_id: global.template_id,
        template_name: global.name,
        model: global.model,
        provider: global.provider,
      });
      await respond({
        workspace_id: workspaceId,
        agents: { router: agent("router"), worker: agent("worker") },
        workers: { items: [], next_cursor: null },
        worker_default_template_id: null,
        platform_defaults: { router: global, worker: global },
        available_models: [
          global,
          ...(saved
            ? [
                saved,
                {
                  ...global,
                  template_id: "unknown-byok",
                  scope: "tenant",
                  model: "third-party-model",
                  model_display_name: "Research: third party model",
                  model_vendor: null,
                },
              ]
            : []),
        ],
      });
      return;
    }
    await respond({ data: [] });
  });
  await page.goto("/#/settings");
  await expect(
    page.getByRole("button", { name: "Model & API", exact: true })
  ).toBeVisible();
  await page.evaluate(() => {
    const fixtures = window as unknown as {
      tokenDanceStatusForTest: () => ReturnType<
        NonNullable<typeof window.commaNative>["tokenDanceAuthorization"]["status"]
      >;
      saveTokenDanceForTest: NonNullable<
        typeof window.commaNative
      >["tokenDanceAuthorization"]["save"];
      cancelTokenDanceForTest: NonNullable<
        typeof window.commaNative
      >["tokenDanceAuthorization"]["cancel"];
    };
    window.commaNative = {
      ...window.commaNative!,
      platform: "electron",
      tokenDanceAuthorization: {
        start: async () => ({ status: "pending" }),
        status: () => fixtures.tokenDanceStatusForTest(),
        save: (input) => fixtures.saveTokenDanceForTest(input),
        cancel: (input) => fixtures.cancelTokenDanceForTest(input),
      },
    };
  });
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Need an API key? Try TokenDance", exact: true })
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Add model", exact: true }).click();
  await page
    .getByRole("button", { name: "Need an API key? Try TokenDance", exact: true })
    .click();
  await expect(
    page.getByRole("textbox", { name: "Base URL", exact: true })
  ).toHaveValue("https://api.openai.com/v1");
  await expect(page.getByLabel("API key", { exact: true })).toHaveValue("");
  await expect(
    page.getByText(
      "Complete authorization in your browser. Then return to Comma to choose a model."
    )
  ).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect.poll(() => cancellations.length).toBe(1);
  authorized = true;
  await page
    .getByRole("button", { name: "Need an API key? Try TokenDance", exact: true })
    .click();
  await page.getByRole("radio", { name: /Qwen3.8 Max/ }).click();
  await expect(
    page.getByRole("textbox", { name: "Base URL", exact: true })
  ).toHaveValue("https://tokendance.space/gateway/v1");
  await expect(page.getByLabel("API key", { exact: true })).toHaveAttribute(
    "readonly",
    ""
  );
  await expect(
    page.getByText(
      "Connected through TokenDance. Your key is stored securely; model usage is billed by TokenDance."
    )
  ).toBeVisible();
  await page
    .getByRole("switch", { name: "Advanced settings", exact: true })
    .press("Space");
  await expect(
    page.getByRole("combobox", { name: "API protocol", exact: true })
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect.poll(() => saves.length).toBe(1);
  expect(saves[0]).toMatchObject({ model: "qwen3.8-max", name: "Qwen3.8 Max" });
  expect(saves[0]).not.toHaveProperty("api_key");
  expect(saves[0]).not.toHaveProperty("protocol");
  await expect(
    page.getByRole("button", { name: "Actions for Qwen3.8 Max", exact: true })
  ).toBeVisible();
  await expect(page.getByText("Qwen: Qwen3.8 Max", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Router", exact: true }).click();
  const byok = page
    .getByRole("menu", { name: "Router", exact: true })
    .getByRole("group", { name: "BYOK", exact: true });
  await expect(byok.getByRole("menuitem", { name: "OpenAI", exact: true })).toHaveCount(
    0
  );
  await expect(
    byok.getByRole("menuitem", { name: "Other models", exact: true })
  ).toBeVisible();
  await byok.getByRole("menuitem", { name: "Other models", exact: true }).click();
  await expect(
    page
      .getByRole("menu", { name: "Other models", exact: true })
      .getByRole("menuitem", { name: "Research: third party model", exact: true })
  ).toBeVisible();
  await byok.getByRole("menuitem", { name: "Qwen", exact: true }).click();
  await expect(
    page
      .getByRole("menu", { name: "Qwen", exact: true })
      .getByRole("menuitem", { name: "Qwen3.8 Max", exact: true })
  ).toBeVisible();
});

test("creates, selects, edits and deletes a BYOK model without storing its key in the browser", async ({
  page,
}, testInfo) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "byok@example.com",
    token: "comma_sess_byok",
    userId: "usr_byok",
  });
  const global = {
    template_id: "global",
    name: "Comma Standard",
    model: "gpt-default",
    provider: "openai",
    model_vendor: "openai",
    scope: "global",
  };
  type Saved = typeof global & {
    protocol: string;
    base_url: string;
    has_api_key: boolean;
    max_tokens: number;
    context_tokens: number;
    supports_images: boolean;
    reasoning_effort?: string | null;
  };
  let saved: Saved | undefined;
  // The worker's own choice; `null` means it follows the Comma default.
  let selected: string | null = null;
  let workerDefault: string | null = null;
  let failInitialCatalog = true;
  let failDiscovery = true;
  const discoveries: Record<string, unknown>[] = [];
  const writes: Record<string, unknown>[] = [];
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();
    const headers = {
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "content-type": "application/json",
    };
    const respond = (body: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(body) });
    if (method === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    if (path === "/v1/comma/workspaces") {
      await respond({
        data: [{ id: workspaceId, group_id: "grp_byok", name: "Workspace" }],
      });
      return;
    }
    if (path.endsWith("/subscription-accounts")) {
      await respond({ accounts: [], next: "" });
      return;
    }
    if (path.endsWith("/model-discovery")) {
      if (request.postDataJSON().account_pool) {
        await respond({ error: "model_discovery_no_account" }, 400);
        return;
      }
      discoveries.push(request.postDataJSON());
      if (failDiscovery) {
        await respond({ error: "model_discovery_unauthorized" }, 400);
        return;
      }
      await respond({
        base_url: "https://api.openai.com/v1",
        provider: "openai",
        protocol: "responses",
        truncated: false,
        data: [
          {
            id: "o3",
            name: "OpenAI o3",
            vendor: "openai",
            supports_images: false,
          },
          {
            id: "custom-model",
            name: "custom-model",
            supports_images: false,
          },
          {
            id: "provider/long-model-name-for-context-and-reasoning-preview",
            name: "provider/long-model-name-for-context-and-reasoning-preview",
            supports_images: false,
          },
        ],
      });
      return;
    }
    if (path.endsWith("/agent-models/router")) {
      await respond({ error: "agent_configuration_rollout_pending" }, 400);
      return;
    }
    const agent = (role: string) => {
      const pinned = role === "worker" ? selected : null;
      return {
        agent_id: role,
        name: role === "worker" ? "Worker A" : "Router",
        role,
        source: pinned ? "pinned" : "platform_default",
        template_id: pinned ?? global.template_id,
        template_name: pinned ? "Model" : global.name,
        model: "gpt-x",
        provider: "openai",
      };
    };
    if (path.endsWith("/agent-models/worker-default")) {
      workerDefault = request.postDataJSON().template_id;
      await respond({ template_id: workerDefault });
      return;
    }
    if (path.endsWith("/agent-models/worker")) {
      selected = request.postDataJSON().template_id;
      await respond(agent("worker"));
      return;
    }
    if (path.endsWith("/agent-models/workers")) {
      await respond({
        items: [
          {
            ...agent("worker"),
            agent_id: "legacy-worker",
            name: "Legacy Worker",
            source: "pinned",
            template_id: "default",
            model: "gpt-test",
          },
        ],
        next_cursor: null,
      });
      return;
    }
    if (path.endsWith("/agent-models")) {
      await respond({
        workspace_id: workspaceId,
        agents: { router: agent("router"), worker: agent("worker") },
        workers: {
          items: [
            agent("worker"),
            {
              ...agent("worker"),
              agent_id: "worker-b",
              name: "Worker B",
              source: "platform_default",
              template_id: global.template_id,
            },
          ],
          next_cursor: "second-page",
        },
        worker_default_template_id: workerDefault,
        platform_defaults: { router: global, worker: global },
        available_models: [
          global,
          ...[
            ["gpt-6-sol-high", "gpt-6-sol", "GPT 6 Sol high", "high"],
            ["gpt-6-sol-proxy", "gpt-6-sol", "GPT 6 Sol via proxy", "high"],
            ["gpt-5-6-sol-high", "gpt-5.6-sol", "GPT 5.6 Sol high", "high"],
            ["gpt-6-sol-low", "gpt-6-sol", "GPT 6 Sol", "low"],
            ["gpt-5-6-sol-low", "gpt-5.6-sol", "GPT 5.6 Sol", "low"],
          ].map(([template_id, model, model_display_name, reasoning_effort]) => ({
            ...global,
            template_id,
            name: template_id,
            model,
            model_display_name,
            reasoning_effort,
          })),
          {
            ...global,
            template_id: "openrouter-gpt",
            provider: "openrouter",
            model: "openai/gpt-6",
            model_vendor: "openai",
            model_display_name: "GPT 6 via OpenRouter",
          },
          {
            ...global,
            template_id: "anthropic-claude",
            provider: "openrouter",
            model: "anthropic/claude-sonnet-4",
            model_vendor: "anthropic",
            model_display_name: "Claude Sonnet 4",
          },
          {
            ...global,
            template_id: "coreweave-qwen",
            model: "@preset/qwen-3-8-27b-coreweave",
            model_vendor: "qwen",
            model_icon: "qwen",
          },
          {
            ...global,
            template_id: "long-name",
            model_vendor: "openai",
            model: "long-model",
            model_display_name:
              "A model with a very long readable name for layout verification",
          },
          ...["US", "EU"].map((region) => ({
            ...global,
            template_id: `regional-${region.toLowerCase()}`,
            name: `${region} endpoint`,
            model_vendor: "openai",
            model: "shared-model",
            model_display_name: "Shared model",
          })),
          {
            ...global,
            template_id: "byok-gpt-6-sol-high",
            scope: "tenant",
            model: "gpt-6-sol",
            model_display_name: "GPT 6 Sol",
            reasoning_effort: "high",
          },
          ...(saved ? [saved] : []),
        ],
      });
      return;
    }
    if (method === "POST" || method === "PATCH") {
      const body = request.postDataJSON();
      writes.push(body);
      const { api_key: _key, ...metadata } = body;
      saved = {
        ...saved,
        ...metadata,
        template_id: "ptm1_test",
        scope: "tenant",
        has_api_key: true,
      };
      await respond(saved, method === "POST" ? 201 : 200);
      return;
    }
    if (method === "DELETE") {
      if (selected === saved?.template_id) {
        await respond({ error: "model_template_in_use" }, 409);
        return;
      }
      saved = undefined;
      await respond({ deleted: true });
      return;
    }
    if (failInitialCatalog) {
      await respond({ error: "model_catalog_unavailable" }, 503);
      return;
    }
    await respond({ data: saved ? [saved] : [] });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(
    page.getByText("Could not load model settings.", { exact: true })
  ).toBeVisible();
  failInitialCatalog = false;
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  const addModel = page.getByRole("button", { name: "Add model", exact: true });
  await addModel.focus();
  for (let index = 0; index < 6; index += 1) {
    await page.keyboard.press("Shift+Tab");
    if (await page.locator('[data-slot="settings-sidebar-item"]:focus').count()) break;
  }
  await expect(page.locator('[data-slot="settings-sidebar-item"]:focus')).toHaveCount(
    1
  );
  await addModel.click();
  await expect(page.getByRole("textbox", { name: "Name", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Save", exact: true })).toBeDisabled();
  await page.getByRole("textbox", { name: "Base URL", exact: true }).press("Enter");
  await page.locator('input[aria-label="API key"]').fill("test-byok-secret");
  await page.getByRole("button", { name: "Get models", exact: true }).press("Enter");
  await expect(page.getByText(/The provider rejected this key/)).toBeVisible();
  expect(writes).toHaveLength(0);
  failDiscovery = false;
  await page.getByRole("button", { name: "Get models", exact: true }).click();
  await page.getByRole("textbox", { name: "Search models", exact: true }).fill("o3");
  await expect(
    page.getByRole("radio", { name: "custom-model", exact: true })
  ).toHaveCount(0);
  await page.getByRole("radio", { name: "OpenAI o3", exact: true }).check();
  await page.getByRole("textbox", { name: "Search models", exact: true }).fill("");
  await page.getByRole("radio", { name: "custom-model", exact: true }).check();
  await expect(
    page.getByRole("radio", { name: "OpenAI o3", exact: true })
  ).not.toBeChecked();
  await page.getByRole("radio", { name: "OpenAI o3", exact: true }).check();
  await expect(page.getByText("Reasoning effort", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Support not reported", { exact: true })).toHaveCount(0);
  await page
    .getByRole("table", { name: "Models", exact: true })
    .screenshot({ path: testInfo.outputPath("model-table-light.png") });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.evaluate(() =>
    document.documentElement.setAttribute("data-theme", "Dark mode")
  );
  await page
    .getByRole("table", { name: "Models", exact: true })
    .screenshot({ path: testInfo.outputPath("model-table-dark.png") });
  await page.emulateMedia({ colorScheme: "light" });
  await page.evaluate(() =>
    document.documentElement.setAttribute("data-theme", "Light mode")
  );
  const originalViewport = page.viewportSize()!;
  await page.setViewportSize({ width: 800, height: 900 });
  const table = page.getByRole("table", { name: "Models", exact: true });
  await table.screenshot({ path: testInfo.outputPath("model-table-narrow.png") });
  expect(
    await table.evaluate((element) => element.scrollWidth <= element.clientWidth)
  ).toBe(true);
  await page.setViewportSize(originalViewport);
  await page.getByRole("textbox", { name: "Name", exact: true }).fill("My provider");
  expect(writes).toHaveLength(0);
  await page.getByRole("textbox", { name: "Name", exact: true }).press("Enter");
  await expect(page.getByRole("rowheader", { name: "OpenAI o3 o3" })).toBeVisible();
  expect(writes[0]?.model_display_name).toBe("OpenAI o3");
  expect(writes[0]?.model_vendor).toBe("openai");
  expect(writes[0]?.api_key).toBe("test-byok-secret");
  expect(writes[0]?.context_tokens).toBe(0);
  expect(writes[0]?.reasoning_effort ?? null).toBeNull();
  expect(discoveries[0]).toEqual({
    base_url: "https://api.openai.com/v1",
    api_key: "test-byok-secret",
  });
  await expect(page.locator('input[aria-label="API key"]')).toHaveCount(0);
  const browserStorage = await page.evaluate(() =>
    JSON.stringify([localStorage, sessionStorage])
  );
  expect(browserStorage).not.toContain("test-byok-secret");

  saved = { ...saved!, reasoning_effort: "high" };
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await rowAction(page, "My provider", "Edit model");
  await expect(page.getByLabel("Replace API key")).toHaveValue("");
  await page
    .getByRole("textbox", { name: "Name", exact: true })
    .fill("Renamed provider");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("rowheader", { name: "OpenAI o3 o3" })).toBeVisible();
  expect(writes[1]).not.toHaveProperty("api_key");
  expect(writes[1]?.reasoning_effort).toBe("high");
  const modelTable = page.getByRole("table", { name: "API key models", exact: true });
  await expect(
    modelTable.getByRole("rowheader", { name: "OpenAI o3 o3" })
  ).toBeVisible();
  expect(
    await modelTable.evaluate(
      (element) =>
        element.getBoundingClientRect().width <=
        element.parentElement!.getBoundingClientRect().width + 1
    )
  ).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("models.png") });
  await rowAction(page, "Renamed provider", "Edit model");
  await page.getByLabel("Replace API key").fill("unsaved-secret");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(page.getByLabel("Replace API key")).toHaveCount(0);

  await page.getByRole("button", { name: "Router" }).click();
  await page
    .getByRole("menu", { name: "Router", exact: true })
    .getByRole("group", { name: "BYOK", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  await page
    .getByRole("menu", { name: "OpenAI", exact: true })
    .getByRole("menuitem", { name: "OpenAI o3", exact: true })
    .click();
  await page
    .getByRole("menu", { name: "OpenAI o3", exact: true })
    .getByRole("menuitem", { name: "high", exact: true })
    .click();
  await expect(
    page.getByText(/Model switching is temporarily unavailable/)
  ).toBeVisible();
  await chooseModel(page, "Worker A", "OpenAI", "OpenAI o3", "BYOK");
  await page
    .getByRole("menu", { name: "OpenAI o3", exact: true })
    .getByRole("menuitem", { name: "high", exact: true })
    .click();
  await expect.poll(() => selected).toBe("ptm1_test");
  await expect(page.getByRole("menu")).toHaveCount(0);
  await page.setViewportSize({ width: 1280, height: 1100 });
  const modelTrigger = page.getByRole("button", { name: "Worker default" });
  await modelTrigger.click();
  const rootMenu = page.getByRole("menu", {
    name: "Worker default",
    exact: true,
  });
  await expect(rootMenu.getByRole("menuitem", { name: /^Default / })).toHaveCount(1);
  await expect(
    rootMenu.getByRole("group", { name: "BYOK", exact: true })
  ).toBeVisible();
  await expect(rootMenu.getByRole("group")).toHaveCount(2);
  await rootMenu
    .getByRole("group", { name: "BYOK", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  const byokMenu = page.getByRole("menu", { name: "OpenAI", exact: true });
  await expect(
    byokMenu.getByRole("menuitem", { name: "gpt-default", exact: true })
  ).toHaveCount(0);
  await byokMenu.getByRole("menuitem", { name: "GPT 6 Sol", exact: true }).click();
  const byokEfforts = page.getByRole("menu", { name: "GPT 6 Sol", exact: true });
  await expect(byokEfforts.getByRole("menuitem")).toHaveCount(1);
  await byokEfforts.getByRole("menuitem", { name: "high", exact: true }).click();
  await expect.poll(() => workerDefault).toBe("byok-gpt-6-sol-high");
  await expect(rootMenu).toHaveCount(0);
  await modelTrigger.click();
  await page.screenshot({ path: testInfo.outputPath("model-source-sections.png") });
  await expect(
    rootMenu
      .getByRole("group", { name: "Platform billing", exact: true })
      .getByRole("menuitem", { name: "OpenAI", exact: true })
  ).toBeVisible();
  await rootMenu.getByRole("menuitem", { name: "Qwen", exact: true }).click();
  await expect(
    page
      .getByRole("menu", { name: "Qwen", exact: true })
      .getByRole("menuitem", { name: "@preset/qwen-3-8-27b-coreweave", exact: true })
  ).toBeVisible();
  await expect(
    rootMenu.getByRole("menuitem", { name: "Other models", exact: true })
  ).toHaveCount(0);
  const anthropic = rootMenu.getByRole("menuitem", { name: "Anthropic", exact: true });
  await expect(anthropic.locator("img")).toHaveCount(1);
  await anthropic.click();
  await expect(
    page
      .getByRole("menu", { name: "Anthropic", exact: true })
      .getByRole("menuitem", { name: "Claude Sonnet 4", exact: true })
  ).toBeVisible();
  await rootMenu
    .getByRole("group", { name: "Platform billing", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  const openAiMenu = page.getByRole("menu", { name: "OpenAI", exact: true });
  const modelFamilies = await openAiMenu.getByRole("menuitem").allTextContents();
  expect(modelFamilies.filter((label) => /^GPT (6|5\.6) Sol/.test(label))).toEqual([
    "GPT 6 Sol",
    "GPT 5.6 Sol",
  ]);
  await expect(openAiMenu.locator('[data-slot="menu-separator"]')).toHaveCount(0);
  await openAiMenu.getByRole("menuitem", { name: "GPT 6 Sol", exact: true }).click();
  const gpt6Efforts = page.getByRole("menu", { name: "GPT 6 Sol", exact: true });
  await expect(gpt6Efforts.getByRole("menuitem")).toHaveCount(3);
  await expect(gpt6Efforts.getByRole("menuitem").first()).toHaveText("low");
  const highEfforts = gpt6Efforts.getByRole("menuitem", { name: "high", exact: true });
  await expect(highEfforts).toHaveCount(2);
  await expect(highEfforts.nth(0)).toHaveAccessibleDescription("gpt-6-sol-high");
  await expect(highEfforts.nth(1)).toHaveAccessibleDescription("gpt-6-sol-proxy");
  await expect(highEfforts.nth(0)).toContainText("gpt-6-sol-high");
  await expect(highEfforts.nth(1)).toContainText("gpt-6-sol-proxy");
  await highEfforts.nth(1).click();
  await expect.poll(() => workerDefault).toBe("gpt-6-sol-proxy");
  await expect(modelTrigger).toContainText("GPT 6 Sol via proxy · high");
  // Reopen only after the closing menu leaves; its exiting items match too.
  await expect(rootMenu).toHaveCount(0);
  await chooseModel(page, "Worker default", "OpenAI", "GPT 6 Sol");
  await expect(gpt6Efforts.locator('[data-slot="menu-separator"]')).toHaveCount(0);
  await gpt6Efforts.getByRole("menuitem", { name: "low", exact: true }).click();
  await expect.poll(() => workerDefault).toBe("gpt-6-sol-low");
  await expect(modelTrigger).toContainText("GPT 6 Sol · low");
  await expect(rootMenu).toHaveCount(0);
  await expect(modelTrigger).toBeEnabled();
  await modelTrigger.click();
  await rootMenu
    .getByRole("group", { name: "Platform billing", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  await expect(
    openAiMenu.getByRole("menuitem", { name: "GPT 6 via OpenRouter" })
  ).toBeVisible();
  await expect(
    openAiMenu.getByRole("menuitem", { name: "Claude Sonnet 4" })
  ).toHaveCount(0);
  await expect(openAiMenu.locator('[data-slot="menu-item-icon"]')).toHaveCount(0);
  const duplicates = openAiMenu.getByRole("menuitem", {
    name: "Shared model",
    exact: true,
  });
  await expect(duplicates).toHaveCount(2);
  await expect(duplicates.nth(0)).toContainText("US endpoint");
  await expect(duplicates.nth(1)).toContainText("EU endpoint");
  await expect(duplicates.nth(0)).toHaveAccessibleDescription("US endpoint");
  await expect(duplicates.nth(1)).toHaveAccessibleDescription("EU endpoint");
  await duplicates.nth(1).scrollIntoViewIfNeeded();
  await page.screenshot({ path: testInfo.outputPath("model-groups.png") });
  await duplicates.nth(1).click();
  await expect.poll(() => workerDefault).toBe("regional-eu");
  await expect(rootMenu).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Worker default" })).toContainText(
    "Shared model"
  );
  await expect(page.getByRole("button", { name: "Worker default" })).not.toContainText(
    "EU endpoint"
  );
  await page.getByRole("button", { name: "Worker default" }).click();
  await rootMenu
    .getByRole("group", { name: "Platform billing", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  await duplicates.nth(1).press("ArrowUp");
  await expect(duplicates.nth(0)).toBeFocused();
  await page.keyboard.press("Enter");
  await expect.poll(() => workerDefault).toBe("regional-us");
  await expect(rootMenu).toHaveCount(0);
  const modelRow = modelTrigger.locator('xpath=ancestor::*[@data-slot="settings-row"]');
  const layout = () =>
    modelRow.evaluate((row) => {
      const [rowBounds, copy, trigger] = [
        row,
        row.querySelector('[data-slot="settings-copy"]')!,
        row.querySelector("button")!,
      ].map((element) => {
        const { x, width, height } = element.getBoundingClientRect();
        return { x, width, height };
      });
      return {
        row: rowBounds!,
        copy: copy!,
        trigger: trigger!,
      };
    });
  const shortNameLayout = await layout();
  await chooseModel(
    page,
    "Worker default",
    "OpenAI",
    "A model with a very long readable name for layout verification"
  );
  await expect.poll(() => workerDefault).toBe("long-name");
  await expect.poll(layout).toEqual(shortNameLayout);
  for (const name of ["Router", "Worker A", "Worker B"]) {
    const bounds = (await page
      .getByRole("button", { name, exact: true })
      .boundingBox())!;
    expect(bounds.x).toBe(shortNameLayout.trigger.x);
    expect(bounds.width).toBe(shortNameLayout.trigger.width);
  }
  await page.screenshot({ path: testInfo.outputPath("model-width-stable.png") });
  await page.setViewportSize({ width: 800, height: 1100 });
  await modelTrigger.scrollIntoViewIfNeeded();
  const narrowLongLayout = await layout();
  const copyBounds = (await modelRow
    .locator('[data-slot="settings-copy"]')
    .boundingBox())!;
  const triggerBounds = (await modelTrigger.boundingBox())!;
  expect(triggerBounds.y).toBeGreaterThanOrEqual(copyBounds.y + copyBounds.height);
  expect(triggerBounds.width).toBe(copyBounds.width);
  expect(await modelRow.evaluate((row) => row.scrollWidth <= row.clientWidth)).toBe(
    true
  );
  await page.screenshot({ path: testInfo.outputPath("model-width-narrow.png") });
  await modelTrigger.click();
  await rootMenu
    .getByRole("group", { name: "Platform billing", exact: true })
    .getByRole("menuitem", { name: "OpenAI", exact: true })
    .click();
  await duplicates.nth(0).click();
  await expect.poll(() => workerDefault).toBe("regional-us");
  await expect(rootMenu).toHaveCount(0);
  await expect.poll(layout).toEqual(narrowLongLayout);
  await expect(page.getByRole("menu")).toHaveCount(0);
  await page.setViewportSize({ width: 1280, height: 1100 });
  await chooseModel(page, "Worker default", "OpenAI", "OpenAI o3", "BYOK");
  await page
    .getByRole("menu", { name: "OpenAI o3", exact: true })
    .getByRole("menuitem", { name: "high", exact: true })
    .click();
  await expect.poll(() => workerDefault).toBe("ptm1_test");
  expect(selected).toBe("ptm1_test");
  await expect(page.getByRole("button", { name: "Worker B" })).toContainText(
    "Default (gpt-default)"
  );
  await page.getByRole("button", { name: "Next page of Workers", exact: true }).click();
  await expect(page.getByRole("button", { name: "Worker B", exact: true })).toHaveCount(
    0
  );
  await page.getByRole("button", { name: "Legacy Worker", exact: true }).click();
  const legacyMenu = page.getByRole("menu", { name: "Legacy Worker", exact: true });
  await expect(legacyMenu.getByRole("menuitem", { name: /^Default / })).toHaveCount(1);
  await expect(
    legacyMenu.getByRole("menuitem", { name: "gpt-test (current choice)", exact: true })
  ).toBeDisabled();
  await page.keyboard.press("Escape");
  await page
    .getByRole("button", { name: "First page of Workers", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Worker A", exact: true })
  ).toContainText("OpenAI o3");
  await rowAction(page, "Renamed provider", "Delete model");
  await page.getByRole("button", { name: "Delete model", exact: true }).last().click();
  await expect(page.getByText(/An agent still uses this model/)).toBeVisible();
  // A refused delete keeps its page open, so leave it before switching models.
  await page.getByRole("button", { name: "Model & API", exact: true }).last().click();
  await page.getByRole("button", { name: "Worker A" }).click();
  await page
    .getByRole("menuitem", { name: "Default (gpt-default)", exact: true })
    .click();
  await expect.poll(() => selected).toBeNull();
  await rowAction(page, "Renamed provider", "Delete model");
  await page.getByRole("button", { name: "Delete model", exact: true }).last().click();
  await expect(page.getByRole("rowheader", { name: "OpenAI o3 o3" })).toHaveCount(0);
  await page.getByRole("button", { name: "Add model", exact: true }).click();
  await page.locator('input[aria-label="API key"]').fill("manual-key");
  await page.getByRole("button", { name: "Enter model ID", exact: true }).click();
  await page
    .getByRole("textbox", { name: "Model ID", exact: true })
    .fill("custom-model");
  await page
    .getByRole("switch", { name: "Advanced settings", exact: true })
    .press("Space");
  await expect(page.getByText("Reasoning effort", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByRole("rowheader", { name: "custom-model", exact: true })
  ).toBeVisible();
  expect(writes[2]?.reasoning_effort ?? null).toBeNull();
  expect(writes[2]?.name).toBe("custom-model");
  await page.getByRole("button", { name: "Add model", exact: true }).click();
  await page.locator('input[aria-label="API key"]').fill("cancelled-key");
  await page
    .getByRole("button", { name: "Model & API", exact: true })
    .last()
    .press("Enter");
  expect(writes).toHaveLength(3);
  await expect(page.locator('input[aria-label="API key"]')).toHaveCount(0);
});
