import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_linear_e2e";
const session = {
  apiBaseUrl,
  email: "linear-e2e@example.com",
  token: "comma_sess_linear_e2e",
  userId: "usr_linear_e2e",
};

const corsHeaders = (origin = "http://127.0.0.1:4173") => ({
  "access-control-allow-credentials": "true",
  "access-control-allow-headers":
    "authorization,content-type,x-comma-session-transport",
  "access-control-allow-methods": "GET,POST,PATCH,DELETE,OPTIONS",
  "access-control-allow-origin": origin,
  "content-type": "application/json",
  vary: "origin",
});

const acme = {
  id: "linear_install_e2e",
  organization_id: "org_e2e",
  organization_name: "Acme",
  organization_url_key: "acme",
  installer: true,
  revoked: false,
  installed_at: "2026-10-07T00:01:00Z",
  updated_at: "2026-10-07T00:01:00Z",
};

// Serves the workspace's channels with Linear not connected yet, and opens
// Settings › Channels.
const openLinearSettings = async (page: Page) => {
  let connectCount = 0;
  let installation: Record<string, unknown> | null = null;
  let member: Record<string, unknown> | null = null;
  // Linear lands the link (and the installation) on the first read after an authorization starts.
  let pendingInstall = false;
  const patches: unknown[] = [];
  const deletes: string[] = [];

  const handle = async (route: Route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = corsHeaders(request.headers().origin);
    const json = async (body: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(body) });

    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }
    if (request.method() === "GET" && url.pathname === "/v1/comma/workspaces") {
      await json({
        data: [{ group_id: "grp_linear_e2e", id: workspaceId, name: "Main" }],
      });
      return;
    }
    if (url.pathname.endsWith("/integrations/telegram")) {
      await json({
        bot_url: null,
        bot_username: null,
        configured: false,
        link: null,
        official_login_available: false,
        workspace_id: workspaceId,
        workspace_name: "Main",
      });
      return;
    }
    if (url.pathname.endsWith("/integrations/wechat")) {
      await json({ pending: null, connection: null });
      return;
    }
    if (url.pathname.includes("/integrations/signal")) {
      await json(
        url.pathname.endsWith("/number")
          ? { override: null, platform: null, effective: null }
          : { account: null, bindings: [], pending_claims: [] }
      );
      return;
    }
    if (url.pathname.endsWith("/integrations/imessage")) {
      await json({
        configured: false,
        shared_handle: null,
        shared_identity: "Comma",
        workspace_id: workspaceId,
        connection_active: false,
        relay_online: false,
        pending_claim: null,
        link: null,
      });
      return;
    }
    // The Router's label reads its models; this test does not show them.
    if (url.pathname.endsWith("/agent-models")) {
      await json({}, 404);
      return;
    }

    const linearPath = `/v1/comma/workspaces/${workspaceId}/integrations/linear`;
    if (request.method() === "POST" && url.pathname === `${linearPath}/connect`) {
      connectCount += 1;
      pendingInstall = true;
      await json({
        authorization_url:
          "https://linear.app/oauth/authorize?scope=read&state=dev.linear-e2e",
        expires_at: "2026-10-07T00:10:00Z",
      });
      return;
    }
    if (request.method() === "GET" && url.pathname === linearPath) {
      if (pendingInstall && !member) {
        pendingInstall = false;
        installation = installation ?? { ...acme };
        member = {
          id: "linear_member_e2e",
          linear_user_id: "linear-user-yue",
          linear_user_name: "Yue",
          linear_user_email: "yue@acme.test",
          completion_state_policy: "unchanged",
          linked_at: "2026-10-07T00:01:00Z",
          updated_at: "2026-10-07T00:01:00Z",
        };
      }
      await json({
        configured: true,
        installation,
        member,
        completion_state_policies: ["unchanged", "in_review", "done"],
        workspace_id: workspaceId,
        workspace_name: "Main",
      });
      return;
    }
    if (request.method() === "PATCH" && url.pathname === linearPath) {
      const body = request.postDataJSON() as Record<string, unknown>;
      patches.push(body);
      member = {
        ...member,
        ...(body.completion_state_policy
          ? { completion_state_policy: body.completion_state_policy }
          : {}),
        updated_at: `2026-10-07T00:0${patches.length + 1}:00Z`,
      };
      await json(member);
      return;
    }
    if (request.method() === "DELETE" && url.pathname === linearPath) {
      const scope = url.searchParams.get("scope") ?? "member";
      deletes.push(scope);
      const removed =
        scope === "organization" ? Boolean(installation) : Boolean(member);
      member = null;
      if (scope === "organization") installation = null;
      await json({ disconnected: removed });
      return;
    }

    throw new Error(`Unexpected request: ${request.method()} ${url.pathname}`);
  };

  await installBrowserTestSession(page, session);
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, handle);
  await page.context().route("https://linear.app/**", async (route) => {
    await route.fulfill({ body: "Linear authorization", status: 200 });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Channels" }).click();
  return {
    get connectCount() {
      return connectCount;
    },
    deletes,
    patches,
  };
};

test("connects a Linear account, installs Comma into its organization and keeps the settings", async ({
  page,
}) => {
  const linear = await openLinearSettings(page);
  const { deletes, patches } = linear;
  const card = page.getByRole("region", { name: "Linear" });
  await expect(card).toBeVisible();
  await expect(
    page.getByText("Assign Linear issues to Comma, or mention @Comma in a comment.")
  ).toBeVisible();
  await expect(page.locator('[data-provider-logo="linear"]')).toBeVisible();
  // Status, organization and account all read as not connected.
  await expect(card.getByText("Not connected", { exact: true })).toHaveCount(3);

  const popupPromise = page.waitForEvent("popup");
  await card.getByRole("button", { name: "Connect", exact: true }).click();
  const popup = await popupPromise;
  await expect(popup).toHaveURL(
    "https://linear.app/oauth/authorize?scope=read&state=dev.linear-e2e"
  );

  await expect(card.getByText("Connected", { exact: true })).toBeVisible();
  await expect(card.getByText("Acme", { exact: true })).toBeVisible();
  await expect(card.getByText("Yue")).toBeVisible();
  await expect(card.getByRole("button", { name: "Manage", exact: true })).toBeEnabled();
  expect(linear.connectCount).toBe(1);
  await page.screenshot({ path: test.info().outputPath("linear-connected.png") });

  // The settings pick what happens to the issue; its Task runs where and on
  // what the workspace's defaults say, so there is no Worker to pick.
  await card.getByRole("button", { name: /When a Task completes/ }).click();
  await page.getByRole("option", { name: "Move the issue to In Review" }).click();
  await expect.poll(() => patches.length).toBe(1);
  expect(patches[0]).toEqual({ completion_state_policy: "in_review" });

  await card.getByRole("button", { name: "Manage", exact: true }).click();
  await page.getByRole("menuitem", { name: "Reconnect" }).click();
  await expect(page.getByRole("dialog", { name: "Reconnect Linear?" })).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  expect(linear.connectCount).toBe(1);

  // Disconnecting removes this person's link; the organization's installation,
  // which this workspace holds, stays and can be removed from here.
  await card.getByRole("button", { name: "Manage", exact: true }).click();
  await page.getByRole("menuitem", { name: "Disconnect" }).click();
  await expect(card.getByText("Not connected", { exact: true })).toHaveCount(2);
  await expect(card.getByText("Acme", { exact: true })).toBeVisible();
  await expect(
    card.getByRole("button", { name: "Connect", exact: true })
  ).toBeEnabled();
  expect(deletes).toEqual(["member"]);

  await card.getByRole("button", { name: "Remove from organization" }).click();
  const remove = page.getByRole("dialog", { name: "Remove Comma from Acme?" });
  await expect(remove).toBeVisible();
  await remove.getByRole("button", { name: "Remove from organization" }).click();
  await expect(card.getByText("Not connected", { exact: true })).toHaveCount(3);
  expect(deletes).toEqual(["member", "organization"]);
});
