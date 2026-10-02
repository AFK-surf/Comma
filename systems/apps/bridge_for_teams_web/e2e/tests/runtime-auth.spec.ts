import { test, expect, type Page, type Route } from "@playwright/test";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// Runtime authentication on the React Devices page, served by Phoenix with the
// real session, CSRF token and Devices API. Each test names its targets by
// rewriting the page's runtime-auth targets, so no seeded device is assumed,
// and answers the browser-owned runtime-auth endpoints itself (one test hands
// them to the production non-root target owner instead). HTTP authorization
// and lease checks live in runtime_auth_controller_test.exs; native
// decryption and commit are exercised by the Go private-RPC integration.
const EMAIL = process.env.E2E_USER_EMAIL || "e2e@example.com";
const ORG_SLUG = process.env.E2E_ORG_SLUG || "e2e";
const systems = path.resolve(__dirname, "../../../..");
const fixture = JSON.parse(
  readFileSync(
    path.join(systems, "connector/salix-connect/testdata/runtime-auth/hpke-js.json"),
    "utf8",
  ),
);

type Target =
  | { kind: "compute_workload"; workload_id: string }
  | { kind: "connected_runtime"; device_id: string; runtime_id: string };

interface AuthRequest {
  method: string;
  path: string;
  body: any;
  raw: string;
}

let projectId = "";

async function login(page: Page) {
  await page.goto(
    `/dev/login?email=${encodeURIComponent(EMAIL)}&to=/orgs/${ORG_SLUG}`,
  );
  await expect(page.locator('meta[name="csrf-token"]')).toHaveCount(1);
}

// One Agent Swarm for the file; its creator administers it.
test.beforeAll(async ({ browser }) => {
  const page = await browser.newPage();
  await login(page);
  const token = await page
    .locator('meta[name="csrf-token"]')
    .getAttribute("content");
  const name = `runtime-auth-${Date.now().toString(36)}`;
  const response = await page.request.post(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/projects`,
    { data: { name, slug: name }, headers: { "x-csrf-token": token || "" } },
  );
  expect(response.ok(), await response.text()).toBe(true);
  projectId = (await response.json()).data.id;
  await page.close();
});

test.beforeEach(async ({ page }) => {
  await login(page);
});

const devicesPath = () => `/orgs/${ORG_SLUG}/projects/${projectId}/devices`;
const authBase = () => `/dashboard/orgs/${ORG_SLUG}/projects/${projectId}`;

/**
 * Opens the Devices page with `targets` as its runtime-auth targets. The
 * runtime-auth endpoints are answered by `handle`: an object is the `data`
 * of a success, "abort" a lost response, a `Route` callback anything else.
 */
async function openDevices(
  page: Page,
  targets: { id: string; provider: string; target: Target; managed: boolean }[],
  handle: (request: AuthRequest, route: Route) => unknown,
) {
  const requests: AuthRequest[] = [];
  await page.route(
    (url) =>
      url.pathname === `/dashboard/api/v1/orgs/${ORG_SLUG}/projects/${projectId}/devices`,
    async (route) => {
      const response = await route.fetch();
      const body = await response.json();
      body.data.runtime_auth.targets = targets.map((target) => ({
        status: "running",
        ...target,
      }));
      await route.fulfill({ response, json: body });
    },
  );
  await page.route(
    (url) => url.pathname.startsWith(authBase() + "/"),
    async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      const raw = request.postData() ?? "";
      const recorded = {
        method: request.method(),
        path: url.pathname.slice(authBase().length) + url.search,
        body: raw ? JSON.parse(raw) : undefined,
        raw,
      };
      requests.push(recorded);
      const reply = await handle(recorded, route);
      if (reply === "handled") return;
      // Unanswered calls (the Router request list) reach the server.
      if (reply === undefined) return route.fallback();
      if (reply === "abort") return route.abort("failed");
      await route.fulfill({ json: { ok: true, data: reply } });
    },
  );
  await page.goto(devicesPath());
  await expect(
    page.getByRole("main").getByRole("heading", { level: 1, name: "Devices" }),
  ).toBeVisible();
  return requests;
}

async function manage(page: Page, id: string) {
  await page.getByRole("button", { name: `Manage ${id}` }).click();
  const dialog = page.getByRole("dialog", {
    name: "Manage runtime authentication",
  });
  await expect(dialog).toBeVisible();
  return dialog;
}

const status = (runtimeAuth: Record<string, unknown>) => ({
  runtime_auth: {
    native_ready: true,
    dispatch_ready: false,
    methods: [],
    attempt: null,
    ...runtimeAuth,
  },
});

for (const provider of ["codex", "pi", "claude"] as const) {
  test(`managed organization account handles a lost ${provider} bind response`, async ({
    page,
  }) => {
    let state = "unbound";
    const account = {
      id: `account-${provider}`,
      version: `version-${provider}`,
      credential_kind: provider === "codex" ? "subscription_oauth" : "provider_api_key",
      name: `${provider} team account`,
      connection:
        provider === "codex"
          ? undefined
          : { endpoint: "https://models.example.test", protocol: "anthropic_messages" },
    };
    const workload = `managed-${provider}`;
    const requests = await openDevices(
      page,
      [
        {
          id: workload,
          provider,
          target: { kind: "compute_workload", workload_id: workload },
          managed: true,
        },
      ],
      (request) => {
        if (!request.path.startsWith(`/workloads/${workload}/managed-auth`)) return undefined;
        if (request.method === "PUT") {
          expect(request.body).toEqual({
            account_id: account.id,
            expected_account_version: account.version,
            expected_binding: null,
          });
          state = "configured";
          return "abort";
        }
        const binding = state === "unbound" ? null : { id: 7, account_id: account.id, enabled: true };
        return {
          managed_auth: {
            source: state === "unbound" ? "self_configured" : "organization",
            state,
            provider,
            binding,
            account: binding ? account : null,
            accounts: state === "unbound" ? [account] : [],
            actions: state === "unbound" ? ["bind"] : ["refresh", "unbind"],
            issue: null,
          },
        };
      },
    );

    const dialog = await manage(page, workload);
    await expect(dialog.getByText("This runtime uses its own configuration.")).toBeVisible();
    await dialog.getByRole("button", { name: /Credential source$/ }).click();
    await page.getByRole("option", { name: "Organization account" }).click();
    await dialog.getByRole("button", { name: "Bind account" }).click();
    await expect(dialog.getByText("Organization account configured.")).toBeVisible();
    await expect(dialog.getByRole("status").first()).toContainText("The result is uncertain");
    expect(requests.filter((request) => request.method === "PUT")).toHaveLength(1);
    expect(requests.filter((request) => request.method === "GET").length).toBeGreaterThanOrEqual(2);
    expect(await page.evaluate(() => localStorage.length)).toBe(0);
  });
}

test("Chromium seals input to the production non-root target owner", async ({ page }) => {
  test.setTimeout(120_000);
  const marker = "synthetic-browser-to-native-claude-key";
  const temporary = mkdtempSync(path.join(os.tmpdir(), "comma-runtime-auth-browser-"));
  const ready = path.join(temporary, "ready");
  let output = "";
  const target = spawn("go", ["test", "-run", "^TestRuntimeAuthBrowserTargetHarness$", "-count=1", "-v"], {
    cwd: path.join(systems, "connector/salix-connect"),
    env: { ...process.env, COMMA_RUNTIME_AUTH_BROWSER_HARNESS_READY: ready, COMMA_RUNTIME_AUTH_BROWSER_HARNESS_MARKER: marker },
    stdio: ["ignore", "pipe", "pipe"],
  });
  target.stdout.on("data", (chunk) => { output += chunk.toString(); });
  target.stderr.on("data", (chunk) => { output += chunk.toString(); });
  const exited = new Promise<number | null>((resolve) => target.once("exit", resolve));
  let url = "";
  try {
    for (let attempt = 0; attempt < 600 && !url; attempt += 1) {
      if (target.exitCode !== null) throw new Error(`target harness exited early: ${output}`);
      try { url = readFileSync(ready, "utf8").trim(); } catch {}
      if (!url) await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!url) throw new Error("target harness did not become ready");

    // The page's runtime-auth calls go to the harness, which wraps the
    // production target owner.
    const requests = await openDevices(
      page,
      [
        {
          id: "browser-workload",
          provider: "claude",
          target: { kind: "compute_workload", workload_id: "browser-workload" },
          managed: false,
        },
      ],
      async (request, route) => {
        if (request.path !== "/runtime-auth") return undefined;
        const response = await route.fetch({ url: `${url}/runtime-auth` });
        await route.fulfill({ response });
        return "handled";
      },
    );

    const dialog = await manage(page, "browser-workload");
    const secret = dialog.getByRole("textbox", { name: "API key" });
    await expect(secret).toBeEnabled();
    await secret.fill(marker);
    await dialog.getByRole("button", { name: "Save to runtime" }).click();
    await expect(dialog.getByText("Saved, not verified", { exact: true })).toBeVisible();
    await expect(secret).toHaveValue("");
    expect(requests.some((request) => request.body?.action === "input_submit")).toBe(true);
    expect(requests.every((request) => !request.raw.includes(marker))).toBe(true);
    expect(await page.evaluate(() => localStorage.length)).toBe(0);
  } finally {
    if (url) await page.request.post(`${url}/shutdown`).catch(() => {});
    else target.kill("SIGTERM");
    const exitCode = await exited;
    rmSync(temporary, { recursive: true, force: true });
    expect(output).not.toContain(marker);
    expect(exitCode, output).toBe(0);
  }
});

for (const failure of ["submit_ack", "status_after_commit"]) {
  test(`secret material is encrypted once and preserved receipts survive ${failure}`, async ({
    page,
  }) => {
    const marker = "synthetic-browser-private-marker";
    const target = { kind: "compute_workload" as const, workload_id: "workload-a" };
    const method = { backend: "openrouter", method: "credential_import", form: "api_key", schema_version: 1 };
    // The first status read after the submit is the one that fails.
    let afterSubmit = 0;
    const requests = await openDevices(
      page,
      [{ id: "workload-a", provider: "pi", target, managed: false }],
      async (request) => {
        if (request.path !== "/runtime-auth") return undefined;
        expect(request.raw).not.toContain(marker);
        expect(request.body.target).toEqual(target);
        if (request.body.action === "input_submit") {
          expect(Object.keys(JSON.parse(request.body.envelope)).sort()).toEqual(["ciphertext", "enc"]);
          await new Promise((resolve) => setTimeout(resolve, 100));
          afterSubmit = 1;
          if (failure === "submit_ack") return "abort";
          return { runtime_auth: { save_result: "committed", issue: "" } };
        }
        if (request.body.action === "status" && afterSubmit > 0 && afterSubmit++ === 1 && failure === "status_after_commit")
          return "abort";
        return request.body.action === "status"
          ? status({ provider: "pi", auth: { status: "configured" }, native_ready: true, methods: [method] })
          : {
              runtime_auth: {
                public_key: fixture.Public,
                context: { ...fixture.Context, form: "api_key", expires_at: Date.now() + 60000 },
              },
            };
      },
    );

    let dialog = await manage(page, "workload-a");
    const secret = dialog.getByRole("textbox", { name: "API key" });
    await expect(secret).toBeEnabled();
    await secret.fill(marker);
    await dialog.getByRole("button", { name: "Save to runtime" }).dblclick();
    await expect(dialog.getByRole("status")).toContainText(
      failure === "submit_ack"
        ? "The save result is unknown"
        : "The configuration is saved, but verification or the status read did not finish",
    );
    await expect(secret).toHaveValue("");
    expect(requests.filter((request) => request.body?.action === "input_submit")).toHaveLength(1);
    await dialog.getByRole("button", { name: "Check again" }).click();
    await expect(dialog.getByText("Saved, not verified", { exact: true })).toBeVisible();
    expect(requests.filter((request) => request.body?.action === "input_submit")).toHaveLength(1);

    // Closing drops typed material.
    await secret.fill(marker);
    await dialog.getByRole("button", { name: "Close" }).click();
    await expect(dialog).toHaveCount(0);
    dialog = await manage(page, "workload-a");
    await expect(dialog.getByRole("textbox", { name: "API key" })).toHaveValue("");
    expect(await page.evaluate(() => localStorage.length)).toBe(0);
  });
}

for (const end of ["close", "expiry"] as const) {
  test(`native device code is cleared on ${end}`, async ({ page }) => {
    await page.clock.install();
    await openDevices(
      page,
      [
        {
          id: "runtime",
          provider: "pi",
          target: { kind: "connected_runtime", device_id: "device", runtime_id: "runtime" },
          managed: false,
        },
      ],
      (request) =>
        request.path === "/runtime-auth"
          ? status({
              provider: "codex",
              auth: { status: "pending" },
              attempt: {
                owned: true,
                attempt_id: "attempt",
                expires_at: Date.now() + 60000,
                ceremony: {
                  verification_url: "https://auth.openai.com/codex/device",
                  user_code: "SYNTHETIC-CODE",
                },
              },
            })
          : undefined,
    );

    const dialog = await manage(page, "runtime");
    await expect(dialog.getByText("SYNTHETIC-CODE")).toBeVisible();
    await expect(
      dialog.getByRole("link", { name: "Open the provider sign-in page" }),
    ).toHaveAttribute("href", "https://auth.openai.com/codex/device");
    if (end === "close") {
      await dialog.getByRole("button", { name: "Close" }).click();
      await expect(dialog).toHaveCount(0);
    } else {
      await page.clock.runFor(61000);
      await expect(dialog.getByRole("status")).toHaveText("The sign-in expired. Check again.");
    }
    await expect(page.getByText("SYNTHETIC-CODE")).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Open the provider sign-in page" })).toHaveCount(0);
  });
}

test("Claude authorization code is HPKE sealed before native login completion", async ({ page }) => {
  const marker = "synthetic-claude-authorization-code";
  const target = { kind: "compute_workload" as const, workload_id: "claude-workload" };
  const url = "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state";
  const context = { ...fixture.Context, provider: "claude", backend: "anthropic", method: "native_login", form: "authorization_code", target_kind: "compute_workload", workload_id: "claude-workload", expires_at: Date.now() + 60000 };
  const offer = { context, public_key: fixture.Public, phase: "awaiting_user", save_result: "not_committed" };
  let started = false;
  let authenticated = false;
  const requests = await openDevices(
    page,
    [{ id: "claude-workload", provider: "claude", target, managed: false }],
    (request) => {
      if (request.path !== "/runtime-auth") return undefined;
      expect(request.raw).not.toContain(marker);
      if (request.body.action === "login_start") {
        started = true;
        return { runtime_auth: { ...offer, verification_url: url } };
      }
      if (request.body.action === "input_submit") {
        authenticated = true;
        return { runtime_auth: { save_result: "committed", issue: "" } };
      }
      return authenticated
        ? status({ provider: "claude", auth: { status: "authenticated" } })
        : started
          ? status({
              provider: "claude",
              auth: { status: "pending" },
              attempt: { owned: true, attempt_id: context.attempt_id, expires_at: context.expires_at, phase: "awaiting_user", save_result: "not_committed", issue: "", ceremony: { verification_url: url, user_code: "", input: offer } },
            })
          : status({
              provider: "claude",
              auth: { status: "unauthenticated" },
              methods: [{ backend: "anthropic", method: "native_login", form: "authorization_code", schema_version: 1 }],
            });
    },
  );

  const dialog = await manage(page, "claude-workload");
  await dialog.getByRole("button", { name: "Use provider sign-in" }).click();
  const code = dialog.getByLabel("Authorization code from the sign-in page");
  await expect(code).toBeVisible();
  await code.fill(marker);
  await dialog.getByRole("button", { name: "Submit code" }).click();
  await expect(
    dialog.getByText("Authenticated; the runtime is not ready yet", { exact: true }),
  ).toBeVisible();
  await expect(code).toHaveCount(0);
  expect(requests.filter((request) => request.body?.action === "input_submit")).toHaveLength(1);
});

test("saved-unverified completion wakes one Router request without resubmitting auth", async ({ page }) => {
  const requests = await openDevices(
    page,
    [
      {
        id: "workload-router",
        provider: "claude",
        target: { kind: "compute_workload", workload_id: "workload-router" },
        managed: false,
      },
    ],
    async (request) => {
      if (request.path === "/runtime-auth/requests/request-router/complete") {
        await new Promise((resolve) => setTimeout(resolve, 100));
        return { runtime_auth_request: { status: "completed" } };
      }
      if (request.path.startsWith("/runtime-auth/requests"))
        return {
          runtime_auth_requests: [
            { request_id: "request-router", action: "verify", target: { workload_id: "workload-router" } },
          ],
          next_cursor: null,
        };
      if (request.path === "/runtime-auth")
        return status({ provider: "claude", auth: { status: "configured" } });
      return undefined;
    },
  );

  const waiting = page
    .getByRole("main")
    .getByRole("region", { name: "Router requests waiting for an admin" });
  await waiting.getByRole("button", { name: "Handle" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  const finish = dialog.getByRole("button", { name: "Finish (saved, not verified)" });
  await expect(finish).toBeVisible();
  await finish.dblclick();
  await expect(dialog.getByRole("status")).toContainText(
    "The requester was told the configuration is saved but not verified.",
  );
  expect(
    requests.filter((request) => request.path.endsWith("/complete")).map((request) => request.body),
  ).toEqual([{ outcome: "saved_unverified" }]);
  expect(requests.filter((request) => request.body?.action === "input_submit")).toHaveLength(0);
});

test("device runtime changes organization account with one action and preserves the expected binding", async ({ page }) => {
  const accounts = [{ id: "first", version: "v1", name: "First team" }, { id: "second", version: "v2", name: "Second team" }];
  let account = accounts[0];
  let binding = { id: 41, account_id: account.id, enabled: true };
  const requests = await openDevices(
    page,
    [
      {
        id: "codex",
        provider: "codex",
        target: { kind: "connected_runtime", device_id: "mac", runtime_id: "codex" },
        managed: true,
      },
    ],
    (request) => {
      if (request.path !== "/devices/mac/runtimes/codex/managed-auth") return undefined;
      if (request.method !== "GET") {
        expect(request.body).toEqual({ account_id: "second", expected_account_version: "v2", expected_binding: binding });
        account = accounts[1];
        binding = { id: 42, account_id: account.id, enabled: true };
      }
      return { managed_auth: { source: "organization", state: "configured", provider: "codex", binding, account, accounts, actions: ["bind", "retry", "unbind"], can_configure: true, can_self_configure: true } };
    },
  );

  const dialog = await manage(page, "codex");
  // The bound account's summary line; the account picker shows the name too.
  const summary = (name: string) =>
    dialog.getByRole("paragraph").filter({ hasText: new RegExp(`^${name}$`) });
  await expect(summary("First team")).toBeVisible();
  await dialog.getByRole("button", { name: /Organization account$/ }).click();
  await page.getByRole("option", { name: "Second team" }).click();
  await dialog.getByRole("button", { name: "Change account" }).click();
  await expect(summary("Second team")).toBeVisible();
  expect(requests.filter((request) => request.method !== "GET").map((request) => request.method)).toEqual(["PUT"]);
  // A bound runtime offers no sign-in of its own.
  await expect(dialog.getByRole("button", { name: "Save to runtime" })).toHaveCount(0);
});

test("device self login survives account-list failure and explains unavailable binding state", async ({ page }) => {
  let unavailable = false;
  await openDevices(
    page,
    [
      {
        id: "codex",
        provider: "codex",
        target: { kind: "connected_runtime", device_id: "mac", runtime_id: "codex" },
        managed: true,
      },
    ],
    async (request, route) => {
      if (request.path === "/runtime-auth")
        return status({ provider: "codex", auth: { status: "unauthenticated" }, methods: [{ backend: "chatgpt", method: "native_login", form: "device_code" }] });
      if (request.path !== "/devices/mac/runtimes/codex/managed-auth") return undefined;
      if (unavailable) {
        await route.fulfill({ status: 503, json: { ok: false, error: { code: "runtime_auth_unavailable", message: "Runtime authentication is temporarily unavailable." } } });
        return "handled";
      }
      return { managed_auth: { source: "self_configured", state: "unbound", provider: "codex", can_self_configure: true, can_configure: true, accounts: [], accounts_unavailable: true, actions: ["bind"] } };
    },
  );

  let dialog = await manage(page, "codex");
  await expect(dialog.getByRole("button", { name: "Use provider sign-in" })).toBeVisible();
  await expect(dialog.getByRole("status").first()).toContainText("account list is unavailable");
  await dialog.getByRole("button", { name: "Close" }).click();

  unavailable = true;
  dialog = await manage(page, "codex");
  await expect(dialog.getByRole("status").first()).toContainText(
    "its own sign-in cannot be changed yet",
  );
  await expect(dialog.getByRole("button", { name: "Use provider sign-in" })).toHaveCount(0);
});
