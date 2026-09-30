import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { createTelegramMockServer } from "./local-telegram-mock.mjs";

describe("Comma local Telegram mock", () => {
  let baseUrl;
  let server;

  before(async () => {
    server = createTelegramMockServer({
      botToken: "test-bot-token",
      botUsername: "CommaTestBot",
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  });

  it("implements the Telegram identity, webhook, and sendMessage contract", async () => {
    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200);

    const unauthorized = await telegram("wrong-token", "getMe");
    assert.equal(unauthorized.status, 401);

    const me = await fetch(`${baseUrl}/bottest-bot-token/getMe`);
    assert.deepEqual((await me.json()).result.username, "CommaTestBot");

    const setWebhook = await telegram("test-bot-token", "setWebhook", {
      allowed_updates: ["message"],
      secret_token: "do-not-return-this-secret",
      url: "http://127.0.0.1:4200/v1/comma/integrations/telegram/webhook",
    });
    assert.equal((await setWebhook.json()).result, true);

    const webhookInfo = await telegram("test-bot-token", "getWebhookInfo");
    assert.deepEqual((await webhookInfo.json()).result.allowed_updates, [
      "message",
    ]);

    const sent = await telegram("test-bot-token", "sendMessage", {
      chat_id: "42001",
      text: "LOCAL_CHAT_OK",
    });
    assert.equal((await sent.json()).result.text, "LOCAL_CHAT_OK");

    const captured = await fetch(`${baseUrl}/test/requests`).then((response) =>
      response.json(),
    );
    assert.deepEqual(
      captured.requests.map((request) => request.method),
      ["getMe", "setWebhook", "getWebhookInfo", "sendMessage"],
    );
    assert.equal(
      captured.requests.find((request) => request.method === "setWebhook").body
        .secret_token,
      "[redacted]",
    );
    assert.equal(JSON.stringify(captured).includes("test-bot-token"), false);
    assert.equal(
      JSON.stringify(captured).includes("do-not-return-this-secret"),
      false,
    );

    const reset = await fetch(`${baseUrl}/test/reset`, { method: "POST" });
    assert.equal(reset.status, 200);
    const afterReset = await fetch(`${baseUrl}/test/requests`).then(
      (response) => response.json(),
    );
    assert.deepEqual(afterReset.requests, []);
  });

  it("keeps command menus scoped by chat type and language and resets them", async () => {
    const scope = { type: "all_private_chats" };
    const commands = [{ command: "help", description: "查看帮助" }];
    await telegram("test-bot-token", "setMyCommands", {
      scope,
      language_code: "zh",
      commands,
    });

    const read = async (body) => {
      const response = await telegram("test-bot-token", "getMyCommands", body);
      return (await response.json()).result;
    };
    assert.deepEqual(await read({ scope, language_code: "zh" }), commands);
    assert.deepEqual(await read({ scope, language_code: "en" }), []);
    assert.deepEqual(await read({ language_code: "zh" }), []);

    await telegram("test-bot-token", "setChatMenuButton", {
      menu_button: { type: "commands" },
    });
    const menu = await telegram("test-bot-token", "getChatMenuButton");
    assert.deepEqual((await menu.json()).result, { type: "commands" });

    await fetch(`${baseUrl}/test/reset`, { method: "POST" });
    assert.deepEqual(await read({ scope, language_code: "zh" }), []);
  });

  it("rejects oversized JSON without dropping the HTTP response", async () => {
    const response = await telegram("test-bot-token", "sendMessage", {
      chat_id: "42001",
      text: "x".repeat(1024 * 1024),
    });

    assert.equal(response.status, 400);
    assert.equal(
      (await response.json()).description,
      "request body is too large",
    );
  });

  function telegram(token, method, body = {}) {
    return fetch(`${baseUrl}/bot${token}/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  }
});
