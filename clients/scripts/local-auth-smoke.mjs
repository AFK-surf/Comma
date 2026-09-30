import assert from "node:assert/strict";
import { chromium } from "@playwright/test";
import {
  bearerSessionHeaders,
  cookieSessionHeaders,
} from "./local-auth-smoke-contract.mjs";

const apiBaseUrl = normalizedUrl(
  process.env.COMMA_LOCAL_AUTH_API_BASE_URL || "http://127.0.0.1:4200"
);
const webBaseUrl = normalizedUrl(
  process.env.COMMA_LOCAL_AUTH_WEB_BASE_URL || "http://127.0.0.1:5174"
);
const mailpitBaseUrl = normalizedUrl(
  process.env.COMMA_LOCAL_AUTH_MAILPIT_BASE_URL || "http://127.0.0.1:8025"
);
const email = `comma-auth-smoke-${Date.now()}@example.com`;

await requireHealthy(`${apiBaseUrl}/health`, "Comma API");
await requireHealthy(webBaseUrl, "Comma Web");
await requireHealthy(`${mailpitBaseUrl}/api/v1/messages`, "Mailpit");

const browser = await chromium.launch({ headless: true });
let issuedSessionToken;

try {
  const context = await browser.newContext();
  const page = await context.newPage();

  await page.addInitScript((baseUrl) => {
    localStorage.setItem("comma.apiBaseUrl", baseUrl);
  }, apiBaseUrl);

  await page.goto(webBaseUrl);
  await page.getByRole("textbox", { name: /email/i }).fill(email);
  await page.getByRole("button", { name: "Send code" }).click();

  const code = await waitForMailpitCode(email);
  await page.getByRole("textbox", { name: /verification code/i }).fill(code);
  await page.getByRole("button", { name: "Verify code" }).click();
  await page.getByRole("complementary", { name: "App sidebar" }).waitFor();

  assert.equal(await page.getByRole("link", { name: "Admin" }).count(), 0);

  const browserStorage = await page.evaluate(() => ({
    admin: localStorage.getItem("comma.userAdmin"),
    email: localStorage.getItem("comma.userEmail"),
    token: localStorage.getItem("comma.sessionToken"),
  }));
  assert.deepEqual(browserStorage, { admin: null, email: null, token: null });

  const authCookie = (await context.cookies(apiBaseUrl)).find(
    (cookie) => cookie.name === "comma_session"
  );
  assert.ok(authCookie, "browser login did not set comma_session");
  assert.equal(authCookie.httpOnly, true);
  assert.equal(authCookie.sameSite, "Lax");
  issuedSessionToken = authCookie.value;

  const sessionView = await page.evaluate(
    async ({ baseUrl, headers }) => {
      const response = await fetch(`${baseUrl}/v1/comma/auth/session`, {
        credentials: "include",
        headers,
      });
      return { body: await response.json(), status: response.status };
    },
    {
      baseUrl: apiBaseUrl,
      headers: cookieSessionHeaders("unknown"),
    }
  );
  assert.equal(sessionView.status, 200);
  assert.equal(sessionView.body.user.email, email);
  assert.equal(Object.hasOwn(sessionView.body.user, "admin"), false);
  assert.equal(Object.hasOwn(sessionView.body, "token"), false);
  const sessionId = sessionView.body.session_id;
  assert.equal(typeof sessionId, "string");
  assert.ok(sessionId.length > 0, "session view did not return a Session id");

  const firstBootstrap = await browserApi(page, "/v1/comma/me/bootstrap", sessionId, {
    method: "POST",
  });
  assert.ok(
    firstBootstrap.status === 200 || firstBootstrap.status === 202,
    `workspace bootstrap returned HTTP ${firstBootstrap.status}`
  );
  assert.ok(firstBootstrap.body.workspace?.id, "bootstrap did not return a Workspace");
  const workspaceId = firstBootstrap.body.workspace.id;

  const readyBootstrap = await waitForWorkspaceReady(page, workspaceId, sessionId);
  assert.equal(readyBootstrap.body.workspace.id, workspaceId);
  assert.equal(readyBootstrap.body.status, "ready");

  const repeatedBootstrap = await browserApi(
    page,
    "/v1/comma/me/bootstrap",
    sessionId,
    {
      method: "POST",
    }
  );
  assert.equal(repeatedBootstrap.status, 200);
  assert.equal(repeatedBootstrap.body.workspace.id, workspaceId);

  const workspaceList = await browserApi(page, "/v1/comma/workspaces", sessionId);
  assert.equal(workspaceList.status, 200);
  assert.deepEqual(
    workspaceList.body.data.map((workspace) => workspace.id),
    [workspaceId]
  );

  const workspaceView = await browserApi(
    page,
    `/v1/comma/workspaces/${workspaceId}`,
    sessionId
  );
  assert.equal(workspaceView.status, 200);
  assert.equal(workspaceView.body.id, workspaceId);

  await page.reload();
  await page.getByRole("complementary", { name: "App sidebar" }).waitFor();

  await page.getByRole("button", { name: "Sign out" }).click();
  await page.getByRole("heading", { name: "Sign in to Comma" }).waitFor();
  await assertEventually(async () => {
    const cookies = await context.cookies(apiBaseUrl);
    return !cookies.some((cookie) => cookie.name === "comma_session");
  }, "logout did not clear comma_session");

  const revokedSession = await fetch(`${apiBaseUrl}/v1/comma/auth/session`, {
    headers: bearerSessionHeaders({
      accept: "application/json",
      authorization: `Bearer ${issuedSessionToken}`,
    }),
  });
  assert.equal(revokedSession.status, 401, "logout did not revoke the server Session");
  issuedSessionToken = undefined;

  await page.reload();
  await page.getByRole("heading", { name: "Sign in to Comma" }).waitFor();

  process.stdout.write(
    `${JSON.stringify({
      apiBaseUrl,
      email,
      result: "pass",
      checks: [
        "email_otp",
        "http_only_cookie",
        "no_renderer_secret",
        "session_reload",
        "ordinary_session_no_admin",
        "server_revocation",
        "workspace_ready",
        "workspace_bootstrap_idempotent",
        "owner_only_workspace_visible",
      ],
    })}\n`
  );
} finally {
  if (issuedSessionToken) {
    await fetch(`${apiBaseUrl}/v1/comma/auth/logout`, {
      body: "{}",
      headers: bearerSessionHeaders({
        authorization: `Bearer ${issuedSessionToken}`,
        "content-type": "application/json",
      }),
      method: "POST",
    }).catch(() => {});
  }
  await browser.close();
}

async function waitForMailpitCode(recipient) {
  let lastError;

  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(`${mailpitBaseUrl}/api/v1/messages`);
      assert.equal(response.ok, true);
      const mailbox = await response.json();
      const message = mailbox.messages?.find(
        (candidate) =>
          candidate.Subject === "Your Comma login code" &&
          candidate.To?.some((address) => address.Address === recipient)
      );
      const code = message?.Snippet?.match(/\b\d{6}\b/)?.[0];

      if (code) {
        return code;
      }
    } catch (error) {
      lastError = error;
    }

    await delay(250);
  }

  throw new Error(
    `Mailpit did not receive a Comma code for ${recipient}${
      lastError instanceof Error ? `: ${lastError.message}` : ""
    }`
  );
}

async function requireHealthy(url, label) {
  try {
    const response = await fetch(url);
    assert.equal(response.ok, true, `${label} returned HTTP ${response.status}`);
  } catch (error) {
    throw new Error(
      `${label} is unavailable at ${url}: ${
        error instanceof Error ? error.message : String(error)
      }`,
      { cause: error }
    );
  }
}

async function waitForWorkspaceReady(page, workspaceId, expectedSessionId) {
  let latest;

  for (let attempt = 0; attempt < 80; attempt += 1) {
    latest = await browserApi(page, "/v1/comma/me/bootstrap", expectedSessionId, {
      method: "POST",
    });

    if (
      latest.status === 200 &&
      latest.body.status === "ready" &&
      latest.body.workspace?.id === workspaceId
    ) {
      return latest;
    }

    assert.equal(latest.status, 202);
    assert.equal(latest.body.status, "provisioning");
    assert.equal(latest.body.workspace?.id, workspaceId);
    await delay(250);
  }

  throw new Error(
    `Workspace ${workspaceId} did not become ready: ${JSON.stringify(latest)}`
  );
}

async function browserApi(page, path, expectedSessionId, options = {}) {
  return page.evaluate(
    async ({
      apiBaseUrl: browserApiBaseUrl,
      headers,
      options: requestOptions,
      path: requestPath,
    }) => {
      const response = await fetch(`${browserApiBaseUrl}${requestPath}`, {
        ...requestOptions,
        body: requestOptions.method === "POST" ? "{}" : undefined,
        credentials: "include",
        headers,
      });

      return { body: await response.json(), status: response.status };
    },
    {
      apiBaseUrl,
      headers: cookieSessionHeaders(expectedSessionId, {
        "content-type": "application/json",
      }),
      options,
      path,
    }
  );
}

async function assertEventually(check, message) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (await check()) {
      return;
    }
    await delay(100);
  }

  throw new Error(message);
}

function normalizedUrl(value) {
  return value.replace(/\/+$/, "");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
