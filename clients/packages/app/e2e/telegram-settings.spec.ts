import { expect, test, type Request, type Route } from "@playwright/test";
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

for (const delayedStep of [
  "connect poll",
  "connect response",
  "disconnect response",
  "disconnect refresh",
  "disconnect failure",
] as const) {
  test(`ignores a late Telegram ${delayedStep} after leaving Channels`, async ({
    page,
  }) => {
    const disconnecting = delayedStep.startsWith("disconnect");
    let actionStarted = false;
    let releaseResponse!: () => void;
    const responseGate = new Promise<void>((resolve) => {
      releaseResponse = resolve;
    });
    let requestHeld!: () => void;
    const heldRequest = new Promise<void>((resolve) => {
      requestHeld = resolve;
    });
    const mutations: string[] = [];
    const inFlight = new Set<Request>();
    let returnedToChannels = false;
    page.on("request", (request) => {
      if (request.url().includes("/integrations/telegram")) inFlight.add(request);
    });
    const completed = (request: Request) => inFlight.delete(request);
    page.on("requestfinished", completed);
    page.on("requestfailed", completed);

    await installBrowserTestSession(page, session);
    await page
      .context()
      .route(/https:\/\/(oauth\.telegram\.org|t\.me)\//, (route) =>
        route.fulfill({ body: "Telegram", status: 200 })
      );
    await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
      const request = route.request();
      const path = new URL(request.url()).pathname;
      const method = request.method();
      const headers = corsHeaders(request.headers().origin);
      if (new URL(request.url()).pathname.endsWith("/integrations/wechat")) {
        await route.fulfill({
          headers,
          status: 200,
          body: JSON.stringify({ pending: null, connection: null }),
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

      const respond = (body: unknown, status = 200) =>
        route.fulfill({ body: JSON.stringify(body), headers, status });

      if (method === "OPTIONS") {
        await route.fulfill({ body: "", headers, status: 204 });
        return;
      }
      if (path === "/v1/comma/workspaces") {
        await respond({
          data: [{ group_id: "grp_a", id: workspaceId, name: "Workspace A" }],
        });
        return;
      }

      const isA = !returnedToChannels;
      if (method !== "GET") {
        mutations.push(`${method} ${path}`);
        if (isA) actionStarted = true;
      }
      const isPoll = method === "GET" && actionStarted;
      const shouldHold =
        isA &&
        ((delayedStep === "connect poll" && isPoll) ||
          (delayedStep === "connect response" && method === "POST") ||
          (delayedStep === "disconnect refresh" && isPoll) ||
          ((delayedStep === "disconnect response" ||
            delayedStep === "disconnect failure") &&
            method === "DELETE"));
      if (shouldHold) {
        requestHeld();
        await responseGate;
      }
      if (delayedStep === "disconnect failure" && isA && method === "DELETE") {
        await respond({ error: "disconnect failed" }, 500);
      } else if (path.endsWith("/connect")) {
        await respond({
          authorization_url: "https://oauth.telegram.org/auth?state=workspace-a",
          expires_in_seconds: 600,
          workspace_id: workspaceId,
        });
      } else if (method === "DELETE") {
        await respond({ disconnected: true });
      } else {
        let linked = disconnecting;
        if (isA) linked = disconnecting ? !actionStarted : actionStarted;
        await respond({
          bot_url: "https://t.me/CommaTestBot",
          bot_username: "CommaTestBot",
          configured: true,
          link: linked
            ? {
                connected_at: 1_788_400_000,
                telegram_user_id: isA ? "424242" : "525252",
                telegram_username: isA ? "alice" : "bob",
                updated_at: 1_788_400_000,
              }
            : null,
          official_login_available: true,
          pending_claim: null,
          workspace_id: workspaceId,
          workspace_name: isA ? "Workspace A" : "Workspace B",
        });
      }
    });

    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Channels" }).click();
    await expect(
      page.getByText(disconnecting ? "@alice" : "Chat with Comma in Telegram.")
    ).toBeVisible();
    if (disconnecting) {
      await page.getByRole("button", { name: "Manage", exact: true }).click();
      await page.getByRole("menuitem", { name: "Disconnect", exact: true }).click();
    } else {
      await page
        .getByRole("region", { name: "Telegram" })
        .getByRole("button", { name: "Connect", exact: true })
        .click();
    }
    await heldRequest;
    await page.getByRole("button", { name: "General", exact: true }).click();

    releaseResponse();
    // Drain the held response and any old-view follow-up before checking
    // absence, so a negative assertion cannot pass before the stale write.
    await expect.poll(() => inFlight.size).toBe(0);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    await expect(page.getByText("@alice")).toHaveCount(0);
    returnedToChannels = true;
    await page.getByRole("button", { name: "Channels", exact: true }).click();
    await expect(
      page.getByText(disconnecting ? "@bob" : "Chat with Comma in Telegram.")
    ).toBeVisible();
    if (disconnecting) {
      await page.getByRole("button", { name: "Manage", exact: true }).click();
      await page.getByRole("menuitem", { name: "Disconnect", exact: true }).click();
      await expect
        .poll(() => mutations.at(-1))
        .toBe(`DELETE /v1/comma/workspaces/${workspaceId}/integrations/telegram`);
    } else {
      await expect(
        page.getByRole("button", { name: "Manage", exact: true })
      ).toHaveCount(0);
      expect(mutations).toHaveLength(1);
    }
  });
}

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
  await expect(page.getByText("Chat with Comma in Telegram.")).toBeVisible();
  // Channels holds one card each for Telegram, WeChat and Signal.
  await expect(page.locator('[data-slot="settings-row"]')).toHaveCount(3);
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
  // Channels holds one card each for Telegram, WeChat and Signal.
  await expect(page.locator('[data-slot="settings-row"]')).toHaveCount(3);

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

for (const scenario of ["official login", "closed login", "blocked popup"] as const) {
  test(`cancels the exact ${scenario} attempt and permits retry`, async ({ page }) => {
    let cancelled: unknown;
    const mutations: string[] = [];
    await installBrowserTestSession(page, session);
    if (scenario === "blocked popup") {
      await page.addInitScript(() => {
        window.open = () => null;
      });
    }
    await page
      .context()
      .route(/https:\/\/(oauth\.telegram\.org|t\.me)\//, (route) =>
        route.fulfill({ body: "Telegram", status: 200 })
      );
    await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
      const request = route.request();
      const path = new URL(request.url()).pathname;
      const method = request.method();
      const headers = corsHeaders(request.headers().origin);
      if (new URL(request.url()).pathname.endsWith("/integrations/wechat")) {
        await route.fulfill({
          headers,
          status: 200,
          body: JSON.stringify({ pending: null, connection: null }),
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

      const respond = (body: unknown) =>
        route.fulfill({ body: JSON.stringify(body), headers, status: 200 });
      if (method === "OPTIONS")
        return route.fulfill({ body: "", headers, status: 204 });
      if (method !== "GET") mutations.push(`${method} ${path}`);
      if (path === "/v1/comma/workspaces")
        return respond({
          data: [{ group_id: "grp_telegram_e2e", id: workspaceId, name: "Main" }],
        });
      if (method === "DELETE" && path.endsWith("/connect")) {
        cancelled = request.postDataJSON();
        return respond({ cancelled: true });
      }
      if (method === "POST" && path.endsWith("/connect"))
        return respond({
          authorization_url: "https://oauth.telegram.org/auth?state=exact-attempt",
          expires_in_seconds: 600,
          workspace_id: workspaceId,
        });
      return respond({
        bot_url: "https://t.me/CommaTestBot",
        bot_username: "CommaTestBot",
        configured: true,
        link: null,
        official_login_available: true,
        workspace_id: workspaceId,
        workspace_name: "Main",
      });
    });
    await page.goto("/#/settings?category=channels");
    await expect(
      page
        .getByRole("region", { name: "Telegram" })
        .getByRole("button", { name: "Connect", exact: true })
    ).toBeEnabled();
    await expect(page.getByText("Chat with Comma in Telegram.")).toBeVisible();
    if (scenario === "blocked popup") {
      await page
        .getByRole("region", { name: "Telegram" })
        .getByRole("button", { name: "Connect", exact: true })
        .click();
      await expect(
        page.getByText("Telegram could not be updated. Please try again.")
      ).toBeVisible();
      await expect(
        page
          .getByRole("region", { name: "Telegram" })
          .getByRole("button", { name: "Connect", exact: true })
      ).toBeEnabled();
      await expect(
        page.getByRole("button", { name: /Generate code|Copy command/ })
      ).toHaveCount(0);
      expect(mutations).toEqual([]);
      return;
    }
    const popupPromise = page.waitForEvent("popup");
    await page
      .getByRole("region", { name: "Telegram" })
      .getByRole("button", { name: "Connect", exact: true })
      .click();
    const popup = await popupPromise;
    await expect(popup).toHaveURL(
      "https://oauth.telegram.org/auth?state=exact-attempt"
    );
    if (scenario === "closed login") await popup.close();
    else
      await page
        .getByRole("button", { name: "Cancel connection", exact: true })
        .click();
    await expect.poll(() => cancelled).toEqual({ state: "exact-attempt" });
    await expect(
      page.getByRole("button", { name: "Cancel connection", exact: true })
    ).toHaveCount(0);
    await expect(
      page
        .getByRole("region", { name: "Telegram" })
        .getByRole("button", { name: "Connect", exact: true })
    ).toBeEnabled();
    await expect(
      page.getByText(
        scenario === "closed login"
          ? "Telegram could not be updated. Please try again."
          : "Chat with Comma in Telegram."
      )
    ).toBeVisible();
  });
}
