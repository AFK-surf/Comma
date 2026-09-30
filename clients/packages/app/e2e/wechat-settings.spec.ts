import jsQR from "jsqr";
import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import type { CommaWeChatConnection } from "../src/api";

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_wechat_e2e";

test("WeChat QR, pairing code, reconnect cancellation and disconnect use the selected workspace", async ({
  page,
}) => {
  let pending: CommaWeChatConnection | null = null;
  let connection: CommaWeChatConnection | null = null;
  let nextStatus = "wait";
  let sequence = 0;
  let failActivation = false;
  const mutations: string[] = [];
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "wechat@example.test",
    token: "comma_sess_wechat",
    userId: "usr_wechat",
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();
    const headers = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
      "access-control-allow-origin":
        request.headers().origin || "http://127.0.0.1:4173",
      "content-type": "application/json",
    };
    const respond = (body: unknown, status = 200) =>
      route.fulfill({ body: JSON.stringify(body), headers, status });
    if (method === "OPTIONS") return route.fulfill({ headers, status: 204, body: "" });
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [{ group_id: "grp_wechat", id: workspaceId, name: "Main" }],
      });
    if (path.endsWith("/integrations/telegram"))
      return respond({
        bot_url: null,
        bot_username: null,
        configured: false,
        link: null,
        connection_active: false,
        official_login_available: false,
        workspace_id: workspaceId,
        workspace_name: "Main",
      });
    if (!path.includes("/integrations/wechat")) return respond({}, 404);
    expect(path).toContain(`/v1/comma/workspaces/${workspaceId}/`);
    if (method !== "GET") mutations.push(`${method} ${path}`);
    if (path.endsWith("/wechat/connect") && method === "POST") {
      pending = {
        connect_id: `imc-${++sequence}`,
        status: "pending",
        login_status: "wait",
        connection_active: false,
        qrcode_url: "https://weixin.qq.com/test-qr",
        expires_at: Math.floor(Date.now() / 1000) + 300,
      };
      return respond(pending, 201);
    }
    if (path.endsWith("/wechat/connect/poll")) {
      expect(request.postDataJSON().attempt_id).toBe(pending!.connect_id);
      if (failActivation) {
        pending = {
          ...pending!,
          status: "prepared",
          login_status: "confirmed",
          qrcode_url: null,
          expires_at: 0,
        };
        failActivation = false;
        return respond({ error: "wechat_integration_unavailable" }, 502);
      }
      if (request.postDataJSON().verify_code || pending!.status === "prepared") {
        if (request.postDataJSON().verify_code)
          expect(request.postDataJSON().verify_code).toBe("123456");
        connection = {
          ...pending!,
          status: "connected",
          login_status: "confirmed",
          connection_active: true,
          qrcode_url: null,
          wechat_id: "alice",
        };
        pending = null;
        return respond(connection);
      }
      pending = {
        ...pending!,
        login_status: nextStatus as CommaWeChatConnection["login_status"],
      };
      return respond(pending);
    }
    if (path.endsWith("/wechat/connect") && method === "DELETE") {
      expect(request.postDataJSON()).toEqual({ attempt_id: pending!.connect_id });
      pending = null;
      return respond({ cancelled: true });
    }
    if (method === "DELETE") {
      pending = null;
      connection = null;
      return respond({ disconnected: true });
    }
    return respond({ pending, connection });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Channels", exact: true }).click();
  await expect(page.locator('[data-provider-logo="wechat"]')).toBeVisible();
  const card = page.locator('[data-setting-id="wechat.connection"]');
  await card.getByRole("button", { name: "Connect", exact: true }).click();
  const qr = card.getByRole("figure", { name: "WeChat connection QR code" });
  await expect(qr).toBeVisible();
  const pixels = await qr.locator("canvas").evaluate((element: HTMLCanvasElement) => ({
    width: element.width,
    height: element.height,
    data: Array.from(
      element.getContext("2d")!.getImageData(0, 0, element.width, element.height).data
    ),
  }));
  expect(
    jsQR(new Uint8ClampedArray(pixels.data), pixels.width, pixels.height)?.data
  ).toBe("https://weixin.qq.com/test-qr");
  await page.screenshot({ path: test.info().outputPath("wechat-qr.png") });
  nextStatus = "need_verifycode";
  await card.getByRole("textbox", { name: "Pairing code" }).fill("123456");
  await card.getByRole("button", { name: "Confirm code" }).click();
  await expect(card.getByText("Connected", { exact: true })).toBeVisible();
  await expect(card.getByText("alice", { exact: true })).toBeVisible();
  nextStatus = "wait";
  await card.getByRole("button", { name: "Manage", exact: true }).click();
  await page.getByRole("menuitem", { name: "Reconnect", exact: true }).click();
  await expect(qr).toBeVisible();
  await card.getByRole("button", { name: "Cancel connection", exact: true }).click();
  await expect(card.getByText("Connected", { exact: true })).toBeVisible();
  await card.getByRole("button", { name: "Manage", exact: true }).click();
  await page.getByRole("menuitem", { name: "Disconnect", exact: true }).click();
  await expect(card.getByText("Not connected", { exact: true })).toBeVisible();
  nextStatus = "expired";
  await card.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(card.getByRole("button", { name: "Create new QR code" })).toBeVisible();
  await expect(qr).toHaveCount(0);
  failActivation = true;
  await card.getByRole("button", { name: "Create new QR code" }).click();
  await card.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(card.getByText("Connected", { exact: true })).toBeVisible();
  await expect(qr).toHaveCount(0);
  expect(mutations).toContain(
    `DELETE /v1/comma/workspaces/${workspaceId}/integrations/wechat`
  );
});
