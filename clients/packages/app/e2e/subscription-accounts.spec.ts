import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const agent = (role: string) => ({
  agent_id: role,
  name: role,
  role,
  source: "pinned",
  template_id: "default",
  template_name: "Default",
  model: "default",
  provider: "openai",
});

test("imports, authorizes, manages and deletes subscription accounts without persisting credentials", async ({
  page,
}, testInfo) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "pool@example.com",
    token: "comma_sess_pool",
    userId: "usr_pool",
  });
  let account = {
    id: "account-1",
    provider: "codex",
    email: "member@example.com",
    version: "v1",
    disabled: false,
    status: "active",
    quota: {
      plan_type: "pro",
      windows: [
        { period: "weekly", remaining_percent: 75, reset_at: "2027-01-01T00:00:00Z" },
      ],
    },
  };
  let exists = false;
  let conflict = true;
  let failExchange = true;
  let pendingPoll = true;
  let failBegin = true;
  let failCatalog = false;
  const authorizationReady = Promise.withResolvers<void>();
  await page
    .context()
    .route("https://example.com/authorize", (route) =>
      route.fulfill({ body: "Provider sign-in" })
    );
  const writes: unknown[] = [];
  const modelWrites: Record<string, unknown>[] = [];
  const modelDiscoveries: unknown[] = [];
  let model: Record<string, unknown> | undefined;
  let selectedModel = "default";
  await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
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
        data: [{ id: "wsp_pool", group_id: "grp_pool", name: "Workspace" }],
      });
      return;
    }
    if (path.endsWith("/model-discovery")) {
      modelDiscoveries.push(req.postDataJSON());
      if (failCatalog) {
        await respond({ error: "model_discovery_unavailable" }, 503);
        return;
      }
      if (!exists || account.disabled || req.postDataJSON().account_pool === "claude") {
        await respond({ error: "model_discovery_no_account" }, 400);
        return;
      }
      await respond({
        base_url: "",
        provider: "openai",
        protocol: "responses",
        truncated: false,
        data: [
          {
            id: "gpt-pool",
            name: "My Codex model",
            supports_images: false,
            reasoning_efforts: ["low", "high", "ultra"],
            default_reasoning_effort: "high",
          },
          {
            id: "gpt-second",
            name: "Second Codex model",
            supports_images: true,
            reasoning_efforts: ["medium"],
          },
        ],
      });
      return;
    }
    if (path.endsWith("/model-templates/resolve-subscription")) {
      const body = req.postDataJSON();
      modelWrites.push(body);
      model = {
        ...body,
        template_id: "pool-model",
        scope: "tenant",
        name: "Subscription model",
        provider: "openai",
        protocol: "responses",
        base_url: "",
        has_api_key: false,
        max_tokens: 4096,
        context_tokens: 500_000,
      };
      await respond(model);
      return;
    }
    if (path.endsWith("/model-templates")) {
      if (req.method() === "POST") {
        const body = req.postDataJSON();
        modelWrites.push(body);
        model = {
          ...body,
          template_id: "pool-model",
          scope: "tenant",
          has_api_key: false,
        };
        await respond(model, 201);
        return;
      }
      await respond({
        data: model
          ? [
              model,
              { ...model, template_id: "claude-pool-model", account_pool: "claude" },
              {
                ...model,
                template_id: "api-key-model",
                account_pool: null,
                has_api_key: true,
                name: "My API key model",
              },
            ]
          : [],
      });
      return;
    }
    if (path.endsWith("/agent-models/worker")) {
      selectedModel = req.postDataJSON().template_id;
      await respond({ ...agent("worker"), template_id: selectedModel });
      return;
    }
    if (path.endsWith("/agent-models")) {
      await respond({
        workspace_id: "wsp_pool",
        agents: {
          router: agent("router"),
          worker: { ...agent("worker"), template_id: selectedModel },
        },
        workers: {
          items: [{ ...agent("worker"), template_id: selectedModel }],
          next_cursor: null,
        },
        worker_default_template_id: null,
        platform_defaults: { router: null, worker: null },
        available_models: model
          ? [
              model,
              { ...model, template_id: "api-key-model", account_pool: null },
              {
                ...model,
                template_id: "claude-pool-model",
                account_pool: "claude",
                provider: "anthropic",
                model: "claude-pool",
                model_display_name: "My Claude model",
              },
            ]
          : [],
      });
      return;
    }
    if (req.method() === "GET") {
      await respond({ accounts: exists ? [account] : [], next: "" });
      return;
    }
    const body = req.postDataJSON();
    writes.push(body);
    if (path.endsWith("/oauth")) {
      if (failBegin) {
        failBegin = false;
        await respond({ error: "unavailable" }, 503);
        return;
      }
      await authorizationReady.promise;
      await respond({
        id: "attempt",
        url: "https://example.com/authorize",
        expires_at: "2027-01-01T00:00:00Z",
        mode: "device",
        user_code: "device-secret",
        interval: 5,
      });
      return;
    }
    if (path.endsWith("/oauth/attempt")) {
      expect(body).toEqual({ code: "" });
      if (pendingPoll) {
        pendingPoll = false;
        await respond({ status: "pending", interval: 5 });
        return;
      }
      if (failExchange) {
        failExchange = false;
        await respond({ error: "authorization_unavailable" }, 400);
        return;
      }
      exists = true;
      await respond(account);
      return;
    }
    if (req.method() === "DELETE") {
      exists = false;
      await respond({ deleted: true });
      return;
    }
    if (req.method() === "PATCH") {
      if (conflict) {
        conflict = false;
        await respond({ error: "conflict" }, 409);
        return;
      }
      account = {
        ...account,
        disabled: body.disabled ?? account.disabled,
        version: "v2",
      };
    }
    exists = true;
    await respond(account);
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(page.getByRole("button", { name: "worker", exact: true })).toBeVisible();
  await expect.poll(() => modelDiscoveries.length).toBe(2);
  await expect(page.getByText("No accounts connected", { exact: true })).toBeVisible();
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("subscription-empty.png"),
  });
  await page.getByRole("button", { name: "Import credentials", exact: true }).click();
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("subscription-import.png"),
  });
  await page.getByLabel("Credentials JSON", { exact: true }).fill("not-json");
  await page
    .getByRole("button", { name: "Import credentials", exact: true })
    .last()
    .click();
  await expect(page.getByText(/Enter a JSON object/)).toBeVisible();
  expect(writes).toHaveLength(0);
  await page.locator('input[type="file"]').setInputFiles({
    name: "auth.json",
    mimeType: "application/json",
    buffer: Buffer.from('{"access_token":"import-secret"}'),
  });
  await expect(page.getByLabel("Credentials JSON", { exact: true })).toHaveValue(
    '{"access_token":"import-secret"}'
  );
  await page
    .getByRole("button", { name: "Import credentials", exact: true })
    .last()
    .click();
  await expect(page.getByText("member@example.com", { exact: true })).toBeVisible();
  await expect(page.getByText("Pro", { exact: true })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("subscription-plan.png") });
  expect(writes[0]).toEqual({
    provider: "codex",
    credentials: { access_token: "import-secret" },
  });
  await expect(page.getByLabel("Credentials JSON", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Add model" })).toHaveCount(0);
  await expect.poll(() => modelDiscoveries.length).toBe(4);
  expect(modelWrites).toHaveLength(0);
  await page.getByRole("button", { name: "worker", exact: true }).click();
  const byok = page.getByRole("group", { name: "BYOK", exact: true });
  await byok.getByRole("menuitem", { name: "Codex", exact: true }).click();
  const codexMenu = page.getByRole("menu", { name: "Codex", exact: true });
  await expect(codexMenu.getByRole("menuitem")).toHaveText([
    "My Codex model",
    "Second Codex model",
  ]);
  await codexMenu
    .getByRole("menuitem", { name: "My Codex model", exact: true })
    .click();
  const efforts = page.getByRole("menu", { name: "My Codex model", exact: true });
  await expect(efforts.getByRole("menuitem")).toHaveText(["low", "high", "ultra"]);
  const sharedEffortMenu = await efforts.elementHandle();
  await expect
    .poll(() =>
      sharedEffortMenu!.evaluate(
        (menu) => getComputedStyle(menu.closest('[data-slot="menu-popover"]')!).opacity
      )
    )
    .toBe("1");
  await codexMenu
    .getByRole("menuitem", { name: "Second Codex model", exact: true })
    .hover();
  const secondEfforts = page.getByRole("menu", {
    name: "Second Codex model",
    exact: true,
  });
  await expect(secondEfforts.getByRole("menuitem")).toHaveText(["medium"]);
  expect(
    await secondEfforts.evaluate(
      (menu, previous) => menu === previous,
      sharedEffortMenu
    )
  ).toBe(true);
  await expect
    .poll(() =>
      sharedEffortMenu!.evaluate(
        (menu) => getComputedStyle(menu.closest('[data-slot="menu-popover"]')!).opacity
      )
    )
    .toBe("1");
  const firstModel = codexMenu.getByRole("menuitem", {
    name: "My Codex model",
    exact: true,
  });
  await firstModel.hover();
  await expect(efforts.getByRole("menuitem")).toHaveText(["low", "high", "ultra"]);
  expect(
    await efforts.evaluate((menu, previous) => menu === previous, sharedEffortMenu)
  ).toBe(true);
  await firstModel.press("ArrowRight");
  await expect(
    efforts.getByRole("menuitem", { name: "low", exact: true })
  ).toBeFocused();
  await page.keyboard.press("ArrowLeft");
  await expect(firstModel).toBeFocused();
  await expect(efforts).toHaveCount(0);
  await firstModel.press("ArrowRight");
  await efforts.getByRole("menuitem", { name: "high", exact: true }).click();
  await expect.poll(() => selectedModel).toBe("pool-model");
  expect(modelWrites).toEqual([
    {
      account_pool: "codex",
      model: "gpt-pool",
      model_display_name: "My Codex model",
      supports_images: false,
      reasoning_effort: "high",
    },
  ]);
  await expect(page.getByRole("button", { name: "worker", exact: true })).toContainText(
    "high"
  );
  const modelTable = page.getByRole("table", { name: "API key models", exact: true });
  await expect(modelTable.getByRole("rowheader")).toHaveText([
    "My Codex modelgpt-pool",
  ]);
  await expect(page.getByRole("menu")).toHaveCount(0);
  // Once saved, the same choice reuses the template without another create.
  await page.getByRole("button", { name: "worker", exact: true }).click();
  await byok.getByRole("menuitem", { name: "Codex", exact: true }).click();
  await codexMenu
    .getByRole("menuitem", { name: "My Codex model", exact: true })
    .click();
  await efforts.getByRole("menuitem", { name: "high", exact: true }).click();
  await expect(page.getByRole("button", { name: "worker", exact: true })).toContainText(
    "high"
  );
  // A click outside a menu that is still open only closes it.
  await expect(page.getByRole("menu")).toHaveCount(0);
  expect(modelWrites).toHaveLength(1);
  expect(modelDiscoveries).toHaveLength(4);
  await page.screenshot({
    path: testInfo.outputPath("subscription-model-selection.png"),
  });
  failCatalog = true;
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(page.getByText(/Could not load subscription models/)).toBeVisible();
  await expect(page.getByRole("button", { name: "worker", exact: true })).toBeEnabled();
  await expect(page.getByRole("button", { name: "worker", exact: true })).toContainText(
    "high"
  );
  failCatalog = false;
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(page.getByText(/Could not load subscription models/)).toHaveCount(0);
  expect(modelWrites).toHaveLength(1);
  await expect(
    page.getByRole("table", { name: "Subscription accounts" })
  ).toBeVisible();
  await expect(page.getByRole("progressbar", { name: "Weekly" })).toHaveAttribute(
    "value",
    "75"
  );
  await page
    .getByRole("table", { name: "Subscription accounts" })
    .scrollIntoViewIfNeeded();
  await expect(
    page.getByRole("switch", { name: "Enable subscription for member@example.com" })
  ).toBeEnabled();
  await page
    .getByText(
      "Use Codex or Claude quota. Compute and storage are billed separately.",
      { exact: true }
    )
    .scrollIntoViewIfNeeded();
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("subscription-accounts.png"),
  });
  await page
    .locator("label")
    .filter({
      has: page.getByRole("switch", {
        name: "Enable subscription for member@example.com",
      }),
    })
    .click();
  await expect(page.getByText(/This account changed/)).toBeVisible();
  await page.getByRole("button", { name: "Refresh accounts", exact: true }).click();
  await expect(
    page.getByRole("switch", { name: "Enable subscription for member@example.com" })
  ).toBeEnabled();
  await page
    .getByRole("switch", { name: "Enable subscription for member@example.com" })
    .press("Space");
  await expect.poll(() => account.disabled).toBe(true);
  await expect(
    page.getByRole("switch", { name: "Enable subscription for member@example.com" })
  ).not.toBeChecked();
  const rowActions = page.getByRole("button", {
    name: "Actions for member@example.com",
    exact: true,
  });
  await rowActions.click();
  await page.getByRole("menuitem", { name: "Reauthorize", exact: true }).click();
  const authorization = page.getByRole("region", { name: "Settings content" });
  await expect(page.getByRole("heading", { name: "Reauthorize" })).toBeVisible();
  await authorization
    .getByRole("button", { name: "Continue with Codex", exact: true })
    .click();
  await expect(authorization.getByRole("alert")).toHaveText(
    /subscription service is unavailable/
  );
  await authorization
    .getByRole("button", { name: "Continue with Codex", exact: true })
    .click();
  authorizationReady.resolve();
  await expect(page.getByLabel("Device code")).toHaveValue("device-secret");
  const popupPromise = page.waitForEvent("popup");
  await page.getByRole("button", { name: "Open authorization page" }).click();
  const popup = await popupPromise;
  await expect(popup).toHaveURL("https://example.com/authorize");
  await popup.close();
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("subscription-authorization.png"),
  });
  await expect(authorization.getByRole("alert")).toHaveText(
    /Could not update subscription accounts/,
    { timeout: 15_000 }
  );
  await authorization
    .getByRole("button", { name: "Continue with Codex", exact: true })
    .click();
  await expect(page.getByLabel("Device code")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Reauthorize" })).toHaveCount(0, {
    timeout: 10_000,
  });
  expect(writes).toContainEqual({
    provider: "codex",
    mode: "device",
    account_id: "account-1",
    version: "v2",
  });
  expect(writes).toContainEqual({ code: "" });
  const storage = await page.evaluate(() =>
    JSON.stringify([localStorage, sessionStorage])
  );
  expect(storage).not.toContain("secret");
  await rowActions.click();
  await page.getByRole("menuitem", { name: "Delete account", exact: true }).click();
  await expect(page.getByText(/Remove this account\?/)).toBeVisible();
  await page
    .getByRole("button", { name: "Delete account", exact: true })
    .last()
    .click();
  await expect(page.getByText("member@example.com", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Import credentials", exact: true }).click();
  await page.getByLabel("Credentials JSON", { exact: true }).fill("unsaved-secret");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Import credentials", exact: true }).click();
  await expect(page.getByLabel("Credentials JSON", { exact: true })).toHaveValue("");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  await expect(page.getByLabel("Credentials JSON", { exact: true })).toHaveCount(0);
});

test("subscription quota tracks stay aligned across percentage widths", async ({
  page,
}, testInfo) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "quota@example.com",
    token: "comma_sess_quota",
    userId: "usr_quota",
  });
  const percentages = [0, 5, 39, 100, null];
  await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const headers = {
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,OPTIONS",
      "content-type": "application/json",
    };
    if (request.method() === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    const path = new URL(request.url()).pathname;
    if (path.endsWith("/model-discovery")) {
      await route.fulfill({
        headers,
        status: 400,
        body: JSON.stringify({ error: "model_discovery_no_account" }),
      });
      return;
    }
    if (path.endsWith("/model-templates")) {
      await route.fulfill({ headers, body: JSON.stringify({ data: [] }) });
      return;
    }
    if (path.endsWith("/agent-models")) {
      await route.fulfill({
        headers,
        body: JSON.stringify({
          workspace_id: "wsp_quota",
          agents: { router: agent("router"), worker: agent("worker") },
          available_models: [],
        }),
      });
      return;
    }
    const body = path.endsWith("/subscription-accounts")
      ? {
          accounts: percentages.map((percent, index) => ({
            id: `quota-${index}`,
            provider: "codex",
            email: `quota-${index}@example.com`,
            version: "v1",
            disabled: false,
            status: "active",
            quota: {
              windows: [{ period: "weekly", remaining_percent: percent }],
            },
          })),
          next: "",
        }
      : { data: [{ id: "wsp_quota", group_id: "grp_quota", name: "Workspace" }] };
    await route.fulfill({ headers, body: JSON.stringify(body) });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Model & API", exact: true }).click();
  const table = page.getByRole("table", { name: "Subscription accounts" });
  const tracks = table.getByRole("progressbar");
  await expect(tracks).toHaveCount(4);
  for (const width of [1280, 800]) {
    await page.setViewportSize({ width, height: 900 });
    await expect
      .poll(async () => {
        const widths = await tracks.evaluateAll((elements) =>
          elements.map((element) => element.getBoundingClientRect().width)
        );
        return Math.max(...widths) - Math.min(...widths);
      })
      .toBeLessThan(1);
    expect(
      await tracks.evaluateAll((elements) =>
        elements.map((element) => (element as HTMLProgressElement).position)
      )
    ).toEqual([0, 0.05, 0.39, 1]);
    for (const percent of percentages.filter((value) => value !== null)) {
      const label = table.getByText(`${percent}%`, { exact: true });
      expect(
        await label.evaluate((element) => element.scrollWidth <= element.clientWidth)
      ).toBe(true);
      await expect(label).toHaveCSS("text-align", "left");
    }
    await expect(table.getByText("Not checked yet", { exact: true })).toBeVisible();
    await expect(table.getByText("Plan unknown", { exact: true })).toHaveCount(
      percentages.length
    );
    await table.screenshot({ path: testInfo.outputPath(`quota-tracks-${width}.png`) });
  }
});

for (const outcome of [
  "reset",
  "already_redeemed",
  "nothing_to_reset",
  "no_credit",
] as const) {
  test(`confirms Codex reset and reports ${outcome} without a second redemption`, async ({
    page,
  }, testInfo) => {
    const base = "http://127.0.0.1:65534";
    await installBrowserTestSession(page, {
      apiBaseUrl: base,
      email: "pool@example.com",
      token: "comma_sess_pool",
      userId: "usr_pool",
    });
    const account = {
      id: "account-reset",
      provider: "codex",
      email: "reset@example.com",
      version: "v1",
      disabled: false,
      status: "active",
      quota: {
        reset_credits: { available_count: 2 },
        windows: [{ period: "weekly", remaining_percent: 0 }],
      },
      reset_attempt: undefined as { request_id: string; outcome: string } | undefined,
    };
    const requests: { version: string; request_id: string }[] = [];
    await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
      const req = route.request();
      const path = new URL(req.url()).pathname;
      const headers = {
        "access-control-allow-origin": req.headers().origin ?? "http://127.0.0.1:4173",
        "access-control-allow-credentials": "true",
        "access-control-allow-headers":
          "authorization,content-type,x-comma-session-transport",
        "access-control-allow-methods": "GET,POST,OPTIONS",
        "content-type": "application/json",
      };
      const respond = (body: unknown, status = 200) =>
        route.fulfill({ headers, status, body: JSON.stringify(body) });
      if (req.method() === "OPTIONS") return route.fulfill({ headers, status: 204 });
      if (path === "/v1/comma/workspaces")
        return respond({
          data: [{ id: "wsp_pool", group_id: "grp_pool", name: "Workspace" }],
        });
      if (path.endsWith("/agent-models"))
        return respond({
          workspace_id: "wsp_pool",
          agents: { router: agent("router"), worker: agent("worker") },
          available_models: [],
        });
      if (path.endsWith("/model-templates")) return respond({ data: [] });
      if (path.endsWith("/model-discovery"))
        return respond({ error: "model_discovery_no_account" }, 400);
      if (path.endsWith("/quota/reset")) {
        requests.push(req.postDataJSON());
        if (requests.length === 1) {
          account.reset_attempt = {
            request_id: requests[0]!.request_id,
            outcome: "pending",
          };
          account.version = "v2";
          account.quota.reset_credits.available_count = 0;
          return respond({ error: "reset_pending" }, 503);
        }
        account.reset_attempt = { request_id: requests[0]!.request_id, outcome };
        return respond({ outcome, account, quota_refreshed: false });
      }
      return respond({
        accounts: [
          account,
          {
            ...account,
            id: "claude-account",
            provider: "claude",
            email: "claude@example.com",
          },
          {
            ...account,
            id: "unknown-account",
            email: "unknown@example.com",
            quota: null,
          },
          {
            ...account,
            id: "zero-account",
            email: "zero@example.com",
            quota: { reset_credits: { available_count: 0 } },
          },
        ],
        next: "",
      });
    });
    const openSettings = async () => {
      await page.goto("/#/settings");
      await page.getByRole("button", { name: "Model & API", exact: true }).click();
      await expect(page.getByText("reset@example.com", { exact: true })).toBeVisible();
    };
    await openSettings();
    const openActions = (email: string) =>
      page.getByRole("button", { name: `Actions for ${email}`, exact: true }).click();
    await openActions("claude@example.com");
    await expect(page.getByRole("menuitem", { name: /^Reset quota/ })).toHaveCount(0);
    await page.keyboard.press("Escape");
    for (const [email, label] of [
      ["unknown@example.com", "Reset quota (count unknown)"],
      ["zero@example.com", "Reset quota (0 resets left)"],
    ]) {
      await openActions(email!);
      await expect(
        page.getByRole("menuitem", { name: label!, exact: true })
      ).toBeDisabled();
      await page.keyboard.press("Escape");
    }
    await openActions("reset@example.com");
    await expect(
      page.getByRole("menuitem", { name: "Reset quota (2 resets left)", exact: true })
    ).toBeEnabled();
    if (outcome === "reset")
      await page.screenshot({
        path: testInfo.outputPath("subscription-reset-menu.png"),
        animations: "disabled",
      });
    await page
      .getByRole("menuitem", { name: "Reset quota (2 resets left)", exact: true })
      .click();
    expect(requests).toHaveLength(0);
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    expect(requests).toHaveLength(0);
    await openActions("reset@example.com");
    await page
      .getByRole("menuitem", { name: "Reset quota (2 resets left)", exact: true })
      .click();
    await page.getByRole("button", { name: "Confirm reset", exact: true }).click();
    await expect(page.getByRole("alert")).toContainText("Reset could not be confirmed");
    await page.reload();
    await page.getByRole("button", { name: "Model & API", exact: true }).click();
    await openActions("reset@example.com");
    await page
      .getByRole("menuitem", { name: "Reset quota (0 resets left)", exact: true })
      .click();
    await page.getByRole("button", { name: "Confirm reset", exact: true }).click();
    const expected = {
      reset: "Quota reset confirmed.",
      already_redeemed: "This reset request was already redeemed.",
      nothing_to_reset: "No quota needs a reset.",
      no_credit: "No reset credits are available.",
    };
    await expect(
      page.getByRole("status").filter({ hasText: expected[outcome] })
    ).toContainText("Quota refresh failed");
    await expect(
      page.getByRole("button", { name: "Confirm reset", exact: true })
    ).toBeDisabled();
    expect(requests).toHaveLength(2);
    expect(requests[1]!.request_id).toBe(requests[0]!.request_id);
    expect(requests[1]!.version).toBe("v2");
    if (outcome === "reset")
      await page.screenshot({
        path: testInfo.outputPath("subscription-reset-result.png"),
        animations: "disabled",
      });
  });
}
