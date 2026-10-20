import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/connections";
const api = "/orgs/acme/projects/p-1/connections";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const feishuConnect = (extra: Record<string, unknown> = {}) => ({
  connect_id: "imc1_feishu",
  status: "connected",
  disabled: false,
  app_id: "cli_a1",
  webhook_url: "https://salix.example/v1/im/feishu/events?app_id=cli_a1",
  app_secret_configured: true,
  verification_token_configured: true,
  encrypt_key_configured: false,
  updated_at: null,
  ...extra,
});

const slackConnect = (extra: Record<string, unknown> = {}) => ({
  connect_id: "imc1_slack",
  installed: false,
  disabled: false,
  workspace: "Acme",
  inbound_agent: "Router · router",
  install_url: "https://slack.com/oauth/v2/authorize?client_id=1",
  client_secret_configured: true,
  signing_secret_configured: true,
  updated_at: null,
  ...extra,
});

const sonnet = {
  key: "catalog:claude-sonnet-4-6",
  choice: { kind: "catalog", model: "claude-sonnet-4-6" },
};

const manifest = (name: string) => ({
  json: JSON.stringify({ display_information: { name } }, null, 2),
  create_url: "https://api.slack.com/apps?new_app=1",
  redirect_url: "https://salix.example/v1/im/slack/oauth/callback",
  events_url: "https://salix.example/v1/im/slack/events",
  interactions_url: null,
});

const tailnetSection = (extra: Record<string, unknown> = {}) => ({
  status: "ok",
  enabled: false,
  state: "disabled",
  approved: false,
  login_url: null,
  tailnet: null,
  node_name: null,
  login_name: null,
  node_tags: [],
  addresses: [],
  key_expiry: null,
  error: null,
  settings: { tags: ["tag:comma-agent"], accept_routes: false, expected_tailnet: null },
  ...extra,
});

const connections = (extra: Record<string, unknown> = {}) => ({
  project,
  org_admin: true,
  messaging: {
    status: "ok",
    feishu: {
      apps: [{ app_id: "cli_a1", name: "Acme Feishu" }],
      connects: [feishuConnect()],
      route: { status: "ready", connect_id: "imc1_feishu", router: "Router" },
    },
    slack: {
      app_name: "Support Desk",
      manifest: manifest("Support Desk"),
      inbound_agents: [{ id: "agt_router", label: "Router · router" }],
      default_inbound_agent_id: "agt_router",
      task_models: [
        { key: "", choice: null, label: "Default Task model" },
        { key: sonnet.key, choice: sonnet.choice, label: "Claude Sonnet" },
      ],
      connects: [slackConnect()],
    },
  },
  signal: {
    status: "ok",
    number: "+15550100",
    bindings: [
      {
        binding_id: "sb-1",
        display_name: "Support rota",
        kind: "group",
        number: "+1555",
      },
    ],
    bindings_truncated: false,
  },
  accounts: {
    status: "ok",
    connections: [
      {
        binding_id: "ob-1",
        provider: "notion",
        alias: "Docs",
        account: "Acme Workspace",
        scopes: ["read"],
        status: "active",
        enabled: true,
      },
    ],
    providers: [
      { provider: "github", ready: true },
      { provider: "google", ready: false },
    ],
  },
  composio: {
    status: "ok",
    configured: true,
    toolkits: [
      { toolkit: "gmail", account_id: null },
      { toolkit: "notion", account_id: "ca_notion" },
    ],
  },
  tailnet: tailnetSection(),
  ...extra,
});

const checks = (gates: Record<string, unknown>[]) => ({
  checks: { ran_at: null, gates },
  recorded: true,
  warning: null,
});

const gate = (
  gate_id: string,
  label: string,
  status: string,
  reason_class: string | null,
  next_action: string,
  evidence: Record<string, unknown> = {}
) => ({ gate_id, label, status, reason_class, next_action, required: true, evidence });

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

async function open(page: Page, handle: Handler = () => undefined, path = base) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    const answer = handle(request);
    if (answer) return answer;
    if (request.method === "GET" && request.path === api) return ok(connections());
    return undefined;
  });
  await page.goto(path);
  await expect(
    main(page).getByRole("heading", { level: 1, name: "Connections" })
  ).toBeVisible();
  return requests;
}

const main = (page: Page) => page.getByRole("main");
const section = (page: Page, name: string) =>
  main(page).getByRole("region", { name, exact: true });
const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("shows the messaging channels and accounts; the sidebar keeps Connections current", async ({
  page,
}) => {
  await open(page);
  await expect(
    main(page).getByText(
      "Messaging channels and third-party accounts for Support Desk."
    )
  ).toBeVisible();
  await expect(
    page
      .getByRole("navigation", { name: "Organization navigation" })
      .getByRole("link", { name: "Connections", exact: true })
  ).toHaveAttribute("aria-current", "page");

  const feishu = section(page, "Feishu");
  await expect(feishu.getByText("Route ready")).toBeVisible();
  await expect(
    feishu.getByRole("list", { name: "Feishu connects" }).getByText("imc1_feishu")
  ).toBeVisible();
  await expect(
    feishu.getByText("https://salix.example/v1/im/feishu/events?app_id=cli_a1")
  ).toBeVisible();
  await expect(
    feishu.getByText("Secret set · Verification token set · Encrypt key missing")
  ).toBeVisible();
  await feishu.getByText("Message route details").click();
  await expect(feishu.getByText("Router", { exact: true }).last()).toBeVisible();

  const slack = section(page, "Slack");
  await expect(slack.getByText("Awaiting install")).toBeVisible();
  await expect(slack.getByRole("link", { name: "Open install URL" })).toHaveAttribute(
    "href",
    "https://slack.com/oauth/v2/authorize?client_id=1"
  );
  await expect(section(page, "Signal").getByText("Support rota")).toBeVisible();
  await expect(
    section(page, "Connected accounts").getByText("Notion · Docs")
  ).toBeVisible();
  // A platform without an org OAuth app points org admins to its settings.
  await expect(
    section(page, "Connect an account").getByRole("link", {
      name: "Configure Google in org settings",
    })
  ).toHaveAttribute("href", "/orgs/acme/settings/integrations#oauth");
  await expect(
    section(page, "Apps via Composio").getByText("Connected", { exact: true })
  ).toBeVisible();
});

test("connects an org Feishu app, then runs the checks Health records", async ({
  page,
}) => {
  let created = false;
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/feishu`) {
      created = true;
      return {
        status: 201,
        body: { ok: true, data: { notice: "Feishu webhook connect ready." } },
      };
    }
    if (request.method === "POST" && request.path === `${api}/feishu/checks`)
      return ok(
        checks([
          gate(
            "bot.callback",
            "Callback reachable + URL verification",
            "ok",
            "url_verification_passed",
            "Callback reachable and URL verification passed."
          ),
          gate(
            "bot.calendar",
            "Google Calendar meeting notifications",
            "needs_manual",
            "calendar_initial_sync_pending",
            "Initial calendar sync has not completed yet.",
            {
              next_retry_at: "2026-08-01T10:00:00Z",
              watched_calendars: ["Comma Event"],
            }
          ),
        ])
      );
    return undefined;
  });
  const feishu = section(page, "Feishu");
  await feishu.getByRole("textbox", { name: "Connect name" }).fill("Support bot");
  await feishu.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(page.getByText("Feishu webhook connect ready.")).toBeVisible();
  expect(created).toBe(true);

  await feishu.getByRole("button", { name: "Run checks" }).click();
  const results = feishu.getByRole("region", { name: "Checks" });
  await expect(
    results.getByText("Callback reachable + URL verification")
  ).toBeVisible();
  await expect(results.getByText("OK", { exact: true })).toBeVisible();
  // A calendar check that is still syncing is pending, not a manual step.
  await expect(results.getByText("Pending", { exact: true })).toBeVisible();
  await expect(
    results.getByText("Reason: calendar initial sync pending")
  ).toBeVisible();
  await results.getByText("Evidence").last().click();
  await expect(results.getByText("Comma Event")).toBeVisible();

  expect(writes(requests)).toEqual([
    {
      method: "POST",
      path: `${api}/feishu`,
      search: "",
      csrf,
      body: { app_id: "cli_a1", app_name: "Support bot" },
    },
    { method: "POST", path: `${api}/feishu/checks`, search: "", csrf, body: undefined },
  ]);
});

test("a refused Feishu connect says why in the form", async ({ page }) => {
  await open(page, (request) =>
    request.method === "POST" && request.path === `${api}/feishu`
      ? {
          status: 409,
          body: {
            ok: false,
            error: {
              code: "provider_app_in_use",
              message: "This Feishu app is already connected to another Agent Swarm.",
              details: {},
            },
          },
        }
      : undefined
  );
  const feishu = section(page, "Feishu");
  await feishu.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(
    feishu.getByText("This Feishu app is already connected to another Agent Swarm.")
  ).toBeVisible();
});

test("adds a Slack app from its manifest; the manifest follows the app name", async ({
  page,
}) => {
  await page.route("https://api.slack.com/**", (route) =>
    route.fulfill({ status: 200, body: "<html><body>Slack</body></html>" })
  );
  const requests = await open(page, (request) => {
    if (request.path === `${api}/slack/manifest`)
      return ok({
        manifest: manifest(new URLSearchParams(request.search).get("app_name") ?? ""),
      });
    if (request.method === "POST" && request.path === `${api}/slack`)
      return {
        status: 201,
        body: {
          ok: true,
          data: {
            notice:
              "Slack connect created. Open the install URL to finish the OAuth install.",
          },
        },
      };
    return undefined;
  });
  await section(page, "Slack").getByRole("button", { name: "Add Slack app" }).click();
  const dialog = page.getByRole("dialog", { name: "Add Slack app" });
  await expect(
    dialog.getByRole("link", { name: "Create app on Slack" })
  ).toHaveAttribute("href", "https://api.slack.com/apps?new_app=1");
  await dialog.getByText("Manifest and callback URLs").click();
  const manifestBlock = dialog.getByLabel("App manifest", { exact: true });
  await expect(manifestBlock).toContainText('"name": "Support Desk"');

  await dialog.getByRole("textbox", { name: "App name" }).fill("Acme Bot");
  await expect(manifestBlock).toContainText('"name": "Acme Bot"');
  await dialog.getByRole("textbox", { name: "App ID" }).fill("A123");
  await dialog.getByRole("textbox", { name: "Client ID" }).fill("cid");
  await dialog.getByLabel("Client secret").fill("client-secret");
  await dialog.getByLabel("Signing secret").fill("signing-secret");
  // Slack messages go to the Router unless another choice is made.
  await expect(
    dialog.getByRole("button", { name: /Deliver Slack messages to/ })
  ).toContainText("Router · router");
  await dialog.getByRole("button", { name: "Connect" }).click();

  await expect(dialog).toHaveCount(0);
  await expect(
    page.getByText(
      "Slack connect created. Open the install URL to finish the OAuth install."
    )
  ).toBeVisible();
  expect(writes(requests)).toEqual([
    {
      method: "POST",
      path: `${api}/slack`,
      search: "",
      csrf,
      body: {
        app_name: "Acme Bot",
        app_id: "A123",
        client_id: "cid",
        client_secret: "client-secret",
        signing_secret: "signing-secret",
        inbound_agent_id: "agt_router",
      },
    },
  ]);
  // The manifest was read again for the typed name only.
  expect(
    requests.filter((request) => request.path === `${api}/slack/manifest`).at(-1)
      ?.search
  ).toBe("?app_name=Acme+Bot");
});

test("adds a QQ bot by its credentials, then shows the callback address to save", async ({
  page,
}) => {
  let connected = false;
  const qq = () => ({
    connects: connected
      ? [
          {
            connect_id: "imc1_qq",
            status: "connected",
            disabled: false,
            app_id: "1900012345",
            bot_name: "Acme helper",
            webhook_url: "https://salix.example/v1/im/qq/events?app_id=1900012345",
            app_secret_configured: true,
            updated_at: null,
          },
        ]
      : [],
    route: {
      status: connected ? "ready" : "not_connected",
      connect_id: connected ? "imc1_qq" : null,
      router: connected ? "Router" : null,
    },
  });
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/qq`) {
      connected = true;
      return {
        status: 201,
        body: {
          ok: true,
          data: {
            notice:
              "QQ bot connected. Save the callback address in the QQ bot console.",
          },
        },
      };
    }
    if (request.method === "GET" && request.path === api)
      return ok(connections({ messaging: { ...connections().messaging, qq: qq() } }));
    return undefined;
  });
  const qqSection = section(page, "QQ");
  await expect(qqSection.getByText("No QQ bots connected yet.")).toBeVisible();

  await qqSection.getByRole("button", { name: "Add QQ bot" }).click();
  const dialog = page.getByRole("dialog", { name: "Add QQ bot" });
  await dialog.getByRole("textbox", { name: "AppID" }).fill(" 1900012345 ");
  await dialog.getByLabel("AppSecret").fill("bot-secret");
  await dialog.getByRole("button", { name: "Connect", exact: true }).click();

  await expect(
    page.getByText("QQ bot connected. Save the callback address in the QQ bot console.")
  ).toBeVisible();
  const bots = qqSection.getByRole("list", { name: "QQ bots" });
  await expect(bots.getByText("Acme helper")).toBeVisible();
  await expect(
    bots.getByText("https://salix.example/v1/im/qq/events?app_id=1900012345")
  ).toBeVisible();
  await expect(bots.getByText("AppSecret set")).toBeVisible();

  expect(
    writes(requests).map((request) => [request.method, request.path, request.body])
  ).toEqual([
    ["POST", `${api}/qq`, { app_id: "1900012345", app_secret: "bot-secret" }],
  ]);
});

test("a Lark app runs its own checks, and the section gives the scope JSON to import", async ({
  page,
}) => {
  const scopeJson = JSON.stringify({ scopes: { tenant: ["im:message"] } }, null, 2);
  const lark = {
    connects: [
      {
        connect_id: "imc1_lark",
        status: "connected",
        disabled: false,
        app_id: "cli_lark1",
        app_name: "Acme Lark bot",
        webhook_url: "https://salix.example/v1/im/lark/events?app_id=cli_lark1",
        app_secret_configured: true,
        verification_token_configured: true,
        encrypt_key_configured: false,
        updated_at: null,
      },
    ],
    route: { status: "ready", connect_id: "imc1_lark", router: "Router" },
    scope_json: scopeJson,
  };
  const requests = await open(page, (request) => {
    if (request.path === `${api}/lark/imc1_lark/checks`)
      return ok(
        checks([
          gate(
            "bot.callback",
            "Callback reachable + URL verification",
            "fail",
            "token_mismatch",
            "Verification Token mismatch: connect the app again with the token of its Events & Callbacks page."
          ),
          gate(
            "bot.manual",
            "Lark Developer Console steps completed",
            "needs_manual",
            "lark_console_steps_required",
            "In the Lark Developer Console, import the scope JSON and publish a version of the app."
          ),
        ])
      );
    if (request.method === "GET" && request.path === api)
      return ok(connections({ messaging: { ...connections().messaging, lark } }));
    return undefined;
  });
  const larkSection = section(page, "Lark");

  // The scopes are one JSON for the batch import of the Lark Developer Console.
  await expect(
    larkSection.getByText("Permissions & Scopes → batch import", { exact: false })
  ).toBeVisible();
  await page.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: (text: string) => {
          (window as unknown as { copied: string }).copied = text;
          return Promise.resolve();
        },
      },
    });
  });
  await larkSection.getByRole("button", { name: "Copy JSON: Lark bot" }).click();
  expect(
    await page.evaluate(() => (window as unknown as { copied: string }).copied)
  ).toBe(scopeJson);

  await larkSection
    .getByRole("button", { name: "Run checks for Acme Lark bot" })
    .click();
  const results = larkSection.getByRole("region", { name: "Checks for Acme Lark bot" });
  await expect(
    results.getByText("Callback reachable + URL verification")
  ).toBeVisible();
  await expect(results.getByText("Reason: token mismatch")).toBeVisible();
  await expect(
    results.getByText("Lark Developer Console steps completed")
  ).toBeVisible();

  expect(
    writes(requests).map((request) => [request.method, request.path, request.body])
  ).toEqual([["POST", `${api}/lark/imc1_lark/checks`, undefined]]);
});

test("adds a Lark app by its credentials, then shows the request URL to save", async ({
  page,
}) => {
  let connected = false;
  const requestUrl = "https://salix.example/v1/im/lark/events?app_id=cli_lark1";
  const lark = () => ({
    connects: connected
      ? [
          {
            connect_id: "imc1_lark",
            status: "connected",
            disabled: false,
            app_id: "cli_lark1",
            app_name: "Acme Lark bot",
            webhook_url: requestUrl,
            app_secret_configured: true,
            verification_token_configured: false,
            encrypt_key_configured: true,
            updated_at: null,
          },
        ]
      : [],
    route: {
      status: connected ? "ready" : "not_connected",
      connect_id: connected ? "imc1_lark" : null,
      router: connected ? "Router" : null,
    },
  });
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/lark`) {
      connected = true;
      return {
        status: 201,
        body: { ok: true, data: { notice: "Lark app connected." } },
      };
    }
    if (request.method === "GET" && request.path === api)
      return ok(
        connections({ messaging: { ...connections().messaging, lark: lark() } })
      );
    return undefined;
  });
  const larkSection = section(page, "Lark");
  await expect(larkSection.getByText("No Lark apps connected yet.")).toBeVisible();

  await larkSection.getByRole("button", { name: "Add Lark app" }).click();
  const dialog = page.getByRole("dialog", { name: "Add Lark app" });
  const connect = dialog.getByRole("button", { name: "Connect", exact: true });
  await dialog.getByRole("textbox", { name: "App ID" }).fill(" cli_lark1 ");
  await dialog.getByLabel("App Secret").fill("app-secret");

  // Lark signs events with the token or the key: without either, nothing is sent.
  await connect.click();
  await expect(
    dialog.getByText("Enter the Verification Token or the Encrypt Key.")
  ).toBeVisible();
  expect(writes(requests)).toEqual([]);

  await dialog.getByLabel("Encrypt Key").fill(" encrypt-key ");
  await connect.click();

  await expect(page.getByText("Lark app connected.")).toBeVisible();
  const apps = larkSection.getByRole("list", { name: "Lark apps" });
  await expect(apps.getByText("Acme Lark bot")).toBeVisible();
  await expect(apps.getByText(requestUrl)).toBeVisible();

  expect(
    writes(requests).map((request) => [request.method, request.path, request.body])
  ).toEqual([
    [
      "POST",
      `${api}/lark`,
      {
        app_id: "cli_lark1",
        app_secret: "app-secret",
        verification_token: "",
        encrypt_key: "encrypt-key",
      },
    ],
  ]);
});

test("edits the shortcuts of a QQ bot's command menu", async ({ page }) => {
  let menu = [
    {
      name: "总结群聊",
      description: "总结最近的群聊内容",
      prompt: "总结这个群最近的聊天内容",
      scope: "group",
      admin_only: false,
    },
  ];
  const qq = () => ({
    connects: [
      {
        connect_id: "imc1_qq",
        status: "connected",
        disabled: false,
        app_id: "1900012345",
        bot_name: "Acme helper",
        webhook_url: "https://salix.example/v1/im/qq/events?app_id=1900012345",
        app_secret_configured: true,
        command_menu: menu,
        command_menu_sync: { private: "synced", group: "owner_panel" },
        updated_at: null,
      },
    ],
    route: { status: "ready", connect_id: "imc1_qq", router: "Router" },
  });
  const requests = await open(page, (request) => {
    if (request.method === "PUT" && request.path === `${api}/qq/imc1_qq/menu`) {
      menu = (request.body as { items: typeof menu }).items;
      return ok({ notice: "Menu saved and sent to QQ." });
    }
    if (request.method === "GET" && request.path === api)
      return ok(connections({ messaging: { ...connections().messaging, qq: qq() } }));
    return undefined;
  });
  const bots = section(page, "QQ").getByRole("list", { name: "QQ bots" });
  await expect(bots.getByText("/status /compact /help /总结群聊")).toBeVisible();
  // The bot's owner made a panel in the QQ bot console; QQ shows that one.
  await expect(
    bots.getByText(/QQ shows a command panel made in the QQ bot console/)
  ).toBeVisible();

  await bots.getByRole("button", { name: "Edit menu" }).click();
  const dialog = page.getByRole("dialog", { name: "Command menu" });
  await dialog
    .getByRole("group", { name: "Shortcut 1" })
    .getByRole("button", { name: "Remove" })
    .click();
  await dialog.getByRole("button", { name: "Add shortcut" }).click();
  const added = dialog.getByRole("group", { name: "Shortcut 1" });
  await added.getByRole("textbox", { name: "Name" }).fill(" 周报 ");
  await added.getByRole("textbox", { name: "Description" }).fill("生成本周周报");
  await added.getByRole("textbox", { name: "Prompt" }).fill("根据本周群聊生成周报");
  await added.getByText("Only group admins can pick it").click();
  await dialog.getByRole("button", { name: "Save", exact: true }).click();

  await expect(page.getByText("Menu saved and sent to QQ.")).toBeVisible();
  await expect(bots.getByText("/status /compact /help /周报")).toBeVisible();
  expect(
    writes(requests).map((request) => [request.method, request.path, request.body])
  ).toEqual([
    [
      "PUT",
      `${api}/qq/imc1_qq/menu`,
      {
        items: [
          {
            name: "周报",
            description: "生成本周周报",
            prompt: "根据本周群聊生成周报",
            scope: "all",
            admin_only: true,
          },
        ],
      },
    ],
  ]);
});

/** Where a Slack create request delivers. */
const inboundOf = (body: unknown) => {
  const { inbound_agent_id, inbound_tasks } = body as Record<string, unknown>;
  return { inbound_agent_id, inbound_tasks };
};

test("a Slack app can make each new thread a Task that runs a chosen model", async ({
  page,
}) => {
  let refuse = true;
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/slack`) {
      if (refuse) {
        refuse = false;
        const message = "Choose a model this organization allows.";
        return {
          status: 422,
          body: {
            ok: false,
            error: {
              code: "model_not_allowed",
              message,
              details: { fields: { inbound_tasks: [message] } },
            },
          },
        };
      }
      return {
        status: 201,
        body: { ok: true, data: { notice: "Slack connect created." } },
      };
    }
    return undefined;
  });

  await section(page, "Slack").getByRole("button", { name: "Add Slack app" }).click();
  const dialog = page.getByRole("dialog", { name: "Add Slack app" });
  await dialog.getByRole("textbox", { name: "App ID" }).fill("A123");
  await dialog.getByRole("textbox", { name: "Client ID" }).fill("cid");
  await dialog.getByLabel("Client secret").fill("client-secret");
  await dialog.getByLabel("Signing secret").fill("signing-secret");
  await dialog.getByRole("button", { name: /Deliver Slack messages to/ }).click();
  await page.getByRole("option", { name: /Tasks/ }).click();
  const model = dialog.getByRole("button", { name: /Task model/ });
  // A new Task runs the swarm's default Task model unless a model is chosen.
  await expect(model).toContainText("Default Task model");
  await model.click();
  await page.getByRole("option", { name: "Claude Sonnet" }).click();

  await dialog.getByRole("button", { name: "Connect" }).click();
  await expect(dialog.getByRole("alert")).toHaveText(
    "Choose a model this organization allows."
  );
  await dialog.getByRole("button", { name: /Task model/ }).click();
  await page.getByRole("option", { name: "Default Task model" }).click();
  await dialog.getByRole("button", { name: "Connect" }).click();
  await expect(dialog).toHaveCount(0);

  expect(writes(requests).map((request) => inboundOf(request.body))).toEqual([
    { inbound_agent_id: undefined, inbound_tasks: { model: sonnet.choice } },
    { inbound_agent_id: undefined, inbound_tasks: { model: null } },
  ]);
});

test("Run checks results are cleared once the page is read again", async ({ page }) => {
  let disabled = false;
  await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/feishu/checks`)
      return ok(
        checks([
          gate(
            "bot.callback",
            "Callback reachable + URL verification",
            "ok",
            "url_verification_passed",
            "Callback reachable and URL verification passed."
          ),
        ])
      );
    if (request.path === `${api}/slack/imc1_slack/checks`)
      return ok(
        checks([
          gate(
            "slack.calendar",
            "Google Calendar meeting auto-join",
            "skipped",
            "calendar_policy_not_configured",
            "Meeting auto-join is optional."
          ),
        ])
      );
    if (
      request.method === "PUT" &&
      request.path === `${api}/im/imc1_slack/enablement`
    ) {
      disabled = true;
      return ok({ notice: "Connect disabled." });
    }
    if (request.method === "GET" && request.path === api && disabled)
      return ok(
        connections({
          messaging: {
            ...connections().messaging,
            slack: {
              ...connections().messaging.slack,
              connects: [slackConnect({ disabled: true })],
            },
          },
        })
      );
    return undefined;
  });
  const feishu = section(page, "Feishu");
  const slack = section(page, "Slack");
  await feishu.getByRole("button", { name: "Run checks" }).click();
  await expect(feishu.getByRole("region", { name: "Checks" })).toBeVisible();
  await slack.getByRole("button", { name: "Run checks for imc1_slack" }).click();
  const slackResults = slack.getByRole("region", { name: "Checks for imc1_slack" });
  await expect(slackResults).toBeVisible();

  await slack.getByRole("button", { name: "Actions for imc1_slack" }).click();
  await page.getByRole("menuitem", { name: "Disable" }).click();
  await expect(slack.getByText("Disabled", { exact: true })).toBeVisible();
  await expect(slackResults).toHaveCount(0);
  await expect(feishu.getByRole("region", { name: "Checks" })).toHaveCount(0);
});

test("a Slack connect runs its calendar checks, and is disabled and deleted from its menu", async ({
  page,
}) => {
  let disabled = false;
  const requests = await open(page, (request) => {
    if (request.path === `${api}/slack/imc1_slack/checks`)
      return ok(
        checks([
          gate(
            "slack.calendar",
            "Google Calendar meeting auto-join",
            "skipped",
            "calendar_policy_not_configured",
            "Meeting auto-join is optional."
          ),
        ])
      );
    if (
      request.method === "PUT" &&
      request.path === `${api}/im/imc1_slack/enablement`
    ) {
      disabled = true;
      return ok({ notice: "Connect disabled." });
    }
    if (request.method === "DELETE" && request.path === `${api}/im/imc1_slack`)
      return ok({ notice: "Connect deleted." });
    if (request.method === "GET" && request.path === api && disabled)
      return ok(
        connections({
          messaging: {
            ...connections().messaging,
            slack: {
              ...connections().messaging.slack,
              connects: [slackConnect({ disabled: true })],
            },
          },
        })
      );
    return undefined;
  });
  const slack = section(page, "Slack");
  await slack.getByRole("button", { name: "Run checks for imc1_slack" }).click();
  const results = slack.getByRole("region", { name: "Checks for imc1_slack" });
  await expect(results.getByText("Skipped")).toBeVisible();
  await expect(results.getByText("Meeting auto-join is optional.")).toBeVisible();

  await slack.getByRole("button", { name: "Actions for imc1_slack" }).click();
  await page.getByRole("menuitem", { name: "Disable" }).click();
  await expect(page.getByText("Connect disabled.")).toBeVisible();
  await expect(slack.getByText("Disabled", { exact: true })).toBeVisible();

  await slack.getByRole("button", { name: "Actions for imc1_slack" }).click();
  await page.getByRole("menuitem", { name: "Enable" }).click();
  // Enable answered with the same mock; open the delete instead.
  await slack.getByRole("button", { name: "Actions for imc1_slack" }).click();
  await page.getByRole("menuitem", { name: "Delete" }).click();
  const confirm = page.getByRole("dialog", { name: "Delete connect" });
  await confirm.getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Connect deleted.")).toBeVisible();

  expect(
    writes(requests).map((request) => [request.method, request.path, request.body])
  ).toEqual([
    ["POST", `${api}/slack/imc1_slack/checks`, undefined],
    ["PUT", `${api}/im/imc1_slack/enablement`, { enabled: false }],
    ["PUT", `${api}/im/imc1_slack/enablement`, { enabled: true }],
    ["DELETE", `${api}/im/imc1_slack`, undefined],
  ]);
});

test("Signal shows a one-time code once and disconnects a chat after confirming", async ({
  page,
}) => {
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/signal/claims`)
      return {
        status: 201,
        body: {
          ok: true,
          data: { claim: { number: "+15550100", command: "comma connect K7QD-M2XP" } },
        },
      };
    if (request.method === "DELETE" && request.path === `${api}/signal/bindings/sb-1`)
      return ok({ notice: "Signal chat disconnected." });
    return undefined;
  });
  const signal = section(page, "Signal");
  await signal.getByRole("button", { name: "New code" }).click();
  await expect(signal.getByLabel("Signal message", { exact: true })).toHaveText(
    "comma connect K7QD-M2XP"
  );
  await signal.getByRole("button", { name: "Done" }).click();
  await expect(signal.getByText("comma connect K7QD-M2XP")).toHaveCount(0);

  await signal.getByRole("button", { name: "Disconnect Support rota" }).click();
  await page
    .getByRole("dialog", { name: "Disconnect Signal chat" })
    .getByRole("button", { name: "Disconnect" })
    .click();
  await expect(page.getByText("Signal chat disconnected.")).toBeVisible();
  expect(writes(requests).map((request) => request.path)).toEqual([
    `${api}/signal/claims`,
    `${api}/signal/bindings/sb-1`,
  ]);
});

test("connects an OAuth account and a Composio toolkit after confirming, then opens the provider", async ({
  page,
}) => {
  await page.route("https://github.com/**", (route) =>
    route.fulfill({ status: 200, body: "<html><body>GitHub consent</body></html>" })
  );
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/accounts`)
      return ok({
        redirect_url: "https://github.com/login/oauth/authorize?client_id=1",
      });
    if (request.method === "POST" && request.path === `${api}/composio/gmail/connect`)
      return {
        status: 422,
        body: {
          ok: false,
          error: {
            code: "composio_not_configured",
            message: "Composio isn't configured for your organization yet.",
            details: {},
          },
        },
      };
    return undefined;
  });

  // Composio: the refusal stays in the confirmation.
  await section(page, "Apps via Composio")
    .getByRole("button", { name: "Connect Gmail through Composio" })
    .click();
  const composio = page.getByRole("dialog", { name: "Gmail" });
  await expect(composio.getByText("Composio direct API")).toBeVisible();
  await composio.getByRole("button", { name: "Continue" }).click();
  await expect(
    composio.getByText("Composio isn't configured for your organization yet.")
  ).toBeVisible();
  await composio.getByRole("button", { name: "Cancel" }).click();

  await section(page, "Connect an account")
    .getByRole("button", { name: "Connect GitHub", exact: true })
    .click();
  const dialog = page.getByRole("dialog", { name: "GitHub" });
  await expect(dialog.getByText("Managed OAuth")).toBeVisible();
  await dialog.getByRole("textbox", { name: "Label (optional)" }).fill("Work");
  await dialog.getByRole("button", { name: "Continue" }).click();
  await expect(page).toHaveURL(/github\.com\/login\/oauth\/authorize/);

  expect(writes(requests).map((request) => [request.path, request.body])).toEqual([
    [`${api}/composio/gmail/connect`, undefined],
    [`${api}/accounts`, { provider: "github", alias: "Work" }],
  ]);
});

test("an account and a Composio toolkit are disconnected after confirming", async ({
  page,
}) => {
  const requests = await open(page, (request) => {
    if (request.method === "PUT" && request.path === `${api}/accounts/ob-1/enablement`)
      return ok({ notice: "Account disabled." });
    if (request.method === "DELETE") return ok({ notice: "Account disconnected." });
    return undefined;
  });
  const accounts = section(page, "Connected accounts");
  await accounts.getByRole("button", { name: "Actions for Notion · Docs" }).click();
  await page.getByRole("menuitem", { name: "Disable" }).click();
  await expect(page.getByText("Account disabled.")).toBeVisible();

  await accounts.getByRole("button", { name: "Actions for Notion · Docs" }).click();
  await page.getByRole("menuitem", { name: "Disconnect" }).click();
  await page
    .getByRole("dialog", { name: "Disconnect account" })
    .getByRole("button", { name: "Disconnect" })
    .click();
  await expect(page.getByText("Account disconnected.")).toBeVisible();

  await section(page, "Apps via Composio")
    .getByRole("button", { name: "Disconnect Notion from Composio" })
    .click();
  await page
    .getByRole("dialog", { name: "Disconnect account" })
    .getByRole("button", { name: "Disconnect" })
    .click();

  await expect
    .poll(() => writes(requests).map((request) => [request.method, request.path]))
    .toEqual([
      ["PUT", `${api}/accounts/ob-1/enablement`],
      ["DELETE", `${api}/accounts/ob-1`],
      ["DELETE", `${api}/composio/ca_notion`],
    ]);
});

test("Tailscale gives the admin a login link and disconnects after confirming", async ({
  page,
}) => {
  const pending = tailnetSection({
    enabled: true,
    state: "needs_login",
    login_url: "https://login.tailscale.com/a/abc123",
    settings: {
      tags: ["tag:comma-agent", "tag:ops"],
      accept_routes: true,
      expected_tailnet: "acme.com",
    },
  });
  let connected = false;
  const requests = await open(page, (request) => {
    if (request.method === "GET" && request.path === api)
      return ok(connections({ tailnet: connected ? pending : tailnetSection() }));
    if (request.method === "PUT" && request.path === `${api}/tailnet`) {
      connected = true;
      return ok({ tailnet: pending, notice: null });
    }
    if (request.method === "DELETE" && request.path === `${api}/tailnet`) {
      connected = false;
      return ok({ tailnet: tailnetSection(), notice: "Tailscale disconnected." });
    }
    return undefined;
  });
  const tailscale = section(page, "Tailscale");
  await expect(tailscale.getByText("Not connected")).toBeVisible();
  await tailscale.getByRole("button", { name: "Connect" }).click();

  const dialog = page.getByRole("dialog", { name: "Tailscale settings" });
  await dialog.getByRole("textbox", { name: "Tags" }).fill("tag:comma-agent, tag:ops");
  await dialog
    .getByRole("textbox", { name: "Tailnet name (optional)" })
    .fill("acme.com");
  // The styled box covers the input; click its label like a user does.
  await dialog.getByText("Use approved subnet routes").click();
  await expect(
    dialog.getByRole("checkbox", { name: "Use approved subnet routes" })
  ).toBeChecked();
  await dialog.getByRole("button", { name: "Connect" }).click();

  await expect(tailscale.getByText("Waiting for approval")).toBeVisible();
  await expect(tailscale.getByLabel("Login link", { exact: true })).toHaveText(
    "https://login.tailscale.com/a/abc123"
  );
  expect(writes(requests)[0]?.body).toEqual({
    tags: ["tag:comma-agent", "tag:ops"],
    accept_routes: true,
    expected_tailnet: "acme.com",
  });

  await tailscale.getByRole("button", { name: "Disconnect" }).click();
  await page
    .getByRole("dialog", { name: "Disconnect Tailscale" })
    .getByRole("button", { name: "Disconnect" })
    .click();
  await expect(page.getByText("Tailscale disconnected.")).toBeVisible();
  expect(
    writes(requests).map((request) => `${request.method} ${request.path}`)
  ).toEqual([`PUT ${api}/tailnet`, `DELETE ${api}/tailnet`]);
});

test("a swarm member reads without write controls", async ({ page }) => {
  await open(page, (request) =>
    request.method === "GET" && request.path === api
      ? ok(connections({ project: { ...project, role: "user" }, org_admin: false }))
      : undefined
  );
  await expect(
    section(page, "Feishu")
      .getByRole("list", { name: "Feishu connects" })
      .getByText("imc1_feishu")
  ).toBeVisible();
  await expect(main(page).getByRole("button", { name: /^Actions for/ })).toHaveCount(0);
  await expect(
    main(page).getByRole("button", {
      name: /^(Connect|Run checks|New code|Add Slack app)/,
    })
  ).toHaveCount(0);
  await expect(main(page).getByRole("textbox", { name: "Connect name" })).toHaveCount(
    0
  );
  await expect(main(page).getByRole("link", { name: /org settings/ })).toHaveCount(0);
  await expect(
    main(page).getByText("Only Agent Swarm admins can connect accounts.")
  ).toBeVisible();
  await expect(main(page).getByText("Ask a swarm admin")).toBeVisible();
});

test("without an org Feishu bot app, an org admin is sent to set one up", async ({
  page,
}) => {
  await open(page, (request) =>
    request.method === "GET" && request.path === api
      ? ok(
          connections({
            messaging: {
              ...connections().messaging,
              feishu: {
                apps: [],
                connects: [],
                route: { status: "not_connected", connect_id: null, router: null },
              },
            },
          })
        )
      : undefined
  );
  const feishu = section(page, "Feishu");
  await expect(feishu.getByText("Not connected", { exact: true })).toBeVisible();
  await expect(feishu.getByText("No Feishu connects yet.")).toBeVisible();
  await feishu.getByRole("link", { name: "Set up a Feishu app" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/settings\/integrations#feishu$/);
});

test("each runtime section says it is unavailable, with a retry", async ({ page }) => {
  let reads = 0;
  await open(page, (request) => {
    if (request.method !== "GET" || request.path !== api) return undefined;
    reads += 1;
    return ok(
      connections({
        messaging: { status: "unavailable", feishu: null, slack: null },
        accounts: { status: "preparing", connections: [], providers: [] },
        signal: {
          status: "unavailable",
          number: null,
          bindings: [],
          bindings_truncated: false,
        },
      })
    );
  });
  await expect(
    main(page).getByText("The runtime is unavailable right now. Retry shortly.")
  ).toBeVisible();
  await expect(
    main(page).getByText("Agent Swarm is still preparing. Retry shortly.")
  ).toBeVisible();
  await expect(main(page).getByText("Signal is unavailable right now.")).toBeVisible();
  // Composio answers on its own.
  await expect(section(page, "Apps via Composio").getByText("Gmail")).toBeVisible();
  const before = reads;
  await main(page).getByRole("button", { name: "Retry" }).first().click();
  await expect.poll(() => reads).toBeGreaterThan(before);
});

test("the retired Integrations address keeps its provider link and opens that section", async ({
  page,
}) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page, undefined, "/orgs/acme/projects/p-1/integrations?provider=slack");
  await expect(page).toHaveURL(new RegExp(`${base}\\?provider=slack$`));
  await expect(
    main(page).getByRole("heading", { level: 3, name: "Slack" })
  ).toBeInViewport();
  // Nothing scrolls sideways at this width.
  const overflow = await page.evaluate(() =>
    [...document.querySelectorAll("main *")].some(
      (element) =>
        element.scrollWidth > element.clientWidth + 1 &&
        !["visible", "hidden", "clip"].includes(getComputedStyle(element).overflowX)
    )
  );
  expect(overflow).toBe(false);
});

test("a failed OAuth return is said once and leaves the address", async ({ page }) => {
  await open(page, undefined, `${base}?oauth_error=access_denied`);
  await expect(
    page.getByText("We couldn't connect that account. Please try again.")
  ).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
});
