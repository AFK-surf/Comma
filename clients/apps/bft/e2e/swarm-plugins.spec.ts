import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/plugins";
const api = "/orgs/acme/projects/p-1/plugins";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const refs = (extra = {}) => ({
  tool_refs: [],
  skill_refs: [],
  mcp_refs: [],
  oauth_requirements: [],
  im_connect_requirements: [],
  ...extra,
});

const plugin = (
  plugin_id: string,
  name: string,
  owner_scope: string,
  extra: Record<string, unknown> = {}
) => ({
  plugin_id,
  name,
  description: `${name} description`,
  owner_scope,
  enabled: false,
  locked: false,
  toggleable: true,
  editable: false,
  attention: [],
  refs: refs(),
  setup_destination: null,
  ...extra,
});

const plugins = () => [
  plugin("android-control", "Android Control", "system", { toggleable: false }),
  plugin("system.search", "Core Search", "system", {
    enabled: true,
    locked: true,
    toggleable: false,
  }),
  plugin("tenant.knowledge", "Knowledge Pack", "tenant", { enabled: true }),
  plugin("linear", "Linear", "system", { attention: ["linear"] }),
  plugin("group.release", "Release Helper", "group", {
    editable: true,
    refs: refs({ skill_refs: ["release-checklist"] }),
    setup_destination: "project_skills",
  }),
];

const list = (extra: Record<string, unknown> = {}) => ({
  project,
  plugins: plugins(),
  android: { status: "ok", entitled: false },
  ...extra,
});

const credential = (
  id: string,
  kind: string,
  label: string,
  extra: Record<string, unknown> = {}
) => ({
  id,
  kind,
  label,
  state: "not_connected",
  dependent_mcps: [],
  action: "connect",
  disconnectable: false,
  integrations_href: null,
  ...extra,
});

const linear = (extra: Record<string, unknown> = {}) => ({
  project,
  android: null,
  plugin: {
    ...plugin("linear", "Linear", "system", { enabled: true }),
    setup: {
      mcps: [
        {
          alias: "linear",
          placement: "server",
          state: "waiting_for_oauth",
          connections: [
            credential("linear-native", "native_mcp_oauth", "Linear MCP OAuth", {
              dependent_mcps: ["linear"],
            }),
            credential("linear-managed", "managed_oauth", "Linear OAuth", {
              state: "connected",
              action: "reconnect",
              disconnectable: true,
              dependent_mcps: ["linear"],
            }),
          ],
        },
      ],
      connections: [
        credential("linear-composio", "composio", "Linear via Composio", {
          state: "external",
        }),
        credential("slack-im", "im_connect", "Slack messaging", {
          action: null,
          integrations_href: "/orgs/acme/projects/p-1/connections?provider=slack",
        }),
      ],
    },
  },
  ...extra,
});

const failure = (status: number, code: string, message: string) => ({
  status,
  body: { ok: false, error: { code, message, details: {} } },
});

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

async function open(page: Page, handle: Handler = () => undefined, path = base) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    const answer = handle(request);
    if (answer) return answer;
    if (request.method === "GET" && request.path === api) return ok(list());
    if (request.method === "GET" && request.path === `${api}/linear`)
      return ok(linear());
    return undefined;
  });
  await page.goto(path);
  return requests;
}

const main = (page: Page) => page.getByRole("main");
// The switch input is visually hidden inside its label; click the label like a user.
const toggle = (page: Page, name: string) =>
  main(page)
    .locator("label")
    .filter({ has: page.getByRole("switch", { name }) })
    .click();
const rows = (page: Page) =>
  main(page).getByRole("list", { name: "All plugins" }).getByRole("listitem");
const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

/** Holds the answer to `path` until the returned function releases it. */
async function hold(
  page: Page,
  path: string,
  reply: { status: number; body: unknown }
) {
  let resolve: (() => void) | undefined;
  const released = new Promise<void>((done) => {
    resolve = done;
  });
  await page.route(`**/dashboard/api/v1${path}`, async (route) => {
    await released;
    await route.fulfill({ status: reply.status, json: reply.body });
  });
  return () => resolve?.();
}

/** An in-app move to `path`, as the browser's history buttons make. */
const moveTo = (page: Page, path: string) =>
  page.evaluate((to) => {
    window.history.pushState(null, "", to);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }, path);

test("lists the swarm's plugins and filters them by text, source and state", async ({
  page,
}) => {
  await open(page);
  await expect(page.getByRole("heading", { level: 1, name: "Plugins" })).toBeVisible();
  await expect(
    main(page).getByText("Choose which products Support Desk can use.")
  ).toBeVisible();
  await expect(main(page).getByText("2 enabled · 3 disabled")).toBeVisible();
  await expect(rows(page)).toHaveCount(5);

  // A required plugin's switch is on and cannot be pressed; Android needs admission.
  await expect(
    page.getByRole("switch", { name: "Core Search is required" })
  ).toBeChecked();
  await expect(
    page.getByRole("switch", { name: "Core Search is required" })
  ).toBeDisabled();
  await expect(
    page.getByRole("switch", { name: "Enable Android Control" })
  ).toBeDisabled();
  await expect(
    rows(page).filter({ hasText: "Linear" }).getByText("linear needs setup")
  ).toBeVisible();
  // Only the swarm's own plugin can be edited.
  await expect(page.getByRole("button", { name: /^Edit / })).toHaveCount(1);

  await page.getByRole("searchbox", { name: "Search plugins" }).fill("checklist");
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("Release Helper");
  await page.getByRole("searchbox", { name: "Search plugins" }).fill("");

  await page.getByRole("button", { name: /Source/ }).click();
  await page.getByRole("option", { name: "Organization" }).click();
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("Knowledge Pack");

  await page.getByRole("button", { name: /Source/ }).click();
  await page.getByRole("option", { name: "All sources" }).click();
  await page.getByRole("button", { name: /State/ }).click();
  await page.getByRole("option", { name: "Enabled" }).click();
  await expect(rows(page)).toHaveCount(2);

  await page.getByRole("searchbox", { name: "Search plugins" }).fill("nothing here");
  await expect(main(page).getByText(/No matching plugins/)).toBeVisible();
  await main(page).getByRole("button", { name: "Clear filters" }).click();
  await expect(rows(page)).toHaveCount(5);
});

test("turns a plugin on and off and reads the list again", async ({ page }) => {
  let enabled = false;
  const requests = await open(page, (request) => {
    if (
      request.method === "PUT" &&
      request.path === `${api}/group.release/enablement`
    ) {
      enabled = (request.body as { enabled: boolean }).enabled;
      return ok({ notice: enabled ? "Plugin enabled." : "Plugin disabled." });
    }
    if (request.method === "PUT" && request.path === `${api}/linear/enablement`)
      return failure(
        503,
        "runtime_unavailable",
        "Salix is unavailable. Retry shortly."
      );
    if (request.method === "GET" && request.path === api)
      return ok(
        list({
          plugins: plugins().map((item) =>
            item.plugin_id === "group.release" ? { ...item, enabled } : item
          ),
        })
      );
    return undefined;
  });

  await toggle(page, "Enable Release Helper");
  await expect(page.getByText("Plugin enabled.")).toBeVisible();
  await expect(
    page.getByRole("switch", { name: "Disable Release Helper" })
  ).toBeChecked();

  await toggle(page, "Enable Linear");
  await expect(page.getByText("Salix is unavailable. Retry shortly.")).toBeVisible();

  expect(
    writes(requests).map(({ path, body, csrf: token }) => [path, body, token])
  ).toEqual([
    [`${api}/group.release/enablement`, { enabled: true }, csrf],
    [`${api}/linear/enablement`, { enabled: true }, csrf],
  ]);
});

test("each switch stays busy until its own write ends", async ({ page }) => {
  await open(page);
  const releaseRelease = await hold(
    page,
    `${api}/group.release/enablement`,
    ok({
      notice: "Plugin enabled.",
    })
  );
  const releaseKnowledge = await hold(
    page,
    `${api}/tenant.knowledge/enablement`,
    ok({
      notice: "Plugin disabled.",
    })
  );

  await toggle(page, "Enable Release Helper");
  await toggle(page, "Disable Knowledge Pack");
  await expect(
    page.getByRole("switch", { name: "Enable Release Helper" })
  ).toBeDisabled();
  await expect(
    page.getByRole("switch", { name: "Disable Knowledge Pack" })
  ).toBeDisabled();

  releaseRelease();
  await expect(page.getByText("Plugin enabled.")).toBeVisible();
  await expect(
    page.getByRole("switch", { name: "Enable Release Helper" })
  ).toBeEnabled();
  // The other write is still running: its switch stays busy.
  await expect(
    page.getByRole("switch", { name: "Disable Knowledge Pack" })
  ).toBeDisabled();

  releaseKnowledge();
  await expect(page.getByText("Plugin disabled.")).toBeVisible();
  await expect(
    page.getByRole("switch", { name: "Disable Knowledge Pack" })
  ).toBeEnabled();
});

test("a failed reload after a write keeps the list and says it may be out of date", async ({
  page,
}) => {
  let reloadFails = false;
  await open(page, (request) => {
    if (
      request.method === "PUT" &&
      request.path === `${api}/group.release/enablement`
    ) {
      reloadFails = true;
      return ok({ notice: "Plugin enabled." });
    }
    if (request.method === "GET" && request.path === api && reloadFails)
      return failure(500, "internal", "Internal error");
    return undefined;
  });
  await expect(rows(page)).toHaveCount(5);

  await toggle(page, "Enable Release Helper");
  await expect(page.getByText("Plugin enabled.")).toBeVisible();
  const stale = main(page)
    .getByRole("alert")
    .filter({ hasText: "Could not refresh. What you see may be out of date." });
  await expect(stale).toBeVisible();
  await expect(rows(page)).toHaveCount(5);

  reloadFails = false;
  await stale.getByRole("button", { name: "Retry" }).click();
  await expect(stale).toHaveCount(0);
  await expect(rows(page)).toHaveCount(5);
});

test("creates a project plugin and edits the swarm's own plugin", async ({ page }) => {
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === api)
      return {
        status: 201,
        body: {
          ok: true,
          data: { plugin_id: "group.docs", notice: "Plugin created: group.docs." },
        },
      };
    if (request.method === "PUT" && request.path === `${api}/group.release`)
      return ok({ notice: "Plugin updated." });
    return undefined;
  });

  await page.getByRole("button", { name: "New project plugin" }).click();
  const create = page.getByRole("dialog", { name: "New project plugin" });
  await create.getByRole("button", { name: "Save" }).click();
  await expect(create.getByText("Enter a name.")).toBeVisible();
  await create.getByRole("textbox", { name: "Name" }).fill("Docs");
  await create
    .getByRole("textbox", { name: "Tools" })
    .fill('docs.search\n{"tool": "docs.read"}');
  await create.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Plugin created: group.docs.")).toBeVisible();

  await page.getByRole("button", { name: "Edit Release Helper" }).click();
  const edit = page.getByRole("dialog", { name: "Edit Release Helper" });
  await expect(edit.getByRole("textbox", { name: "Skills" })).toHaveValue(
    "release-checklist"
  );
  await edit.getByRole("textbox", { name: "Name" }).fill("Release");
  await edit.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Plugin updated.")).toBeVisible();

  expect(
    writes(requests).map(({ method, path, body }) => [method, path, body])
  ).toEqual([
    [
      "POST",
      api,
      {
        name: "Docs",
        description: "",
        setup_destination: "",
        refs: refs({ tool_refs: ["docs.search", { tool: "docs.read" }] }),
      },
    ],
    [
      "PUT",
      `${api}/group.release`,
      {
        name: "Release",
        description: "Release Helper description",
        setup_destination: "project_skills",
        refs: refs({ skill_refs: ["release-checklist"] }),
      },
    ],
  ]);
});

test("a plugin's page shows its MCP servers and credentials", async ({ page }) => {
  await open(page);
  await rows(page)
    .filter({ hasText: "Linear" })
    .getByRole("link", { name: "Linear" })
    .click();
  await expect(page).toHaveURL(/\/plugins\/linear$/);
  await expect(page.getByRole("heading", { level: 1, name: "Linear" })).toBeVisible();
  // The sidebar keeps Plugins current.
  await expect(
    page
      .getByRole("navigation")
      .getByRole("link", { name: "Plugins", exact: true })
      .first()
  ).toBeVisible();

  const servers = main(page).getByRole("region", { name: "MCP servers" });
  await expect(servers.getByText("Waiting for OAuth")).toBeVisible();
  const native = servers.getByRole("listitem").filter({ hasText: "Linear MCP OAuth" });
  await expect(native.getByText("Native MCP OAuth")).toBeVisible();
  await expect(native.getByText("Not connected")).toBeVisible();
  await expect(
    servers.getByRole("button", { name: "Reconnect Linear OAuth" })
  ).toBeVisible();

  const others = main(page).getByRole("region", { name: "Credentials" });
  await expect(others.getByText("Direct API connection")).toBeVisible();
  // A messaging credential is set up on the swarm's Connections page.
  await expect(
    others.getByRole("link", { name: "Set up in Connections Slack messaging" })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/connections?provider=slack");

  await main(page).getByRole("link", { name: "Plugins" }).click();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
});

test("connecting a credential confirms first, then opens the provider", async ({
  page,
}) => {
  await page.route("https://linear.app/**", (route) =>
    route.fulfill({ status: 200, body: "<html><body>Linear consent</body></html>" })
  );
  const requests = await open(
    page,
    (request) =>
      request.path === `${api}/linear/connections/linear-native/connect`
        ? ok({ redirect_url: "https://linear.app/oauth/authorize?client=1" })
        : undefined,
    `${base}/linear`
  );

  await page.getByRole("button", { name: "Connect Linear MCP OAuth" }).click();
  const dialog = page.getByRole("dialog", { name: "Linear MCP OAuth" });
  await expect(dialog.getByText("Native MCP OAuth")).toBeVisible();
  await expect(dialog.getByText("Dependent MCP servers: linear")).toBeVisible();
  await expect(
    dialog.getByText(
      "Nothing is connected until you continue to the provider and approve access."
    )
  ).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  expect(writes(requests)).toEqual([]);

  await page.getByRole("button", { name: "Connect Linear MCP OAuth" }).click();
  await dialog.getByRole("button", { name: "Continue" }).click();
  await expect(page).toHaveURL("https://linear.app/oauth/authorize?client=1");
  expect(writes(requests).map(({ path, csrf: token }) => [path, token])).toEqual([
    [`${api}/linear/connections/linear-native/connect`, csrf],
  ]);
});

test("reconnect keeps the credential; disconnect and a refusal say so in place", async ({
  page,
}) => {
  const requests = await open(
    page,
    (request) => {
      if (request.path === `${api}/linear/connections/linear-managed/connect`)
        return ok({ notice: "Connected" });
      if (request.path === `${api}/linear/connections/linear-managed/disconnect`)
        return ok({ notice: "Connection disconnected." });
      if (request.path === `${api}/linear/connections/linear-composio/connect`)
        return failure(
          422,
          "provider_not_configured",
          "That platform isn't configured for your organization yet."
        );
      return undefined;
    },
    `${base}/linear`
  );

  await page.getByRole("button", { name: "Reconnect Linear OAuth" }).click();
  const managed = page.getByRole("dialog", { name: "Linear OAuth" });
  await expect(
    managed.getByText(
      "The current credential stays active until the new authorization succeeds."
    )
  ).toBeVisible();
  await managed.getByRole("button", { name: "Continue" }).click();
  await expect(managed).toHaveCount(0);
  await expect(page.getByText("Connected", { exact: true }).first()).toBeVisible();

  await page.getByRole("button", { name: "Disconnect Linear OAuth" }).click();
  await expect(
    managed.getByText(/Disconnecting removes this credential from the plugin/)
  ).toBeVisible();
  await managed.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Connection disconnected.")).toBeVisible();

  await page.getByRole("button", { name: "Connect Linear via Composio" }).click();
  const composio = page.getByRole("dialog", { name: "Linear via Composio" });
  await expect(composio.getByText(/never used as an MCP credential/)).toBeVisible();
  await composio.getByRole("button", { name: "Continue" }).click();
  await expect(
    composio.getByText("That platform isn't configured for your organization yet.")
  ).toBeVisible();

  expect(writes(requests).map(({ path }) => path)).toEqual([
    `${api}/linear/connections/linear-managed/connect`,
    `${api}/linear/connections/linear-managed/disconnect`,
    `${api}/linear/connections/linear-composio/connect`,
  ]);
});

test("another plugin's page never shows the previous plugin's data", async ({
  page,
}) => {
  await open(page, undefined, `${base}/linear`);
  await expect(page.getByRole("heading", { level: 1, name: "Linear" })).toBeVisible();

  const release = await hold(
    page,
    `${api}/tenant.knowledge`,
    failure(503, "runtime_unavailable", "Salix is unavailable. Retry shortly.")
  );
  await moveTo(page, `${base}/tenant.knowledge`);
  // While Knowledge Pack loads, nothing of Linear stays under its address.
  await expect(
    page.getByRole("heading", { level: 1, name: "tenant.knowledge" })
  ).toBeVisible();
  await expect(main(page).getByText("Linear MCP OAuth")).toHaveCount(0);

  release();
  await expect(
    main(page).getByText("Salix is unavailable. Retry shortly.")
  ).toBeVisible();
  await expect(page.getByRole("heading", { level: 1, name: "Linear" })).toHaveCount(0);
  await expect(main(page).getByText("Linear MCP OAuth")).toHaveCount(0);
  await expect(
    main(page).getByText("Could not refresh.", { exact: false })
  ).toHaveCount(0);
});

test("a connected Composio account points to the Composio connection list", async ({
  page,
}) => {
  const connected = linear();
  connected.plugin.setup.connections[0] = credential(
    "linear-composio",
    "composio",
    "Linear via Composio",
    { state: "connected", action: "reconnect", disconnectable: false }
  );
  await open(
    page,
    (request) =>
      request.method === "GET" && request.path === `${api}/linear`
        ? ok(connected)
        : undefined,
    `${base}/linear`
  );

  const others = main(page).getByRole("region", { name: "Credentials" });
  await expect(others.getByText("Linear via Composio")).toBeVisible();
  await expect(
    others.getByRole("button", { name: "Disconnect Linear via Composio" })
  ).toHaveCount(0);
  await expect(
    others.getByRole("link", {
      name: "Disconnect this account from the Composio connection list on Connections.",
    })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/connections#composio");
});

test("a failed OAuth return is said once and leaves the address", async ({ page }) => {
  await open(page, undefined, `${base}/linear?oauth_error=access_denied`);
  await expect(
    page.getByText("We couldn't connect that account. Please try again.")
  ).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`${base}/linear$`));
});

test("Android shows its admission, and a missing plugin says so", async ({ page }) => {
  await open(
    page,
    (request) => {
      if (request.path === `${api}/android-control`)
        return ok({
          project,
          plugin: {
            ...plugin("android-control", "Android Control", "system"),
            toggleable: false,
            setup: null,
          },
          android: { status: "ok", entitled: false },
        });
      if (request.path === `${api}/gone`)
        return ok({ project, plugin: null, android: null });
      return undefined;
    },
    `${base}/android-control`
  );

  await expect(
    main(page).getByText("Not available for this organization")
  ).toBeVisible();
  await expect(
    main(page).getByText(/Contact your platform administrator/)
  ).toBeVisible();
  await expect(
    page.getByRole("switch", { name: "Enable Android Control" })
  ).toBeDisabled();

  await page.goto(`${base}/gone`);
  await expect(
    page.getByRole("heading", { level: 1, name: "Plugin not found" })
  ).toBeVisible();
  await expect(main(page).getByRole("link", { name: "Back to plugins" })).toBeVisible();
});

test("a swarm member reads plugins without write controls", async ({ page }) => {
  const member = { ...project, role: "user" };
  await open(page, (request) => {
    if (request.method !== "GET") return undefined;
    if (request.path === api)
      return ok(
        list({
          project: member,
          plugins: plugins().map((item) => ({
            ...item,
            toggleable: false,
            editable: false,
          })),
        })
      );
    if (request.path === `${api}/linear`) return ok(linear({ project: member }));
    return undefined;
  });

  await expect(rows(page)).toHaveCount(5);
  await expect(page.getByRole("button", { name: "New project plugin" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Edit / })).toHaveCount(0);
  for (const item of await main(page).getByRole("switch").all())
    await expect(item).toBeDisabled();

  await page.goto(`${base}/linear`);
  await expect(main(page).getByText("Linear MCP OAuth")).toBeVisible();
  await expect(
    main(page).getByRole("button", { name: /^(Connect|Reconnect|Disconnect) / })
  ).toHaveCount(0);
  await expect(
    main(page).getByRole("link", { name: /Set up in Integrations/ })
  ).toHaveCount(0);
});

test("a preparing swarm says so with a retry", async ({ page }) => {
  let ready = false;
  await open(page, (request) => {
    if (request.method === "GET" && request.path === api && !ready)
      return failure(
        409,
        "group_not_ready",
        "Agent Swarm is still preparing. Retry shortly."
      );
    return undefined;
  });
  await expect(
    main(page).getByText("Agent Swarm is still preparing. Retry shortly.")
  ).toBeVisible();
  ready = true;
  await main(page).getByRole("button", { name: "Retry" }).click();
  await expect(rows(page)).toHaveCount(5);
});

test("the pages fit a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page);
  await expect(rows(page)).toHaveCount(5);
  const overflow = () =>
    page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
  expect(await overflow()).toBe(0);
  await page.goto(`${base}/linear`);
  await expect(main(page).getByText("Linear MCP OAuth")).toBeVisible();
  expect(await overflow()).toBe(0);
});

test("X credentials use a blank password field and a scoped token write", async ({
  page,
}) => {
  const tokenConnection = credential("x-token", "mcp_api_key", "X read-only API", {
    credential_setup: {
      key: "X_BEARER_TOKEN",
      label: "App-only Bearer Token",
      help_url: "https://docs.x.com/tools/mcp",
    },
  });
  const requests = await open(
    page,
    (request) => {
      if (request.method === "GET" && request.path === `${api}/x-twitter`)
        return ok({
          project,
          android: null,
          plugin: {
            ...plugin("x-twitter", "X", "system"),
            setup: { mcps: [], connections: [tokenConnection] },
          },
        });
      if (
        request.method === "POST" &&
        request.path === `${api}/x-twitter/connections/x-token/connect`
      )
        return ok({ notice: "Connected" });
      return undefined;
    },
    `${base}/x-twitter`
  );
  await page.getByRole("button", { name: "Connect X read-only API" }).click();
  const dialog = page.getByRole("dialog");
  const input = dialog.getByLabel("App-only Bearer Token");
  await expect(input).toHaveAttribute("type", "password");
  await expect(input).toHaveValue("");
  await expect(dialog.getByRole("button", { name: "Save token" })).toBeDisabled();
  await input.fill("test-only-token");
  await dialog.getByRole("button", { name: "Save token" }).click();
  await expect(dialog).not.toBeVisible();
  expect(writes(requests)).toMatchObject([
    {
      method: "POST",
      path: `${api}/x-twitter/connections/x-token/connect`,
      body: { config_values: { X_BEARER_TOKEN: "test-only-token" } },
    },
  ]);
  await page.getByRole("button", { name: "Connect X read-only API" }).click();
  await expect(
    page.getByRole("dialog").getByLabel("App-only Bearer Token")
  ).toHaveValue("");
});
