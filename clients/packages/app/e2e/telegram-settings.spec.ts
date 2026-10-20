import { expect, test, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_telegram_e2e";
const disabledIMessage = {
  configured: false,
  shared_handle: null,
  shared_identity: "Comma",
  workspace_id: workspaceId,
  connection_active: false,
  relay_online: false,
  pending_claim: null,
  link: null,
};
const session = {
  apiBaseUrl,
  email: "telegram-e2e@example.com",
  token: "comma_sess_telegram_e2e",
  userId: "usr_telegram_e2e",
};

const corsHeaders = (origin = "http://127.0.0.1:4173") => ({
  "access-control-allow-credentials": "true",
  "access-control-allow-headers":
    "authorization,content-type,x-comma-session-transport",
  "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
  "access-control-allow-origin": origin,
  "content-type": "application/json",
  vary: "origin",
});

test("connects the Comma-owned Telegram channel without exposing workspace selection", async ({
  page,
}) => {
  let connectCount = 0;
  let botUsername = "CommaTestBot";
  let accountUsername = "ada";

  const handleTelegramRequest = async (route: Route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = corsHeaders(request.headers().origin);
    if (new URL(request.url()).pathname.endsWith("/integrations/wechat")) {
      await route.fulfill({
        headers,
        status: 200,
        body: JSON.stringify({ pending: null, connection: null }),
      });
      return;
    }

    if (url.pathname.includes("/integrations/signal")) {
      await route.fulfill({
        headers,
        status: 200,
        body: JSON.stringify(
          url.pathname.endsWith("/number")
            ? { override: null, platform: null, effective: null }
            : { account: null, bindings: [], pending_claims: [] }
        ),
      });
      return;
    }

    if (url.pathname.endsWith("/integrations/linear")) {
      await route.fulfill({
        headers,
        status: 200,
        body: JSON.stringify({
          configured: false,
          installation: null,
          member: null,
          completion_state_policies: ["unchanged", "in_review", "done"],
          workspace_id: workspaceId,
          workspace_name: "Main",
        }),
      });
      return;
    }

    if (new URL(request.url()).pathname.endsWith("/integrations/imessage")) {
      await route.fulfill({
        headers,
        status: 200,
        body: JSON.stringify(disabledIMessage),
      });
      return;
    }

    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }

    if (request.method() === "GET" && url.pathname === "/v1/comma/workspaces") {
      await route.fulfill({
        body: JSON.stringify({
          data: [{ group_id: "grp_telegram_e2e", id: workspaceId, name: "Main" }],
        }),
        headers,
        status: 200,
      });
      return;
    }

    if (
      request.method() === "POST" &&
      url.pathname ===
        `/v1/comma/workspaces/${workspaceId}/integrations/telegram/connect`
    ) {
      connectCount += 1;
      await route.fulfill({
        body: JSON.stringify({
          authorization_url: "https://oauth.telegram.org/auth?state=telegram-e2e",
          expires_in_seconds: 600,
          workspace_id: workspaceId,
        }),
        headers,
        status: 200,
      });
      return;
    }

    if (
      request.method() === "GET" &&
      url.pathname === `/v1/comma/workspaces/${workspaceId}/integrations/telegram`
    ) {
      await route.fulfill({
        body: JSON.stringify({
          bot_url: `https://t.me/${botUsername}`,
          bot_username: botUsername,
          configured: true,
          link:
            connectCount > 0
              ? {
                  connection_id: `connection-${connectCount}`,
                  connected_at: 1_788_400_000,
                  telegram_user_id: "424242",
                  telegram_username: accountUsername,
                  updated_at: 1_788_400_000,
                }
              : null,
          official_login_available: true,
          pending_claim: null,
          workspace_id: workspaceId,
          workspace_name: "Main",
        }),
        headers,
        status: 200,
      });
      return;
    }

    // The task list (the client core's worker) names the active workspace, and
    // the Router's label reads its models; this test does not show them.
    if (
      request.method() === "GET" &&
      url.pathname === `/v1/comma/workspaces/${workspaceId}/agent-models`
    ) {
      await route.fulfill({ body: "{}", headers, status: 404 });
      return;
    }

    throw new Error(`Unexpected request: ${request.method()} ${url.pathname}`);
  };

  await installBrowserTestSession(page, session);
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, handleTelegramRequest);
  await page.context().route("https://oauth.telegram.org/**", async (route) => {
    await route.fulfill({ body: "Telegram authorization", status: 200 });
  });
  await page.goto("/#/settings");

  await page.getByRole("button", { name: "Channels" }).click();
  await expect(page.getByRole("region", { name: "Telegram" })).toBeVisible();
  // Channels holds one card each for Telegram, WeChat, Signal and Linear.
  await expect(page.locator('[data-slot="settings-row"]')).toHaveCount(4);
  await expect(
    page.getByRole("button", { name: /Generate code|Copy command/ })
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Main Select a workspace" })
  ).toHaveCount(0);
  await expect(page.getByText("Comma workspace", { exact: true })).toHaveCount(0);
  await expect(page.locator('[data-provider-logo="telegram"]')).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("telegram-disconnected.png") });

  const popupPromise = page.waitForEvent("popup");
  await page
    .getByRole("region", { name: "Telegram" })
    .getByRole("button", { name: "Connect", exact: true })
    .click();
  const popup = await popupPromise;
  await expect(popup).toHaveURL("https://oauth.telegram.org/auth?state=telegram-e2e");

  await expect(page.getByText("@ada")).toBeVisible();
  await expect(page.getByRole("button", { name: "Manage", exact: true })).toBeEnabled();
  await page.screenshot({ path: test.info().outputPath("telegram-connected.png") });
  await page.getByRole("region", { name: "Telegram" }).screenshot({
    path: test.info().outputPath("telegram-card.png"),
  });
  await page.getByRole("button", { name: "Manage", exact: true }).click();
  await expect(page.getByRole("menuitem", { name: "Disconnect" })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("telegram-manage.png") });
  await page.getByRole("menuitem", { name: "Reconnect" }).click();
  await expect(page.getByRole("dialog", { name: "Reconnect Telegram?" })).toBeVisible();
  await expect(
    page.getByText(/it will replace the currently connected account/)
  ).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("button", { name: "Manage", exact: true })).toBeFocused();
  await expect(page.getByText("@ada")).toBeVisible();
  expect(connectCount).toBe(1);
  await page.getByRole("button", { name: "Manage", exact: true }).click();
  await page.getByRole("menuitem", { name: "Reconnect" }).click();
  const reconnectPopupPromise = page.waitForEvent("popup");
  await page.getByRole("button", { name: "Reconnect", exact: true }).click();
  const reconnectPopup = await reconnectPopupPromise;
  await expect(reconnectPopup).toHaveURL(
    "https://oauth.telegram.org/auth?state=telegram-e2e"
  );
  await expect(page.getByRole("button", { name: "Manage", exact: true })).toBeEnabled();
  expect(connectCount).toBe(2);
  // Channels holds one card each for Telegram, WeChat, Signal and Linear.
  await expect(page.locator('[data-slot="settings-row"]')).toHaveCount(4);

  // Reuse the connected fixture with full-length handles to exercise wrapping.
  botUsername = "comma_connector_with_long_ab_bot";
  accountUsername = "telegram_account_with_32_letters";
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByRole("button", { name: "Channels", exact: true }).click();
  const telegramCard = page.getByRole("region", { name: "Telegram" });
  const botAction = telegramCard.getByRole("button", {
    name: `Open in Telegram (@${botUsername})`,
  });
  const account = telegramCard.locator("dd").filter({ hasText: `@${accountUsername}` });
  await page.setViewportSize({ width: 480, height: 800 });
  await expect(botAction).toBeVisible();
  await expect(account).toBeVisible();
  for (const detail of [botAction, account]) {
    expect(
      await detail.evaluate((element) => element.scrollWidth - element.clientWidth)
    ).toBeLessThanOrEqual(1);
  }
  await expect
    .poll(async () => {
      const [accountBox, botBox] = await Promise.all([
        account.boundingBox(),
        botAction.boundingBox(),
      ]);
      return Boolean(
        accountBox && botBox && botBox.y >= accountBox.y + accountBox.height
      );
    })
    .toBe(true);
  for (const action of [
    botAction,
    telegramCard.getByRole("button", { name: "Manage", exact: true }),
  ]) {
    const cardBox = (await telegramCard.boundingBox())!;
    const actionBox = (await action.boundingBox())!;
    expect(actionBox.x).toBeGreaterThanOrEqual(cardBox.x);
    expect(actionBox.x + actionBox.width).toBeLessThanOrEqual(
      cardBox.x + cardBox.width + 1
    );
  }
  expect(
    await telegramCard.evaluate((element) => element.scrollWidth - element.clientWidth)
  ).toBeLessThanOrEqual(1);
  await page.screenshot({ path: test.info().outputPath("telegram-narrow.png") });

  await page.setViewportSize({ width: 1280, height: 800 });
  await page.getByRole("button", { name: "Appearance", exact: true }).click();
  await page.getByRole("button", { name: /Select theme/ }).click();
  await page.getByRole("option", { name: "Dark", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
  await page.getByRole("button", { name: "Channels", exact: true }).click();
  await expect(botAction).toBeVisible();
  await expect(account).toBeVisible();
  await telegramCard.screenshot({
    path: test.info().outputPath("telegram-card-dark.png"),
  });
});
