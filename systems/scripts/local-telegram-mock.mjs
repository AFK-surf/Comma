import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const maxBodyBytes = 1024 * 1024;

function json(response, status, body) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let raw = "";
    let size = 0;
    let rejected = false;

    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      if (rejected) return;
      size += Buffer.byteLength(chunk);
      if (size > maxBodyBytes) {
        rejected = true;
        reject(new Error("request body is too large"));
        return;
      }
      raw += chunk;
    });
    request.on("end", () => {
      if (rejected) return;
      try {
        resolve(raw === "" ? {} : JSON.parse(raw));
      } catch {
        reject(new Error("request body is not valid JSON"));
      }
    });
    request.on("error", reject);
  });
}

function sanitizedBody(method, body) {
  if (method !== "setWebhook") return body;

  return {
    ...body,
    ...(body.secret_token ? { secret_token: "[redacted]" } : {}),
  };
}

export function createTelegramMockServer({
  botToken = process.env.TELEGRAM_MOCK_BOT_TOKEN || "comma-local-dev-bot-token",
  botUsername = process.env.TELEGRAM_MOCK_BOT_USERNAME || "CommaLocalBot",
  logPath = process.env.LOG_PATH,
} = {}) {
  let messageId = 0;
  let requestId = 0;
  let requests = [];
  const commands = new Map();
  let menuButton = { type: "commands" };
  let webhook = {
    allowed_updates: [],
    url: "",
  };

  const record = (method, body) => {
    const entry = {
      id: ++requestId,
      at: new Date().toISOString(),
      method,
      body: sanitizedBody(method, body),
    };
    requests.push(entry);
    if (logPath) fs.appendFileSync(logPath, `${JSON.stringify(entry)}\n`);
    return entry;
  };

  return http.createServer(async (request, response) => {
    const url = new URL(request.url || "/", "http://telegram-mock.local");

    if (request.method === "GET" && url.pathname === "/health") {
      json(response, 200, { status: "ok" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/test/requests") {
      json(response, 200, { requests });
      return;
    }

    if (request.method === "POST" && url.pathname === "/test/reset") {
      requests = [];
      requestId = 0;
      messageId = 0;
      commands.clear();
      menuButton = { type: "commands" };
      webhook = { allowed_updates: [], url: "" };
      json(response, 200, { ok: true });
      return;
    }

    const match = url.pathname.match(/^\/bot([^/]+)\/(\w+)$/);
    if (!match || !["GET", "POST"].includes(request.method)) {
      json(response, 404, { ok: false, description: "not found" });
      return;
    }

    const [, presentedToken, method] = match;
    if (presentedToken !== botToken) {
      json(response, 401, { ok: false, description: "unauthorized" });
      return;
    }

    let body;
    try {
      body =
        request.method === "GET"
          ? Object.fromEntries(url.searchParams.entries())
          : await readJson(request);
    } catch (error) {
      json(response, 400, { ok: false, description: error.message });
      return;
    }

    record(method, body);

    switch (method) {
      case "getMe":
        json(response, 200, {
          ok: true,
          result: {
            id: 9_900_001,
            is_bot: true,
            first_name: "Comma Local",
            username: botUsername,
          },
        });
        return;

      case "setWebhook":
        webhook = {
          allowed_updates: body.allowed_updates || [],
          url: body.url || "",
        };
        json(response, 200, { ok: true, result: true });
        return;

      case "getWebhookInfo":
        json(response, 200, {
          ok: true,
          result: {
            allowed_updates: webhook.allowed_updates,
            has_custom_certificate: false,
            pending_update_count: 0,
            url: webhook.url,
          },
        });
        return;

      case "setMyCommands":
        commands.set(commandScopeKey(body), body.commands || []);
        json(response, 200, { ok: true, result: true });
        return;

      case "getMyCommands":
        json(response, 200, {
          ok: true,
          result: commands.get(commandScopeKey(body)) || [],
        });
        return;

      case "setChatMenuButton":
        menuButton = body.menu_button || { type: "commands" };
        json(response, 200, { ok: true, result: true });
        return;

      case "getChatMenuButton":
        json(response, 200, { ok: true, result: menuButton });
        return;

      case "sendMessage":
        json(response, 200, {
          ok: true,
          result: {
            message_id: ++messageId,
            chat: { id: body.chat_id, type: "private" },
            date: Math.floor(Date.now() / 1000),
            text: body.text,
          },
        });
        return;

      default:
        json(response, 404, {
          ok: false,
          description: `unsupported Telegram method: ${method}`,
        });
    }
  });
}

function commandScopeKey(body) {
  return JSON.stringify([
    body.scope || { type: "default" },
    body.language_code || "",
  ]);
}

function isMainModule() {
  return Boolean(
    process.argv[1] &&
    fileURLToPath(import.meta.url) === path.resolve(process.argv[1]),
  );
}

if (isMainModule()) {
  const port = Number(process.env.PORT || 43_124);
  const server = createTelegramMockServer();

  server.listen(port, "0.0.0.0", () => {
    console.log(`Comma local Telegram mock listening on ${port}`);
  });
}
