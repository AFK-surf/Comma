import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// Nothing listens here: the page routes every request to the script below.
const apiBaseUrl = "http://api.imessage-e2e.test";
const workspaceId = "wsp_imessage_e2e";
const line = "+15559990000";
const code = "Abc123_xyZ";
// The page's clock starts here (Playwright's clock); attempts expire ten minutes
// on. The core runs in a Web Worker, which Playwright's clock does not reach: it
// keeps reading the attempt only while the machine's own time is before the
// expiry, so the page's time is set past any day the test runs on.
const start = Date.UTC(2099, 0, 1);
const session = {
  apiBaseUrl,
  email: "imessage-e2e@example.com",
  token: "comma_sess_imessage_e2e",
  userId: "usr_imessage_e2e",
};

const corsHeaders = (origin: string | undefined) => ({
  "access-control-allow-credentials": "true",
  "access-control-allow-headers":
    "authorization,content-type,x-comma-session-transport",
  "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
  "access-control-allow-origin": origin ?? "*",
  "content-type": "application/json",
  vary: "origin",
});

/** Where to keep the UI-state screenshots: the test output, and `IMESSAGE_SHOTS_DIR` when set. */
async function shoot(page: Page, name: string) {
  const card = page.locator('[data-setting-id="imessage.connection"]');
  await card.screenshot({ path: test.info().outputPath(`${name}.png`) });
  const dir = process.env.IMESSAGE_SHOTS_DIR;
  if (dir) await card.screenshot({ path: `${dir}/${name}.png` });
}

for (const { kind, input, account } of [
  { kind: "phone", input: "+1 (415) 555-0123", account: "+14155550123" },
  {
    kind: "email",
    input: " Person.Name@Example.com ",
    account: "person.name@example.com",
  },
]) {
  test(`connects iMessage over a Photon line: ${kind}, code, reply, disconnect`, async ({
    page,
  }) => {
    const server = {
      attempt: null as null | Record<string, unknown>,
      link: null as null | Record<string, unknown>,
      started: [] as unknown[],
      cancelled: 0,
      disconnected: 0,
    };
    const state = () => ({
      configured: true,
      relay_configured: false,
      photon_configured: true,
      shared_handle: null,
      shared_identity: "Comma",
      workspace_id: workspaceId,
      connection_active: Boolean(server.link),
      relay_online: false,
      photon_online: true,
      pending_claim: server.attempt,
      link: server.link,
    });

    const handle = async (route: Route) => {
      const request = route.request();
      const url = new URL(request.url());
      const headers = corsHeaders(request.headers().origin);
      const reply = (status: number, body: unknown) =>
        route.fulfill({ headers, status, body: JSON.stringify(body) });

      if (request.method() === "OPTIONS")
        return route.fulfill({ body: "", headers, status: 204 });
      if (url.pathname.endsWith("/integrations/wechat"))
        return reply(200, { pending: null, connection: null });
      if (url.pathname.includes("/integrations/signal"))
        return reply(
          200,
          url.pathname.endsWith("/number")
            ? { override: null, platform: null, effective: null }
            : { account: null, bindings: [], pending_claims: [] }
        );
      if (url.pathname.endsWith("/integrations/linear"))
        return reply(200, {
          configured: false,
          installation: null,
          member: null,
          completion_state_policies: ["unchanged", "in_review", "done"],
          workspace_id: workspaceId,
          workspace_name: "Main",
        });
      if (url.pathname === `/v1/comma/workspaces/${workspaceId}/integrations/telegram`)
        return reply(200, {
          bot_url: null,
          bot_username: null,
          configured: false,
          link: null,
          official_login_available: false,
          pending_claim: null,
          workspace_id: workspaceId,
          workspace_name: "Main",
        });
      if (
        url.pathname === `/v1/comma/workspaces/${workspaceId}/integrations/imessage`
      ) {
        if (request.method() === "DELETE") {
          server.disconnected += 1;
          server.link = null;
          return reply(200, { disconnected: true });
        }
        return reply(200, state());
      }
      if (
        url.pathname ===
        `/v1/comma/workspaces/${workspaceId}/integrations/imessage/connect`
      ) {
        if (request.method() === "DELETE") {
          server.cancelled += 1;
          server.attempt = null;
          return reply(200, { cancelled: true });
        }
        const body = request.postDataJSON() as { handle: string };
        server.started.push(body);
        // The server refuses a number Photon cannot register.
        if (body.handle === "+15550000000")
          return reply(400, { error: "invalid_imessage_handle" });
        server.attempt = {
          code,
          expires_at: Math.floor(start / 1000) + 600,
          transport: "photon",
          sender_handle: body.handle,
          line_handle: line,
        };
        return reply(201, server.attempt);
      }
      if (request.method() === "GET" && url.pathname === "/v1/comma/workspaces")
        return reply(200, {
          data: [{ group_id: "grp_imessage_e2e", id: workspaceId, name: "Main" }],
        });
      if (url.pathname === `/v1/comma/workspaces/${workspaceId}/agent-models`)
        return route.fulfill({ body: "{}", headers, status: 404 });
      throw new Error(`Unexpected request: ${request.method()} ${url.pathname}`);
    };

    await page.clock.install({ time: start });
    await installBrowserTestSession(page, session);
    await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, handle);
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Channels" }).click();

    // Photon is set up: Channels holds iMessage beside Telegram, WeChat, Signal and Linear.
    const card = page.locator('[data-setting-id="imessage.connection"]');
    await expect(card).toContainText("Not connected");
    await expect(page.locator('[data-slot="settings-row"]')).toHaveCount(5);
    await expect(card.locator('[data-provider-logo="imessage"]')).toBeVisible();
    await shoot(page, "imessage-empty");

    await card.getByRole("button", { name: "Connect", exact: true }).click();
    const field = card.getByLabel(/Your iMessage phone number or email/);
    await field.fill("4155550123");
    await card.getByRole("button", { name: "Get code" }).click();
    await expect(card).toContainText(
      "Enter an iMessage email address or a full phone number"
    );
    expect(server.started).toEqual([]);

    await field.fill("+15550000000");
    await expect(field).toHaveValue("+15550000000");
    await card.getByRole("button", { name: "Get code" }).click();
    await expect(card).toContainText("Comma could not use this account.");
    await shoot(page, "imessage-error");

    await field.fill(input);
    await expect(field).toHaveValue(input);
    await card.getByRole("button", { name: "Get code" }).click();
    await expect(card.getByTestId("imessage-code-value")).toHaveText(code);
    await expect(card.getByTestId("imessage-line")).toHaveText(line);
    await expect(card).toContainText(`from ${account}`);
    await expect(card.getByTestId("imessage-expiry")).toContainText(
      /Expires in (10:00|9:5\d)/
    );
    await expect(card).toContainText("Connecting");
    expect(server.started.at(-1)).toEqual({ handle: account });
    await shoot(page, "imessage-pending");

    // The person sends the code from that phone: the next read shows the connection.
    server.link = {
      sender_handle: account,
      sender_label: null,
      transport: "photon",
      connection_id: "imc_e2e",
      connected_at: Math.floor(start / 1000),
      updated_at: Math.floor(start / 1000),
    };
    server.attempt = null;
    await expect(card).toContainText("Connected");
    await expect(card).toContainText(account);
    await expect(card.getByTestId("imessage-code")).toHaveCount(0);
    await shoot(page, "imessage-connected");

    await card.getByRole("button", { name: "Manage", exact: true }).click();
    await page.getByRole("menuitem", { name: "Disconnect" }).click();
    await expect(card).toContainText("Not connected");
    expect(server.disconnected).toBe(1);
  });
}
