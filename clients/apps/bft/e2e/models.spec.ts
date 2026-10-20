import { expect, test, type Page } from "@playwright/test";
import {
  context,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/settings/models";

const sonnet = {
  key: "catalog:claude-sonnet-4-6",
  choice: { kind: "catalog", model: "claude-sonnet-4-6" },
  label: "Claude Sonnet",
  vendor: "anthropic",
};

const models = {
  catalog_status: "ok",
  catalog: [sonnet],
  allowed_models: [],
  default_router_model: null,
  default_task_model: sonnet,
  default_options: { router: [sonnet], task: [sonnet] },
  platform_defaults: { router: null, task: null },
};

const codex = {
  id: "acct-codex",
  version: "3",
  credential_kind: "subscription_oauth",
  provider: "codex",
  name: null,
  email: "team@acme.test",
  status: "active",
  disabled: false,
  quota: {
    plan_type: "pro",
    observed_at: null,
    windows: [{ period: "week", remaining_percent: 40, reset_at: null }],
    reset_credits: { available_count: 1 },
  },
  reset_attempt: null,
  connection: null,
  compatible_runtimes: [],
};

const gateway = {
  ...codex,
  id: "acct-key",
  credential_kind: "provider_api_key",
  provider: "custom",
  name: "Team gateway",
  email: null,
  quota: null,
  connection: {
    endpoint: "https://models.example.test/v1",
    protocol: "anthropic_messages",
    auth_scheme: "bearer",
  },
  compatible_runtimes: ["pi", "claude"],
};

type Reply = { status: number; body: unknown } | undefined;

async function openModels(
  page: Page,
  handle: (request: RecordedRequest) => Reply,
  accounts: unknown[] = [codex, gateway],
  path = base
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    const answer = handle(request);
    if (answer) return answer;
    if (request.method !== "GET") return undefined;
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === `${base}`) return ok(models);
    if (request.path === `${base}/accounts`) return ok({ accounts, next: null });
    return undefined;
  });
  await page.goto(path);
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

const accounts = (page: Page) =>
  page.getByRole("list", { name: "Organization accounts" });

// The switch input is visually hidden inside its label; click the label like a user.
const toggleFor = (page: Page, name: string) =>
  page.locator("label").filter({ has: page.getByRole("switch", { name }) });

test("an import reads the pasted credentials as JSON before sending them", async ({
  page,
}) => {
  const imported = { ...codex, id: "acct-new", email: "new@acme.test" };
  const requests = await openModels(
    page,
    (request) =>
      request.method === "POST" && request.path === `${base}/accounts`
        ? ok({ accounts: [imported], next: null })
        : undefined,
    []
  );
  await expect(page.getByText("No organization accounts yet.")).toBeVisible();
  await page.getByRole("button", { name: "Add account" }).click();
  await page.getByRole("menuitem", { name: "Import credentials" }).click();
  const json = page.getByRole("textbox", { name: "Or paste credential JSON" });

  await json.fill("[1, 2]");
  await page.getByRole("button", { name: "Import subscription" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "The credentials must contain a valid JSON object."
  );
  expect(writes(requests)).toEqual([]);

  await json.fill('{"access_token":"secret","email":"new@acme.test"}');
  await page.getByRole("button", { name: "Import subscription" }).click();
  await expect(accounts(page)).toContainText("new@acme.test");
  expect(writes(requests).map(({ body }) => body)).toEqual([
    {
      kind: "subscription",
      provider: "codex",
      credentials: { access_token: "secret", email: "new@acme.test" },
      cursor: null,
    },
  ]);
});

test("disabling a Provider API key asks first; a subscription toggles at once", async ({
  page,
}) => {
  const requests = await openModels(page, (request) =>
    request.method === "PATCH"
      ? ok({
          accounts: [
            { ...codex, disabled: request.path.endsWith("acct-codex") },
            { ...gateway, disabled: request.path.endsWith("acct-key") },
          ],
          next: null,
        })
      : undefined
  );
  await toggleFor(page, "Enable Team gateway").click();
  await expect(
    page.getByRole("dialog", { name: "Disable Provider API key" })
  ).toContainText("Offline runtimes can still hold the key");
  expect(writes(requests)).toEqual([]);
  await page.getByRole("button", { name: "Disable", exact: true }).click();
  await expect(
    page.getByRole("switch", { name: "Enable Team gateway" })
  ).not.toBeChecked();

  await toggleFor(page, "Enable team@acme.test").click();
  await expect(
    page.getByRole("switch", { name: "Enable team@acme.test" })
  ).not.toBeChecked();
  expect(writes(requests).map(({ path, body }) => ({ path, body }))).toEqual([
    {
      path: `${base}/accounts/acct-key`,
      body: { version: "3", disabled: true, cursor: null },
    },
    {
      path: `${base}/accounts/acct-codex`,
      body: { version: "3", disabled: true, cursor: null },
    },
  ]);
});

test("a stale version re-reads the accounts so the next attempt is current", async ({
  page,
}) => {
  let reads = 0;
  let patches = 0;
  let stale = true;
  const requests = await openModels(page, (request) => {
    if (request.method === "GET" && request.path === `${base}/accounts`) {
      reads += 1;
      // Another admin changed the subscription after the first read.
      const current = stale ? codex : { ...codex, version: "4" };
      return ok({ accounts: [current, gateway], next: null });
    }
    if (request.method !== "PATCH") return undefined;
    patches += 1;
    return patches === 1
      ? {
          status: 409,
          body: {
            ok: false,
            error: { code: "conflict", message: "Refresh the list and try again." },
          },
        }
      : ok({
          accounts: [{ ...codex, disabled: true, version: "5" }, gateway],
          next: null,
        });
  });

  await expect(
    page.getByRole("switch", { name: "Enable team@acme.test" })
  ).toBeChecked();
  const before = reads;
  stale = false;
  await toggleFor(page, "Enable team@acme.test").click();
  await expect(page.getByText("Refresh the list and try again.")).toBeVisible();
  await expect.poll(() => reads).toBeGreaterThan(before);

  await toggleFor(page, "Enable team@acme.test").click();
  await expect(
    page.getByRole("switch", { name: "Enable team@acme.test" })
  ).not.toBeChecked();
  expect(writes(requests).map(({ body }) => body)).toEqual([
    { version: "3", disabled: true, cursor: null },
    { version: "4", disabled: true, cursor: null },
  ]);
});

test("an unconfirmed reset is checked again with the same request id", async ({
  page,
}) => {
  let attempts = 0;
  const requests = await openModels(page, (request) => {
    if (!request.path.endsWith("/reset")) return undefined;
    attempts += 1;
    return attempts === 1
      ? {
          status: 409,
          body: {
            ok: false,
            error: {
              code: "reset_pending",
              message: "The reset result is not confirmed.",
            },
          },
        }
      : ok({ outcome: "already_redeemed", quota_refreshed: true, account: codex });
  });

  await page.getByRole("button", { name: "Actions for team@acme.test" }).click();
  await page.getByRole("menuitem", { name: "Use one reset credit" }).click();
  await expect(
    page.getByRole("dialog", { name: "Use one reset credit" })
  ).toContainText("Resets available: 1");
  await page.getByRole("button", { name: "Use one reset credit" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "The reset result is not confirmed."
  );
  await page.getByRole("button", { name: "Check same reset" }).click();
  await expect(page.getByRole("status")).toContainText(
    "This reset already completed. No other reset credit was used. Allowance refreshed."
  );

  const ids = writes(requests).map(
    ({ body }) => (body as { request_id: string }).request_id
  );
  expect(ids).toHaveLength(2);
  expect(ids[0]).toMatch(/^[A-Za-z0-9_-]{16,128}$/);
  expect(ids[1]).toBe(ids[0]);
});

test("Codex connects through a polled device code; the old address opens the section", async ({
  page,
}) => {
  let polls = 0;
  const connected = { ...codex, id: "acct-2", email: "second@acme.test" };
  const requests = await openModels(
    page,
    (request) => {
      if (request.path === `${base}/accounts/oauth`) {
        return ok({
          id: "attempt-1",
          mode: "device",
          href: "https://auth.example.test/device",
          user_code: "K7QF-29XM",
          interval: 1,
        });
      }
      if (request.path === `${base}/accounts/oauth/attempt-1/complete`) {
        polls += 1;
        return ok(
          polls < 2 ? { status: "pending", interval: 1 } : { status: "connected" }
        );
      }
      if (request.path === `${base}/accounts`) {
        return ok({ accounts: polls < 2 ? [codex] : [codex, connected], next: null });
      }
      return undefined;
    },
    [],
    "/orgs/acme/settings/subscriptions"
  );
  await expect(page).toHaveURL(/\/orgs\/acme\/settings\/models#accounts$/);

  await page.getByRole("button", { name: "Add account" }).click();
  await page.getByRole("menuitem", { name: "Connect subscription" }).click();
  await page.getByRole("button", { name: "Continue with Codex" }).click();
  await expect(page.getByText("K7QF-29XM")).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Open Codex authorization" })
  ).toHaveAttribute("href", "https://auth.example.test/device");
  // At least five seconds between polls; the second one connects.
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(writes(requests).map(({ body }) => body)).toEqual([
    { provider: "codex" },
    { code: "" },
    { code: "" },
  ]);
  await expect(accounts(page)).toContainText("second@acme.test");
});

test("Claude opens its sign-in tab during the click and completes with the pasted URL", async ({
  page,
  context: browserContext,
}) => {
  await browserContext.route("https://claude.example.test/**", (route) =>
    route.fulfill({ contentType: "text/html", body: "<h1>Sign in</h1>" })
  );
  const requests = await openModels(page, (request) => {
    if (request.path === `${base}/accounts/oauth`) {
      return ok({
        id: "attempt-2",
        mode: "callback",
        href: "https://claude.example.test/authorize?code_challenge=abc",
        user_code: null,
        interval: 5,
      });
    }
    if (request.path === `${base}/accounts/oauth/attempt-2/complete`) {
      return ok({ status: "connected" });
    }
    return undefined;
  });
  await page.getByRole("button", { name: "Add account" }).click();
  await page.getByRole("menuitem", { name: "Connect subscription" }).click();
  await page.getByRole("button", { name: /Provider/ }).click();
  await page.getByRole("option", { name: "Claude" }).click();
  const popup = page.waitForEvent("popup");
  await page.getByRole("button", { name: "Continue with Claude" }).click();
  await expect(await popup).toHaveURL(/claude\.example\.test\/authorize/);

  await page
    .getByRole("textbox", { name: "Callback URL or authorization code" })
    .fill("http://localhost:54545/callback?code=c1&state=s1");
  await page.getByRole("button", { name: "Connect subscription" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(writes(requests).map(({ body }) => body)).toEqual([
    { provider: "claude" },
    { code: "http://localhost:54545/callback?code=c1&state=s1" },
  ]);
});

test("usage lists the bound workloads and says when others are hidden", async ({
  page,
}) => {
  await openModels(page, (request) =>
    request.path === `${base}/accounts/acct-key/usage`
      ? ok({
          bindings: [
            {
              project: { id: "p-1", name: "Support Desk" },
              workload_id: "wl-1",
              href: "/orgs/acme/projects/p-1/devices",
            },
          ],
          hidden_count: 2,
          next: null,
        })
      : undefined
  );
  await page.getByRole("button", { name: "Actions for Team gateway" }).click();
  await page.getByRole("menuitem", { name: "View usage" }).click();
  const dialog = page.getByRole("dialog", { name: "Account usage" });
  await expect(dialog.getByRole("link", { name: "Support Desk" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/devices"
  );
  await expect(dialog).toContainText("Workload wl-1");
  await expect(dialog).toContainText(
    "Other projects you cannot open also use this account."
  );
});

test("a selected model stays selected when an account change stops serving it", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 1400 });
  const plain = { ...sonnet, served_by: null, plans: [], key_sources: [] };
  const paid = {
    ...plain,
    key: `${sonnet.key}+paid`,
    choice: { ...sonnet.choice, allow_paid: true },
    served_by: "api_key",
    key_sources: ["Custom"],
  };
  const modelsWith = (option: unknown) => ({
    ...models,
    servable_status: "ok",
    catalog: [option],
    default_task_model: null,
    default_options: { router: [option], task: [option] },
  });
  // The gateway serves Sonnet pay-per-use until it is disabled.
  let current = modelsWith(paid);
  const requests = await openModels(page, (request) => {
    if (request.method === "GET" && request.path === base) return ok(current);
    if (request.method === "PATCH" && request.path === `${base}/accounts/acct-key`) {
      current = modelsWith(plain);
      return ok({ accounts: [codex, { ...gateway, disabled: true }], next: null });
    }
    return request.method === "PUT" ? ok(current) : undefined;
  });

  await page.getByText("Only the models I select").click();
  // The styled box covers the input and takes the click, like a user's.
  await page.getByRole("checkbox", { name: "Claude Sonnet" }).check({ force: true });
  await page.getByRole("button", { name: /Default Task model$/ }).click();
  await page
    .getByRole("option", { name: /Claude Sonnet · Pay-per-use: Custom/ })
    .click();
  await expect(page.getByRole("button", { name: /Default Task model$/ })).toContainText(
    "Pay-per-use: Custom"
  );

  // Disabling the only key reads again what serves each model.
  const reread = page.waitForRequest(
    (request) =>
      request.method() === "GET" &&
      new URL(request.url()).pathname.endsWith("/orgs/acme/settings/models")
  );
  await toggleFor(page, "Enable Team gateway").click();
  await page.getByRole("button", { name: "Disable", exact: true }).click();
  await reread;
  await expect(
    page.getByRole("button", { name: "Hide No account serves these" })
  ).toBeVisible();

  // The unsaved choice keeps its data: listed as served by no account, still
  // selected, and saved as it was rather than widening to every model.
  const kept = page.getByRole("checkbox", { name: "Claude Sonnet", checked: true });
  await expect(kept).toHaveCount(1);
  await expect(kept).toBeEnabled();
  await expect(page.getByText("Pay-per-use: Custom")).toBeVisible();
  await page.getByRole("button", { name: "Save" }).click();
  expect(
    writes(requests)
      .filter((request) => request.method === "PUT")
      .map((request) => request.body)
  ).toEqual([
    {
      allowed_models: [paid.choice],
      default_task_model: paid.choice,
      default_router_model: null,
    },
  ]);
});

test("the page fits 900 px in Chinese", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  // Phoenix writes the locale into the served page; the dev server does not.
  await page.route("**/*", async (route) => {
    if (route.request().resourceType() !== "document") return route.fallback();
    const response = await route.fetch();
    const html = (await response.text()).replace(
      "</head>",
      '<meta name="bft-locale" content="zh_Hans" /></head>'
    );
    await route.fulfill({ response, body: html });
  });
  await openModels(page, () => undefined);
  await expect(page.getByRole("heading", { name: "组织账户" })).toBeVisible();
  await expect(page.getByRole("list", { name: "组织账户" })).toContainText(
    "剩余 40%（每周）"
  );
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)
  ).toBe(true);
});
