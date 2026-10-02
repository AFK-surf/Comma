import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/devices";
const api = "/orgs/acme/projects/p-1/devices";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

// The native owner's HPKE fixture: a real one-time key and its context.
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../../../../systems/connector/salix-connect/testdata/runtime-auth/hpke-js.json",
      import.meta.url
    ),
    "utf8"
  )
) as { Context: Record<string, unknown>; Public: string };

const device = (id: string, name: string, extra: Record<string, unknown> = {}) => ({
  id,
  name,
  status: "connected",
  disconnectable: true,
  runtimes: [],
  host: null,
  os: null,
  cpu_model: null,
  cpu_count: null,
  memory_bytes: null,
  last_seen_at: new Date(Date.now() - 120_000).toISOString(),
  info_updated_at: null,
  android: null,
  ...extra,
});

const computeTarget = (id: string, provider = "pi", managed = false) => ({
  id,
  provider,
  status: "running",
  target: { kind: "compute_workload", workload_id: id },
  managed,
});

type Data = ReturnType<typeof page1>;

const page1 = (overrides: Record<string, unknown> = {}) => ({
  project,
  cloud: { enabled: true, manageable: true },
  devices: [
    device("dev-mac", "Mac Studio", {
      runtimes: [{ id: "rt-codex", provider: "codex", version: "codex-cli 1.4.2" }],
      host: "studio.local",
      os: "macOS 15.4",
      cpu_model: "Apple M2",
      cpu_count: 8,
      memory_bytes: 17_179_869_184,
    }),
    device("dev-box", "Build box", { status: "disconnected", disconnectable: false }),
  ],
  provisioning: false,
  android: {
    status: "ok",
    entitled: false,
    profiles: [],
    setup: "not_connected",
    registered: false,
  },
  compute: {
    status: "ok",
    environments: [
      { id: "env-1", desired_state: "ready", observed_state: "ready", revision: 3 },
    ],
    workloads: [{ id: "wl-shell", kind: "shell", observed_state: "pending" }],
  },
  runtime_auth: {
    targets: [
      computeTarget("wl-router", "codex", true),
      {
        id: "rt-codex",
        provider: "codex",
        status: "connected",
        target: {
          kind: "connected_runtime",
          device_id: "dev-mac",
          runtime_id: "rt-codex",
        },
        managed: true,
      },
      computeTarget("workload-a"),
    ],
    request: null,
  },
  ...overrides,
});

const failure = (status: number, code: string, message: string) => ({
  status,
  body: { ok: false, error: { code, message, details: {} } },
});

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

/** The page's data; `extra` answers anything else first. */
async function open(
  page: Page,
  handle: Handler = () => undefined,
  data: () => Data = () => page1(),
  path = base
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    const answer = handle(request);
    if (answer) return answer;
    if (request.method === "GET" && request.path === api) return ok(data());
    return undefined;
  });
  await page.goto(path);
  await expect(page.getByRole("heading", { level: 1, name: "Devices" })).toBeVisible();
  return requests;
}

interface AuthRequest {
  method: string;
  path: string;
  body: Record<string, unknown> | undefined;
  raw: string;
  csrf: string | undefined;
}

/**
 * The browser-owned runtime-auth endpoints under `/dashboard/orgs/...`; a
 * reply of "abort" drops the connection as a lost response does.
 */
async function routeAuth(page: Page, handle: (request: AuthRequest) => unknown) {
  const requests: AuthRequest[] = [];
  await page.route("**/dashboard/orgs/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const raw = request.postData() ?? "";
    const recorded: AuthRequest = {
      method: request.method(),
      path: url.pathname.replace("/dashboard/orgs/acme/projects/p-1", "") + url.search,
      body: raw ? (JSON.parse(raw) as Record<string, unknown>) : undefined,
      raw,
      csrf: (await request.allHeaders())["x-csrf-token"],
    };
    requests.push(recorded);
    const reply = handle(recorded);
    if (reply === "abort") return route.abort("failed");
    if (reply === undefined && recorded.path.startsWith("/runtime-auth/requests"))
      return route.fulfill({
        json: { ok: true, data: { runtime_auth_requests: [], next_cursor: null } },
      });
    if (reply === undefined)
      return route.fulfill({
        status: 404,
        json: { ok: false, error: { code: "not_found", message: "Not found" } },
      });
    return route.fulfill({ json: { ok: true, data: reply } });
  });
  return requests;
}

const main = (page: Page) => page.getByRole("main");
const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");
const pageReads = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method === "GET" && request.path === api);
const polls = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.path === `${api}/provisioning`);

test("lists the cloud computer, the devices, Compute and Android setup", async ({
  page,
}) => {
  await routeAuth(page, () => undefined);
  await open(page);

  const m = main(page);
  await expect(
    m.getByText("Computers and runtimes the agents of Support Desk can use.")
  ).toBeVisible();
  const cloud = m.getByRole("row", { name: /Cloud computer/ });
  await expect(cloud.getByText("Fixed · managed by Comma")).toBeVisible();
  await expect(cloud.getByText("Enabled")).toBeVisible();
  await expect(
    cloud.getByRole("switch", { name: "Use the cloud computer in this Agent Swarm" })
  ).toBeChecked();

  const mac = m.getByRole("row", { name: /Mac Studio/ });
  await expect(mac.getByText("Connected")).toBeVisible();
  await expect(mac.getByText("codex-cli 1.4.2")).toBeVisible();
  await expect(mac.getByText("studio.local")).toBeVisible();
  await expect(mac.getByText("macOS 15.4")).toBeVisible();
  await expect(mac.getByText("8 cores · 16.0 GiB")).toBeVisible();
  await expect(mac.getByText("2 minutes ago")).toBeVisible();
  await expect(
    m.getByRole("row", { name: /Build box/ }).getByText("Disconnected")
  ).toBeVisible();

  await expect(m.getByRole("row", { name: /env-1/ }).getByText("Ready")).toHaveCount(2);
  await expect(
    m.getByRole("row", { name: /wl-shell/ }).getByText("Pending")
  ).toBeVisible();
  await expect(
    m.getByText(
      "Android setup is unavailable because this organization has no Android connector entitlement. Contact your platform administrator."
    )
  ).toBeVisible();
  await expect(
    page
      .getByRole("navigation", { name: "Organization navigation" })
      .getByRole("link", { name: "Devices", exact: true })
  ).toHaveAttribute("aria-current", "page");
});

test("an entitled swarm shows its Android connector, profiles and slots", async ({
  page,
}) => {
  await routeAuth(page, () => undefined);
  await open(page, undefined, () =>
    page1({
      devices: [
        device("dev-android", "Android N2", {
          android: {
            profiles: ["api30-phone", "api35-phone-google-apis"],
            default_profile: "api35-phone-google-apis",
            active_profile: "api30-phone",
            target_profile: "api35-phone-google-apis",
            phase: "waiting_ready",
            state: "preparing",
            available_slots: 0,
            capacity: 1,
          },
        }),
      ],
      android: {
        status: "ok",
        entitled: true,
        profiles: ["api30-phone"],
        setup: "connected",
        registered: true,
      },
      compute: { status: "unavailable", environments: [], workloads: [] },
    })
  );

  const m = main(page);
  await expect(
    m.getByText("Allowed profiles: api30-phone · One concurrent lease")
  ).toBeVisible();
  await expect(
    m.getByText("The Android connector is registered to this Agent Swarm.")
  ).toBeVisible();
  for (const line of [
    "Configured profiles: api30-phone, api35-phone-google-apis",
    "Default: api35-phone-google-apis",
    "Current: api30-phone",
    "Target: api35-phone-google-apis",
    "Phase: Waiting for Android",
    "Android: Preparing",
    "0 of 1 slots available",
  ]) {
    await expect(m.getByText(line, { exact: true })).toBeVisible();
  }
  await expect(
    m.getByText("Could not load Compute readiness. Retry shortly.")
  ).toBeVisible();
});

test("turns the cloud computer off and reads the page again", async ({ page }) => {
  await routeAuth(page, () => undefined);
  let enabled = true;
  const requests = await open(
    page,
    (request) => {
      if (request.method === "PUT" && request.path === `${api}/cloud`) {
        enabled = false;
        return ok({
          enabled: false,
          notice: "Cloud computer disabled for this Agent Swarm.",
        });
      }
      return undefined;
    },
    () => page1({ cloud: { enabled, manageable: true } })
  );

  const cloud = main(page).getByRole("row", { name: /Cloud computer/ });
  // The switch input is visually hidden inside its label; click the label like a user.
  await cloud
    .locator("label")
    .filter({ has: page.getByRole("switch") })
    .click();
  await expect(
    page.getByText("Cloud computer disabled for this Agent Swarm.")
  ).toBeVisible();
  await expect(cloud.getByText("Disabled")).toBeVisible();
  await expect(cloud.getByRole("switch")).not.toBeChecked();
  expect(writes(requests)).toEqual([
    expect.objectContaining({ method: "PUT", csrf, body: { enabled: false } }),
  ]);
});

test("adds a device on a runner, then polls only until it is provisioned", async ({
  page,
}) => {
  await page.clock.install();
  await routeAuth(page, () => undefined);
  let provisioning = false;
  let answers = [true, false];
  const requests = await open(
    page,
    (request) => {
      if (request.path === `${api}/runners`)
        return ok({
          runners: [
            { id: "run-1", label: "Lab Mac mini" },
            { id: "run-2", label: "Spare Mac mini" },
          ],
          runners_href: "/orgs/acme/fin",
        });
      if (request.method === "POST" && request.path === api) {
        provisioning = true;
        return {
          status: 201,
          body: { ok: true, data: { notice: "Device connection request created." } },
        };
      }
      if (request.path === `${api}/provisioning`) {
        const active = answers.shift() ?? false;
        provisioning = active;
        return ok({ active });
      }
      return undefined;
    },
    () => page1({ provisioning })
  );

  await page.getByRole("button", { name: "Add device" }).click();
  const dialog = page.getByRole("dialog", { name: "Add device" });
  await dialog.getByLabel("Name").fill("staging-box");
  await dialog.getByLabel("Alias").fill("prod-mac");
  await dialog.getByRole("button", { name: /Runner/ }).click();
  await page.getByRole("option", { name: "Spare Mac mini" }).click();
  await dialog.getByRole("button", { name: "Create on runner" }).click();

  await expect(page.getByText("Device connection request created.")).toBeVisible();
  await expect(dialog).toHaveCount(0);
  expect(writes(requests)).toEqual([
    expect.objectContaining({
      method: "POST",
      path: api,
      csrf,
      body: { name: "staging-box", alias: "prod-mac", runner_id: "run-2" },
    }),
  ]);
  const status = main(page).getByText(
    "A device is being connected. The list updates when it is ready."
  );
  await expect(status).toBeVisible();
  const readsBefore = pageReads(requests).length;

  // Still provisioning: the page is not read again.
  await page.clock.runFor(2_100);
  await expect.poll(() => polls(requests).length).toBe(1);
  expect(pageReads(requests)).toHaveLength(readsBefore);
  // Done: the page is read once more and the poll stops.
  await page.clock.runFor(2_100);
  await expect.poll(() => polls(requests).length).toBe(2);
  await expect(status).toHaveCount(0);
  expect(pageReads(requests)).toHaveLength(readsBefore + 1);
  await page.clock.runFor(10_000);
  expect(polls(requests)).toHaveLength(2);
});

test("the provisioning poll waits for each reply, pauses while hidden and stops on leaving", async ({
  page,
}) => {
  await page.clock.install();
  await routeAuth(page, () => undefined);
  const requests = await open(
    page,
    (request) =>
      request.path === `${api}/provisioning` ? ok({ active: true }) : undefined,
    () => page1({ provisioning: true })
  );
  // Every poll is counted when it leaves; the first reply is held until released.
  const sent: number[] = [];
  let release: (() => void) | undefined;
  const held = new Promise<void>((resolve) => (release = resolve));
  await page.route(`**/dashboard/api/v1${api}/provisioning`, async (route) => {
    sent.push(sent.length + 1);
    if (sent.length === 1) await held;
    await route.fallback();
  });

  await page.clock.runFor(2_100);
  await expect.poll(() => sent.length).toBe(1);
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(1);
  release?.();
  await expect.poll(() => polls(requests).length).toBe(1);
  await page.clock.runFor(2_100);
  await expect.poll(() => sent.length).toBe(2);

  const setHidden = (hidden: boolean) =>
    page.evaluate((value) => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => value,
      });
      document.dispatchEvent(new Event("visibilitychange"));
    }, hidden);
  await setHidden(true);
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(2);
  // Visible again: it checks at once.
  await setHidden(false);
  await expect.poll(() => sent.length).toBe(3);

  await page.evaluate(() => {
    window.history.pushState(null, "", "/orgs/acme/members");
    window.dispatchEvent(new Event("bft:locationchange"));
  });
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(3);
});

test("without an online runner the dialog links Runners and checks again", async ({
  page,
}) => {
  await routeAuth(page, () => undefined);
  const requests = await open(page, (request) =>
    request.path === `${api}/runners`
      ? ok({ runners: [], runners_href: "/orgs/acme/fin" })
      : undefined
  );

  await page.getByRole("button", { name: "Add device" }).click();
  const dialog = page.getByRole("dialog", { name: "No runners connected" });
  await expect(
    dialog.getByText("Connect a runner in Runners before creating a project device.")
  ).toBeVisible();
  await expect(dialog.getByRole("link", { name: "Open Runners" })).toHaveAttribute(
    "href",
    "/orgs/acme/fin"
  );
  const reads = () =>
    requests.filter((request) => request.path === `${api}/runners`).length;
  const before = reads();
  await dialog.getByRole("button", { name: "Check for runners" }).click();
  await expect.poll(reads).toBe(before + 1);
  expect(writes(requests)).toEqual([]);
});

test("disconnects and deletes a device after confirming", async ({ page }) => {
  await routeAuth(page, () => undefined);
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/dev-mac/disconnect`)
      return ok({ notice: "Device disconnected." });
    if (request.method === "DELETE" && request.path === `${api}/dev-box`)
      return ok({ notice: "Device deleted." });
    return undefined;
  });

  // A disconnected device can only be deleted.
  await page.getByRole("button", { name: "Actions for Build box" }).click();
  await expect(page.getByRole("menuitem", { name: "Disconnect" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  await page.getByRole("button", { name: "Actions for Mac Studio" }).click();
  await page.getByRole("menuitem", { name: "Disconnect" }).click();
  const disconnect = page.getByRole("dialog", { name: "Disconnect device" });
  await expect(disconnect.getByText(/Disconnect Mac Studio\?/)).toBeVisible();
  await disconnect.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Device disconnected.")).toBeVisible();

  await page.getByRole("button", { name: "Actions for Build box" }).click();
  await page.getByRole("menuitem", { name: "Delete" }).click();
  const remove = page.getByRole("dialog", { name: "Delete device" });
  await expect(
    remove.getByText(
      "Delete Build box? It will be disconnected and removed from this Agent Swarm. Agents using it will become unavailable."
    )
  ).toBeVisible();
  await remove.getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Device deleted.")).toBeVisible();

  expect(
    writes(requests).map(({ method, path, csrf: token }) => [method, path, token])
  ).toEqual([
    ["POST", `${api}/dev-mac/disconnect`, csrf],
    ["DELETE", `${api}/dev-box`, csrf],
  ]);
});

test("Compute: a Shell workload after confirming; drain and revoke carry the revision", async ({
  page,
}) => {
  await routeAuth(page, () => undefined);
  const requests = await open(page, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/shell")
      return {
        status: 201,
        body: {
          ok: true,
          data: {
            notice: "Shell workload accepted. Refresh to check its runtime status.",
          },
        },
      };
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/drain")
      return ok({ notice: "Compute environment updated." });
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/revoke")
      return failure(
        409,
        "environment_changed",
        "This Compute environment changed. Refresh and try again."
      );
    return undefined;
  });

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Create Shell workload" }).click();
  const shell = page.getByRole("dialog", { name: "Create Shell workload" });
  await expect(
    shell.getByText(
      "Create a Shell workload in this environment? It has a 512 PID limit, a 2 GiB writable disk limit, and no network access."
    )
  ).toBeVisible();
  await shell.getByRole("button", { name: "Create Shell workload" }).click();
  await expect(
    page.getByText("Shell workload accepted. Refresh to check its runtime status.")
  ).toBeVisible();

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Drain" }).click();
  await expect(page.getByText("Compute environment updated.")).toBeVisible();

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Revoke" }).click();
  await expect(
    page.getByText("This Compute environment changed. Refresh and try again.")
  ).toBeVisible();

  expect(writes(requests).map(({ path, body }) => [path, body])).toEqual([
    ["/orgs/acme/projects/p-1/compute/env-1/shell", undefined],
    ["/orgs/acme/projects/p-1/compute/env-1/drain", { expected_revision: 3 }],
    ["/orgs/acme/projects/p-1/compute/env-1/revoke", { expected_revision: 3 }],
  ]);
});

test("a swarm member reads the page without admin controls", async ({ page }) => {
  await routeAuth(page, (request) =>
    request.path.startsWith("/runtime-auth/requests")
      ? {
          runtime_auth_requests: [
            {
              request_id: "req-1",
              action: "verify",
              target: { workload_id: "wl-router" },
            },
          ],
          next_cursor: null,
        }
      : undefined
  );
  await open(page, undefined, () =>
    page1({
      project: { ...project, role: "user" },
      cloud: { enabled: true, manageable: false },
    })
  );

  const m = main(page);
  await expect(m.getByRole("row", { name: /Mac Studio/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Add device" })).toHaveCount(0);
  await expect(m.getByRole("switch")).toHaveCount(0);
  await expect(m.getByRole("button", { name: /^Actions for/ })).toHaveCount(0);
  // Organization-managed targets can be viewed; the rest need an admin.
  await expect(m.getByRole("button", { name: "View wl-router" })).toBeVisible();
  await expect(
    m.getByRole("row", { name: /workload-a/ }).getByText("An admin must finish this")
  ).toBeVisible();
  await expect(
    m
      .getByRole("region", { name: "Router requests waiting for an admin" })
      .getByText("An admin must finish this")
  ).toBeVisible();
  await expect(m.getByRole("button", { name: "Handle" })).toHaveCount(0);
});

test("binding an organization account survives a lost response", async ({ page }) => {
  let state = "unbound";
  const account = { id: "acct-1", version: "v1", name: "Team ChatGPT" };
  const auth = await routeAuth(page, (request) => {
    if (!request.path.startsWith("/workloads/wl-router/managed-auth")) return undefined;
    if (request.method === "PUT") {
      state = "configured";
      return "abort";
    }
    const binding =
      state === "unbound" ? null : { id: 7, account_id: account.id, enabled: true };
    return {
      mode: "managed_auth",
      managed_auth: {
        state,
        provider: "codex",
        binding,
        account: binding ? account : null,
        accounts: [account],
        actions: state === "unbound" ? ["bind"] : ["refresh", "unbind"],
        can_configure: true,
      },
    };
  });
  await open(page);

  await page.getByRole("button", { name: "Manage wl-router" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  await expect(
    dialog.getByText("This runtime uses its own configuration.")
  ).toBeVisible();
  await dialog.getByRole("button", { name: /Credential source/ }).click();
  await page.getByRole("option", { name: "Organization account" }).click();
  await dialog.getByRole("button", { name: "Bind account" }).click();

  await expect(dialog.getByText("Organization account configured.")).toBeVisible();
  await expect(dialog.getByRole("status").first()).toHaveText(
    "The result is uncertain. The current state was read again."
  );
  const puts = auth.filter((request) => request.method === "PUT");
  expect(puts).toHaveLength(1);
  expect(puts[0]?.body).toEqual({
    account_id: "acct-1",
    expected_account_version: "v1",
    expected_binding: null,
  });
  expect(puts[0]?.csrf).toBe(csrf);
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
});

test("an API key is sealed once and a lost submit stays unknown", async ({ page }) => {
  const marker = "synthetic-browser-private-marker";
  let statusReads = 0;
  const auth = await routeAuth(page, (request) => {
    if (request.path !== "/runtime-auth") return undefined;
    expect(request.raw).not.toContain(marker);
    expect(request.body?.target).toEqual({
      kind: "compute_workload",
      workload_id: "workload-a",
    });
    switch (request.body?.action) {
      case "status":
        statusReads += 1;
        return {
          runtime_auth: {
            provider: "pi",
            auth: { status: statusReads > 1 ? "configured" : "unauthenticated" },
            native_ready: true,
            dispatch_ready: false,
            methods: [
              { backend: "openrouter", method: "credential_import", form: "api_key" },
            ],
            attempt: null,
          },
        };
      case "input_begin":
        return {
          runtime_auth: {
            public_key: fixture.Public,
            context: { ...fixture.Context, expires_at: Date.now() + 60_000 },
          },
        };
      case "input_submit":
        return "abort";
      default:
        return undefined;
    }
  });
  await open(page);

  await page.getByRole("button", { name: "Manage workload-a" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  const secret = dialog.getByRole("textbox", { name: "API key" });
  await expect(secret).toBeEnabled();
  await secret.fill(marker);
  await dialog.getByRole("button", { name: "Save to runtime" }).dblclick();

  await expect(dialog.getByRole("status")).toContainText("The save result is unknown");
  await expect(secret).toHaveValue("");
  const submits = auth.filter((request) => request.body?.action === "input_submit");
  expect(submits).toHaveLength(1);
  const envelope = JSON.parse(String(submits[0]?.body?.envelope)) as Record<
    string,
    string
  >;
  expect(Object.keys(envelope).toSorted()).toEqual(["ciphertext", "enc"]);
  expect(submits[0]?.body?.attempt_id).toBe("attempt-a");

  await dialog.getByRole("button", { name: "Check again" }).click();
  await expect(dialog.getByText("Saved, not verified", { exact: true })).toBeVisible();
  expect(
    auth.filter((request) => request.body?.action === "input_submit")
  ).toHaveLength(1);
  expect(auth.every((request) => !request.raw.includes(marker))).toBe(true);
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
});

for (const end of ["close", "expiry"] as const) {
  test(`a provider device code is cleared on ${end}`, async ({ page }) => {
    await page.clock.install();
    await routeAuth(page, (request) =>
      request.path === "/runtime-auth"
        ? {
            runtime_auth: {
              provider: "pi",
              auth: { status: "pending" },
              native_ready: true,
              dispatch_ready: false,
              methods: [],
              attempt: {
                owned: true,
                attempt_id: "attempt",
                phase: "completed",
                expires_at: Date.now() + 60_000,
                ceremony: {
                  verification_url: "https://auth.openai.com/codex/device",
                  user_code: "SYNTHETIC-CODE",
                },
              },
            },
          }
        : undefined
    );
    await open(page);

    await page.getByRole("button", { name: "Manage workload-a" }).click();
    const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
    await expect(dialog.getByText("SYNTHETIC-CODE")).toBeVisible();
    await expect(
      dialog.getByRole("link", { name: "Open the provider sign-in page" })
    ).toHaveAttribute("href", "https://auth.openai.com/codex/device");
    if (end === "close") {
      await dialog.getByRole("button", { name: "Close" }).click();
      await expect(dialog).toHaveCount(0);
    } else {
      await page.clock.runFor(61_000);
      await expect(dialog.getByRole("status")).toHaveText(
        "The sign-in expired. Check again."
      );
    }
    await expect(page.getByText("SYNTHETIC-CODE")).toHaveCount(0);
    await expect(
      page.getByRole("link", { name: "Open the provider sign-in page" })
    ).toHaveCount(0);
  });
}

test("changing the input method clears an entered API key", async ({ page }) => {
  await routeAuth(page, (request) => {
    if (request.path !== "/runtime-auth") return undefined;
    if (request.body?.action !== "status") return undefined;
    return {
      runtime_auth: {
        provider: "pi",
        auth: { status: "unauthenticated" },
        native_ready: true,
        dispatch_ready: false,
        methods: [
          { backend: "openrouter", method: "credential_import", form: "api_key" },
          { backend: "anthropic", method: "credential_import", form: "api_key" },
        ],
        attempt: null,
      },
    };
  });
  await open(page);

  await page.getByRole("button", { name: "Manage workload-a" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  const secret = dialog.getByRole("textbox", { name: "API key" });
  await expect(secret).toBeEnabled();
  await secret.fill("key-for-openrouter");
  await dialog.getByRole("button", { name: /Input method/ }).click();
  await page.getByRole("option", { name: "anthropic · Enter an API key" }).click();
  await expect(secret).toHaveValue("");
});

test("a Claude authorization code is sealed before it completes the sign-in", async ({
  page,
}) => {
  const marker = "synthetic-claude-authorization-code";
  const url =
    "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&scope=user%3Ainference&state=state";
  const signIn = {
    ...fixture.Context,
    provider: "claude",
    backend: "anthropic",
    method: "native_login",
    form: "authorization_code",
    expires_at: Date.now() + 60_000,
  };
  const offer = { context: signIn, public_key: fixture.Public, phase: "awaiting_user" };
  let started = false;
  let authenticated = false;
  const auth = await routeAuth(page, (request) => {
    if (request.path !== "/runtime-auth") return undefined;
    expect(request.raw).not.toContain(marker);
    const action = request.body?.action;
    if (action === "login_start") {
      started = true;
      return { runtime_auth: { ...offer, verification_url: url } };
    }
    if (action === "input_submit") {
      authenticated = true;
      return { runtime_auth: { save_result: "committed", issue: "" } };
    }
    return {
      runtime_auth: authenticated
        ? {
            provider: "claude",
            auth: { status: "authenticated" },
            methods: [],
            attempt: null,
          }
        : started
          ? {
              provider: "claude",
              auth: { status: "pending" },
              methods: [],
              attempt: {
                owned: true,
                attempt_id: fixture.Context.attempt_id,
                expires_at: signIn.expires_at,
                phase: "completed",
                ceremony: { verification_url: url, user_code: "", input: offer },
              },
            }
          : {
              provider: "claude",
              auth: { status: "unauthenticated" },
              methods: [
                {
                  backend: "anthropic",
                  method: "native_login",
                  form: "authorization_code",
                },
              ],
              attempt: null,
            },
    };
  });
  await open(page);

  await page.getByRole("button", { name: "Manage workload-a" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  await dialog.getByRole("button", { name: "Use provider sign-in" }).click();
  const code = dialog.getByLabel("Authorization code from the sign-in page");
  await expect(code).toBeVisible();
  await code.fill(marker);
  await dialog.getByRole("button", { name: "Submit code" }).click();

  await expect(
    dialog.getByText("Authenticated; the runtime is not ready yet", { exact: true })
  ).toBeVisible();
  const submits = auth.filter((request) => request.body?.action === "input_submit");
  expect(submits).toHaveLength(1);
  expect(submits[0]?.body?.attempt_id).toBe("attempt-a");
});

test("a Router request is finished once as saved but not verified", async ({
  page,
}) => {
  const auth = await routeAuth(page, (request) => {
    if (request.path.startsWith("/runtime-auth/requests/req-1/complete"))
      return { runtime_auth_request: { status: "completed" } };
    if (request.path.startsWith("/runtime-auth/requests"))
      return {
        runtime_auth_requests: [
          { request_id: "req-1", action: "verify", target: { workload_id: "wl-gone" } },
        ],
        next_cursor: null,
      };
    if (request.path === "/workloads/wl-gone/managed-auth")
      return {
        managed_auth: {
          state: "unbound",
          binding: null,
          accounts: [],
          actions: ["bind"],
          can_configure: true,
        },
      };
    if (request.path === "/runtime-auth")
      return {
        runtime_auth: {
          provider: "claude",
          auth: { status: "configured" },
          methods: [],
          attempt: null,
        },
      };
    return undefined;
  });
  await open(page);

  const requests = main(page).getByRole("region", {
    name: "Router requests waiting for an admin",
  });
  await expect(requests.getByText("verify · wl-gone")).toBeVisible();
  await requests.getByRole("button", { name: "Handle" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  await expect(
    dialog.getByText("Not read yet · Agents that use this runtime share this change.")
  ).toBeVisible();
  const finish = dialog.getByRole("button", { name: "Finish (saved, not verified)" });
  await finish.dblclick();
  await expect(dialog.getByRole("status").last()).toHaveText(
    "The requester was told the configuration is saved but not verified."
  );
  await expect(finish).toHaveCount(0);
  const completions = auth.filter((request) => request.path.endsWith("/complete"));
  expect(completions.map((request) => request.body)).toEqual([
    { outcome: "saved_unverified" },
  ]);
});

test("a handled Router request leaves the list when its dialog closes", async ({
  page,
}) => {
  let completed = false;
  await routeAuth(page, (request) => {
    if (request.path.startsWith("/runtime-auth/requests/req-1/complete")) {
      completed = true;
      return { runtime_auth_request: { status: "completed" } };
    }
    if (request.path.startsWith("/runtime-auth/requests"))
      return {
        runtime_auth_requests: completed
          ? []
          : [
              {
                request_id: "req-1",
                action: "verify",
                target: { workload_id: "wl-gone" },
              },
            ],
        next_cursor: null,
      };
    if (request.path === "/workloads/wl-gone/managed-auth")
      return {
        managed_auth: {
          state: "unbound",
          binding: null,
          accounts: [],
          actions: ["bind"],
          can_configure: true,
        },
      };
    if (request.path === "/runtime-auth")
      return {
        runtime_auth: {
          provider: "claude",
          auth: { status: "configured" },
          methods: [],
          attempt: null,
        },
      };
    return undefined;
  });
  await open(page);

  const requests = main(page).getByRole("region", {
    name: "Router requests waiting for an admin",
  });
  await requests.getByRole("button", { name: "Handle" }).click();
  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  await dialog.getByRole("button", { name: "Finish (saved, not verified)" }).click();
  await expect(dialog.getByRole("status").last()).toHaveText(
    "The requester was told the configuration is saved but not verified."
  );
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(requests).toHaveCount(0);
});

test("Router requests page on even when a page is empty", async ({ page }) => {
  await routeAuth(page, (request) => {
    if (request.path === "/runtime-auth/requests")
      return { runtime_auth_requests: [], next_cursor: "page-two" };
    if (request.path === "/runtime-auth/requests?cursor=page-two")
      return {
        runtime_auth_requests: [
          {
            request_id: "req-2",
            action: "login",
            target: { workload_id: "wl-router" },
          },
        ],
        next_cursor: null,
      };
    return undefined;
  });
  await open(page);

  const requests = main(page).getByRole("region", {
    name: "Router requests waiting for an admin",
  });
  await requests.getByRole("button", { name: "Next page" }).click();
  await expect(requests.getByText("login · wl-router")).toBeVisible();
  await expect(requests.getByRole("button", { name: "Next page" })).toHaveCount(0);
});

test("a management link opens its target and leaves the address when closed", async ({
  page,
}) => {
  await routeAuth(page, (request) =>
    request.path === "/runtime-auth"
      ? {
          runtime_auth: {
            provider: "pi",
            auth: { status: "unauthenticated" },
            methods: [],
            attempt: null,
          },
        }
      : undefined
  );
  const requests = await open(
    page,
    undefined,
    () =>
      page1({
        runtime_auth: {
          ...page1().runtime_auth,
          request: {
            request_id: "req-9",
            action: "verify",
            target: { workload_id: "workload-a" },
          },
        },
      }),
    `${base}?runtime_auth_target=workload-a&runtime_auth_request=req-9`
  );

  const dialog = page.getByRole("dialog", { name: "Manage runtime authentication" });
  await expect(dialog.getByText("workload-a", { exact: true })).toBeVisible();
  expect(pageReads(requests)[0]?.search).toBe(
    "?runtime_auth_target=workload-a&runtime_auth_request=req-9"
  );
  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
  await expect(dialog).toHaveCount(0);
});

test("the page fits a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await routeAuth(page, () => undefined);
  await open(page);
  await expect(main(page).getByRole("row", { name: /Mac Studio/ })).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    )
  ).toBe(0);
  // The narrower table leaves out CPU and memory.
  await expect(main(page).getByText("CPU / Memory")).toBeHidden();
});
