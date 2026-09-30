import { expect, test } from "@playwright/test";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import {
  createE2eSessionProjection,
  startSessionProjectionStub,
} from "../../../e2e/helpers/session-fixture";

const target = "group_id=grp_panel&conversation_id=cnv_panel";
const previewPath = "/v1/comma/groups/grp_panel/conversations/cnv_panel/preview";

test.beforeEach(async ({ page }) => {
  await page.route("https://telegram.org/js/telegram-web-app.js?63", (route) =>
    route.fulfill({ status: 200, contentType: "application/javascript", body: "" })
  );
});

test("the chat-hosted Task panel reads and refreshes one Task without starting chat", async ({
  page,
}) => {
  const requests: string[] = [];
  let status = "active";
  let forbidden = false;
  const stub = await startSessionProjectionStub({
    email: "task-panel@comma.local",
    profile: { name: "Task panel reader" },
    handleRequest(request, response, path) {
      requests.push(`${request.method} ${request.url}`);
      const body =
        path === previewPath
          ? {
              id: "cnv_panel",
              group_id: "grp_panel",
              kind: "agent_task",
              title: "Prepare Friday's product launch",
              status,
              activity_status: "idle",
              freshness: { state: "fresh" },
              updated_at: 1790100000,
              origin: "telegram",
              labels: ["lbl_launch"],
              bound_worker: {
                participant_id: "ptp_worker",
                actor_id: "actor_worker",
                name: "Mira",
              },
            }
          : path === "/v1/comma/groups/grp_panel/task-labels"
            ? {
                labels: [{ id: "lbl_launch", name: "Launch", color: "blue" }],
                colors: [],
                proposals: [],
              }
            : undefined;
      if (!body) return false;
      response.writeHead(forbidden ? 404 : 200, { "content-type": "application/json" });
      response.end(JSON.stringify(forbidden ? { error: "not_found" } : body));
      return true;
    },
  });

  try {
    await page.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      // Embedded browsers need no SharedWorker to read this auxiliary page.
      Object.defineProperty(window, "SharedWorker", { value: undefined });
    }, stub.baseUrl);
    await page.setViewportSize({ width: 390, height: 740 });
    await page.goto(`/task-panel.html?${target}`);
    await expect(
      page.getByRole("heading", { name: "Prepare Friday's product launch" })
    ).toBeVisible();
    const details = page.getByRole("complementary", { name: "Task details" });
    await expect(details.getByText("Mira", { exact: true })).toBeVisible();
    await expect(details.getByText("Launch", { exact: true })).toBeVisible();
    await expect(details.getByText("Telegram", { exact: true })).toBeVisible();
    await expect(page.getByRole("textbox")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Done", exact: true })).toHaveCount(
      0
    );
    await expect(page.getByRole("button", { name: "Add label" })).toHaveCount(0);
    await expect(
      page.getByText("Continue the conversation in your chat.")
    ).toBeVisible();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth)
    ).toBeLessThanOrEqual(390);
    await page.screenshot({ path: "/tmp/comma-task-panel-mobile.png" });

    status = "ready_for_review";
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await expect(details.getByTestId("task-conversation-status")).toContainText(
      "Needs Review"
    );
    await expect(page.getByRole("button", { name: "Done", exact: true })).toHaveCount(
      0
    );
    await page.setViewportSize({ width: 920, height: 740 });
    await page.screenshot({ path: "/tmp/comma-task-panel-wide.png" });

    forbidden = true;
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await expect(page.getByRole("alert")).toContainText("Task unavailable");
    await expect(details).toHaveCount(0);
    await expect(page.getByText("Mira", { exact: true })).toHaveCount(0);
    // Opening and refreshing this page must not provision Home or touch a transcript.
    expect(
      requests.every(
        (request) =>
          request === `GET ${previewPath}?include_worker=true` ||
          request === "GET /v1/comma/groups/grp_panel/task-labels"
      )
    ).toBe(true);
  } finally {
    await stub.close();
  }
});

test("unsigned Telegram launch data cannot skip Comma sign-in", async ({ page }) => {
  const stub = await startSessionProjectionStub({ email: "signed-out@comma.local" });
  const productReads: string[] = [];
  try {
    await page.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      Object.defineProperty(window, "Telegram", {
        value: { WebApp: { initDataUnsafe: { user: { id: 42001 } } } },
      });
    }, stub.baseUrl);
    await page.route(`${stub.baseUrl}/v1/comma/auth/session`, (route) =>
      route.fulfill({
        status: 401,
        contentType: "application/json",
        body: '{"error":"unauthorized"}',
        headers: {
          "access-control-allow-origin": new URL(page.url()).origin,
          "access-control-allow-credentials": "true",
        },
      })
    );
    page.on("request", (request) => {
      if (request.url().includes("/v1/comma/groups/")) productReads.push(request.url());
    });
    await page.goto(`/task-panel.html?${target}&source=telegram`);
    await expect(page.getByRole("textbox", { name: /email/i })).toBeVisible();
    expect(productReads).toEqual([]);
  } finally {
    await stub.close();
  }
});

test("Telegram Mini App reopens after its short session expires", async ({ page }) => {
  const requests: string[] = [];
  let sessionId = "panel-first";
  const projection = () =>
    createE2eSessionProjection({ email: "telegram-panel@comma.local", sessionId });
  const stub = await startSessionProjectionStub({
    email: "telegram-panel@comma.local",
    handleRequest(request, response, path) {
      requests.push(`${request.method} ${path}`);
      if (request.method === "POST" && path === "/v1/comma/auth/telegram-miniapp") {
        response.writeHead(201, { "content-type": "application/json" });
        response.end(JSON.stringify(projection()));
        return true;
      }
      if (request.method === "GET" && path === previewPath) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(
          JSON.stringify({
            id: "cnv_panel",
            group_id: "grp_panel",
            kind: "agent_task",
            title: "Verified Telegram Task",
            status: "active",
            activity_status: "idle",
            freshness: { state: "fresh" },
            updated_at: 1790100000,
            origin: "telegram",
            labels: [],
          })
        );
        return true;
      }
      if (
        request.method === "GET" &&
        path === "/v1/comma/groups/grp_panel/task-labels"
      ) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ labels: [], colors: [], proposals: [] }));
        return true;
      }
      return false;
    },
  });

  const { promise: stylesHeld, resolve: releaseStyles } = Promise.withResolvers<void>();
  await page.route("**/*.css", async (route) => {
    await stylesHeld;
    await route.continue();
  });
  try {
    await page.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      Object.defineProperty(window, "SharedWorker", { value: undefined });
      Object.defineProperty(window, "Telegram", {
        value: { WebApp: { initData: "signed-launch", ready: () => {} } },
      });
    }, stub.baseUrl);
    await page.route(stub.baseUrl + "/v1/comma/auth/session", (route) => {
      const expected = route.request().headers()["x-comma-expected-auth-session-id"];
      const matches = expected === "unknown" || expected === sessionId;
      return route.fulfill({
        status: matches ? 200 : 409,
        json: matches ? projection() : { error: "session_changed" },
      });
    });
    await page.goto(`/task-panel.html?${target}&source=telegram`, {
      waitUntil: "commit",
    });
    await expect.poll(() => requests).toContain("POST /v1/comma/auth/telegram-miniapp");
    expect(requests).not.toContain(`GET ${previewPath}`);
    releaseStyles();
    await expect(
      page.getByRole("heading", { name: "Verified Telegram Task" })
    ).toBeVisible();
    sessionId = "panel-renewed";
    await page.reload();
    await expect(
      page.getByRole("heading", { name: "Verified Telegram Task" })
    ).toBeVisible();
    expect(requests[0]).toBe("POST /v1/comma/auth/telegram-miniapp");
    expect(requests).toContain(`GET ${previewPath}`);
  } finally {
    releaseStyles();
    await stub.close();
  }
});

test("a focused peer finishes checking its session when Telegram renews in another tab", async ({
  page,
  context,
}) => {
  let sessionId = "panel-original";
  const projection = () =>
    createE2eSessionProjection({ email: "peer-panel@comma.local", sessionId });
  const { promise: exchangeHeld, resolve: releaseExchange } =
    Promise.withResolvers<void>();
  const { promise: exchangeStarted, resolve: markExchangeStarted } =
    Promise.withResolvers<void>();
  const { promise: probeHeld, resolve: releaseProbe } = Promise.withResolvers<void>();
  const { promise: probeStarted, resolve: markProbeStarted } =
    Promise.withResolvers<void>();
  const stub = await startSessionProjectionStub({
    email: "peer-panel@comma.local",
    sessionId,
    handleRequest(request, response, path) {
      if (path === previewPath) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(
          JSON.stringify({
            id: "cnv_panel",
            group_id: "grp_panel",
            kind: "agent_task",
            title: "Shared Telegram Task",
            status: "active",
            activity_status: "idle",
            freshness: { state: "fresh" },
            updated_at: 1790100000,
            origin: "telegram",
            labels: [],
          })
        );
        return true;
      }
      if (path === "/v1/comma/groups/grp_panel/task-labels") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ labels: [], colors: [], proposals: [] }));
        return true;
      }
      return false;
    },
  });
  const heading = page.getByRole("heading", { name: "Shared Telegram Task" });
  try {
    await context.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      Object.defineProperty(window, "Telegram", {
        value: { WebApp: { initData: "signed-launch", ready: () => {} } },
      });
    }, stub.baseUrl);
    // Observe real BroadcastChannel delivery without changing its timing or payload.
    await page.addInitScript(() => {
      const NativeChannel = window.BroadcastChannel;
      window.BroadcastChannel = class extends NativeChannel {
        constructor(name: string) {
          super(name);
          this.addEventListener("message", () => {
            document.documentElement.dataset.sessionHintReceived = "true";
          });
        }
      };
    });
    await context.route("https://telegram.org/js/telegram-web-app.js?63", (route) =>
      route.fulfill({ status: 200, contentType: "application/javascript", body: "" })
    );
    await context.route(
      `${stub.baseUrl}/v1/comma/auth/telegram-miniapp`,
      async (route) => {
        markExchangeStarted();
        await exchangeHeld;
        sessionId = "panel-renewed";
        await route.fulfill({ status: 201, json: projection() });
      }
    );
    await context.route(`${stub.baseUrl}/v1/comma/auth/session`, async (route) => {
      if (sessionId === "panel-renewed" && route.request().frame().page() === page) {
        markProbeStarted();
        await probeHeld;
      }
      const expected = route.request().headers()["x-comma-expected-auth-session-id"];
      const matches = expected === "unknown" || expected === sessionId;
      await route.fulfill({
        status: matches ? 200 : 409,
        json: matches ? projection() : { error: "session_changed" },
      });
    });
    await page.goto(`/task-panel.html?${target}`);
    await expect(heading).toBeVisible();
    const renewedPage = await context.newPage();
    await renewedPage.goto(`/task-panel.html?${target}&source=telegram`);
    await exchangeStarted;
    await page.bringToFront();
    await page.evaluate(() => {
      window.dispatchEvent(new Event("focus"));
      document.dispatchEvent(new Event("visibilitychange"));
    });
    releaseExchange();
    await probeStarted;
    await expect(heading).toBeVisible();
    await expect(page.locator("html")).toHaveAttribute(
      "data-session-hint-received",
      "true"
    );
    await expect(
      renewedPage.getByRole("heading", { name: "Shared Telegram Task" })
    ).toBeVisible();
    releaseProbe();
    await expect(heading).toBeVisible();
    await expect(page.getByText("Checking your session…", { exact: true })).toHaveCount(
      0
    );
  } finally {
    releaseExchange();
    releaseProbe();
    await stub.close();
  }
});

test("Telegram Web iframe keeps its restricted Task session across requests", async ({
  page,
  baseURL,
}) => {
  const panelCookie = "comma_panel_session=iframe-panel-session";
  const readCookies: string[] = [];
  const api = createServer((request, response) => {
    const origin = request.headers.origin ?? "*";
    response.setHeader("access-control-allow-origin", origin);
    response.setHeader("access-control-allow-credentials", "true");
    response.setHeader(
      "access-control-allow-headers",
      request.headers["access-control-request-headers"] ?? "content-type"
    );
    response.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
    if (request.method === "OPTIONS") {
      response.writeHead(204).end();
      return;
    }

    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    if (path === "/v1/comma/auth/telegram-miniapp" && request.method === "POST") {
      response.setHeader(
        "set-cookie",
        `${panelCookie}; HttpOnly; Secure; SameSite=None; Partitioned; Path=/`
      );
      response.writeHead(201, { "content-type": "application/json" });
      response.end(
        JSON.stringify(
          createE2eSessionProjection({
            email: "panel@comma.local",
            userId: "telegram-user",
            sessionId: "iframe-panel-session",
          })
        )
      );
      return;
    }

    const hasPanelCookie = request.headers.cookie?.includes(panelCookie) ?? false;
    if (path === "/v1/comma/auth/session" || path.startsWith("/v1/comma/groups/")) {
      readCookies.push(request.headers.cookie ?? "");
      const status = hasPanelCookie ? 200 : 401;
      const body =
        path === "/v1/comma/auth/session"
          ? {
              session_id: "iframe-panel-session",
              expires_at: 4_102_444_800,
              user: {
                id: "telegram-user",
                email: "panel@comma.local",
                status: "active",
              },
            }
          : path === previewPath
            ? {
                id: "cnv_panel",
                group_id: "grp_panel",
                kind: "agent_task",
                title: "Iframe Telegram Task",
                status: "active",
                activity_status: "idle",
                freshness: { state: "fresh" },
                updated_at: 1790100000,
                origin: "telegram",
                labels: [],
              }
            : { labels: [], colors: [], proposals: [] };
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(hasPanelCookie ? body : { error: "unauthorized" }));
      return;
    }

    response.writeHead(404).end();
  });
  await new Promise<void>((resolve) => api.listen(0, "127.0.0.1", resolve));
  const apiPort = (api.address() as AddressInfo).port;
  const host = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html" });
    response.end(
      `<iframe src="${baseURL}/task-panel.html?${target}&source=telegram"></iframe>`
    );
  });
  await new Promise<void>((resolve) => host.listen(0, "localhost", resolve));
  const hostPort = (host.address() as AddressInfo).port;

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
      Object.defineProperty(window, "SharedWorker", { value: undefined });
      Object.defineProperty(window, "Telegram", {
        value: { WebApp: { initData: "signed-launch", ready: () => {} } },
      });
    }, `http://127.0.0.1:${apiPort}`);
    await page.goto(`http://localhost:${hostPort}/`);
    await expect(
      page.frameLocator("iframe").getByRole("heading", { name: "Iframe Telegram Task" })
    ).toBeVisible();
    expect(readCookies.some((cookie) => cookie.includes(panelCookie))).toBe(true);
  } finally {
    await Promise.all([
      new Promise<void>((resolve) => api.close(() => resolve())),
      new Promise<void>((resolve) => host.close(() => resolve())),
    ]);
  }
});

for (const failure of [
  {
    status: 401,
    heading: "Telegram sign-in could not be verified",
    action: "Sign in with Comma",
  },
  {
    status: 409,
    heading: "A different Comma account is signed in",
    action: "Open Comma",
  },
] as const) {
  test(`${failure.status} Telegram Mini App launch does not read Task data`, async ({
    page,
  }) => {
    const requests: string[] = [];
    const stub = await startSessionProjectionStub({
      email: "telegram-panel@comma.local",
      handleRequest(request, response, path) {
        requests.push(`${request.method} ${path}`);
        if (request.method === "POST" && path === "/v1/comma/auth/telegram-miniapp") {
          response.writeHead(failure.status, { "content-type": "application/json" });
          response.end('{"error":"invalid_telegram_miniapp_login"}');
          return true;
        }
        return false;
      },
    });

    try {
      await page.addInitScript((baseUrl) => {
        localStorage.setItem("comma.apiBaseUrl", baseUrl);
        Object.defineProperty(window, "SharedWorker", { value: undefined });
        Object.defineProperty(window, "Telegram", {
          value: { WebApp: { initData: "launch-data", ready: () => {} } },
        });
      }, stub.baseUrl);
      await page.goto(`/task-panel.html?${target}&source=telegram`);
      await expect(page.getByRole("heading", { name: failure.heading })).toBeVisible();
      await expect(page.getByText(failure.action, { exact: true })).toBeVisible();
      expect(requests).toEqual(["POST /v1/comma/auth/telegram-miniapp"]);
    } finally {
      await stub.close();
    }
  });
}

test("the Telegram Task list opens a bounded, read-only conversation from the same Task", async ({
  page,
}) => {
  const requests: string[] = [];
  const stub = await startSessionProjectionStub({
    email: "task-list@comma.local",
    handleRequest(request, response, path) {
      requests.push(`${request.method} ${request.url}`);
      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      let body: unknown;
      if (path === "/v1/comma/groups/grp_panel/conversations") {
        body = url.searchParams.get("cursor")
          ? {
              data: [
                {
                  id: "cnv_comma",
                  group_id: "grp_panel",
                  kind: "agent_task",
                  title: "Comma follow-up",
                  status: "completed",
                  updated_at: 1790100002,
                  origin: "comma",
                },
              ],
              has_more: false,
            }
          : {
              data: [
                {
                  id: "cnv_router",
                  group_id: "grp_panel",
                  kind: "user_chat",
                  title: "Private router chat",
                  status: "active",
                  updated_at: 1790100000,
                },
                {
                  id: "cnv_tg",
                  group_id: "grp_panel",
                  kind: "agent_task",
                  title: "Telegram launch",
                  status: "ready_for_review",
                  updated_at: 1790100000,
                  origin: "telegram",
                },
                {
                  id: "cnv_slack",
                  group_id: "grp_panel",
                  kind: "agent_task",
                  title: "Slack report",
                  status: "active",
                  updated_at: 1790100001,
                  freshness: { state: "fresh" },
                  origin: "slack",
                },
              ],
              has_more: true,
              next_cursor: "next-page",
            };
      } else if (
        path === "/v1/comma/groups/grp_panel/conversations/cnv_slack/preview"
      ) {
        body = {
          id: "cnv_slack",
          group_id: "grp_panel",
          kind: "agent_task",
          title: "Slack report",
          status: "active",
          activity_status: "idle",
          freshness: { state: "fresh" },
          updated_at: 1790100001,
          origin: "slack",
          labels: [],
          bound_worker: {
            participant_id: "worker_slack",
            actor_id: "actor_slack",
            name: "Mira",
          },
        };
      } else if (path === "/v1/comma/groups/grp_panel/conversations/cnv_slack") {
        body = {
          id: "cnv_slack",
          group_id: "grp_panel",
          kind: "agent_task",
          title: "Slack report",
          status: "active",
          updated_at: 1790100001,
          messages: [
            {
              actor_type: "user",
              content: [{ type: "text", text: "Please check the report from Slack" }],
              created_at: 1790100000,
              kind: "message",
              message_id: "slack-user",
              user_id: "user-1",
            },
            {
              actor_type: "agent",
              content: [{ type: "text", text: "Comma follow-up on the same Task" }],
              created_at: 1790100001,
              kind: "message",
              message_id: "comma-agent",
              agent_id: "worker-1",
            },
          ],
        };
      } else if (path === "/v1/comma/groups/grp_panel/task-labels") {
        body = { labels: [], colors: [], proposals: [] };
      }
      if (!body) return false;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
      return true;
    },
  });

  try {
    await page.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      Object.defineProperty(window, "SharedWorker", { value: undefined });
    }, stub.baseUrl);
    await page.setViewportSize({ width: 390, height: 740 });
    await page.goto("/task-panel.html?group_id=grp_panel&workspace_id=ws_panel");
    await expect(page.getByRole("button", { name: "Telegram launch" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Slack report" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Private router chat" })).toHaveCount(
      0
    );
    await page.screenshot({ path: "/tmp/comma-task-panel-list-mobile.png" });
    await page.getByRole("button", { name: "Needs Review" }).click();
    await expect(page.getByRole("button", { name: "Telegram launch" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Slack report" })).toHaveCount(0);
    await page.getByRole("button", { name: "All tasks" }).click();
    await page.getByRole("button", { name: "Load more" }).click();
    await expect(page.getByRole("button", { name: "Comma follow-up" })).toBeVisible();
    await page.getByRole("button", { name: "Slack report" }).click();
    await expect(
      page.getByRole("complementary", { name: "Task details" })
    ).toContainText("Slack");
    await page.getByRole("button", { name: "View conversation" }).click();
    await expect(page.getByText("Please check the report from Slack")).toBeVisible();
    await expect(page.getByText("Comma follow-up on the same Task")).toBeVisible();
    await expect(page.getByRole("textbox")).toHaveCount(0);
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth)
    ).toBeLessThanOrEqual(390);
    expect(requests).toContain(
      "GET /v1/comma/groups/grp_panel/conversations/cnv_slack?message_limit=20"
    );
    expect(requests.every((request) => request.startsWith("GET "))).toBe(true);

    // A conversation bundle failure must leave Task navigation usable.
    await page.reload();
    await page.getByRole("button", { name: "Slack report" }).click();
    await expect(
      page.getByRole("complementary", { name: "Task details" })
    ).toBeVisible();
    await page.route("**/assets/*.js", (route) => route.abort());
    await page.getByRole("button", { name: "View conversation" }).click();
    await expect(page.getByRole("alert")).toBeVisible();
    await page.getByRole("button", { name: "Task details", exact: true }).click();
    await expect(
      page.getByRole("complementary", { name: "Task details" })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("Task panel shows progress while the Telegram SDK is loading", async ({
  page,
}) => {
  await page.route("https://telegram.org/js/telegram-web-app.js?63", () => {});
  await page.goto("/task-panel.html?" + target + "&source=telegram", {
    waitUntil: "domcontentloaded",
  });
  await expect(page.getByRole("status")).toContainText("Opening Task panel", {
    timeout: 2000,
  });
  await page.screenshot({ path: "/tmp/comma-task-panel-startup.png" });
});

test("Task panel shows progress before its JavaScript downloads", async ({ page }) => {
  await page.route("**/assets/*.js", () => {});
  const sdkRequest = page.waitForRequest(
    "https://telegram.org/js/telegram-web-app.js?63"
  );
  await page.goto(`/task-panel.html?${target}&source=telegram`, {
    waitUntil: "commit",
  });
  await expect(page.getByRole("status")).toContainText("Opening Task panel");
  await sdkRequest;
});

test("Task startup paints before the full stylesheet arrives", async ({ page }) => {
  await page.route("**/*.css", () => {});
  await page.goto(`/task-panel.html?${target}&source=telegram`, {
    waitUntil: "commit",
  });
  await expect
    .poll(
      () =>
        page.evaluate(
          () => performance.getEntriesByName("first-contentful-paint").length
        ),
      { timeout: 2000 }
    )
    .toBeGreaterThan(0);
  await expect(page.getByRole("status")).toContainText("Opening Task panel");
});

test("Task panel offers reload when its view cannot download", async ({ page }) => {
  await page.route("**/assets/task-panel-view-*.js", (route) => route.abort());
  await page.goto(`/task-panel.html?${target}`);
  await expect(page.getByRole("status")).toContainText("Task panel could not load");
  await expect(page.getByRole("button", { name: "Reload", exact: true })).toBeVisible();
});

test("Telegram's dark scheme and back button drive the Task panel chrome", async ({
  page,
}) => {
  const task = {
    id: "cnv_panel",
    group_id: "grp_panel",
    kind: "agent_task",
    title: "Night shift Task",
    status: "active",
    activity_status: "idle",
    freshness: { state: "fresh" },
    updated_at: 1790100000,
    origin: "telegram",
    labels: [],
  };
  let listReads = 0;
  const stub = await startSessionProjectionStub({
    email: "telegram-dark@comma.local",
    handleRequest(request, response, path) {
      if (path === "/v1/comma/groups/grp_panel/conversations") listReads += 1;
      const body =
        request.method === "POST" && path === "/v1/comma/auth/telegram-miniapp"
          ? createE2eSessionProjection({ email: "telegram-dark@comma.local" })
          : path === "/v1/comma/groups/grp_panel/conversations"
            ? { data: [task], has_more: false }
            : path === previewPath
              ? task
              : path === "/v1/comma/groups/grp_panel/task-labels"
                ? { labels: [], colors: [], proposals: [] }
                : undefined;
      if (!body) return false;
      response.writeHead(request.method === "POST" ? 201 : 200, {
        "content-type": "application/json",
      });
      response.end(JSON.stringify(body));
      return true;
    },
  });
  try {
    await page.addInitScript((baseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", baseUrl);
      Object.defineProperty(window, "SharedWorker", { value: undefined });
      const calls: string[] = [];
      let backHandler: (() => void) | undefined;
      Object.assign(window, {
        telegramCalls: calls,
        pressTelegramBack: () => backHandler?.(),
      });
      Object.defineProperty(window, "Telegram", {
        value: {
          WebApp: {
            initData: "signed-launch",
            colorScheme: "dark",
            ready: () => {},
            isVersionAtLeast: () => true,
            onEvent: () => {},
            setBackgroundColor: (color: string) => calls.push(`background ${color}`),
            setHeaderColor: (color: string) => calls.push(`header ${color}`),
            HapticFeedback: { selectionChanged: () => calls.push("haptic selection") },
            BackButton: {
              show: () => calls.push("back show"),
              hide: () => calls.push("back hide"),
              onClick: (callback: () => void) => {
                backHandler = callback;
              },
              offClick: () => {
                backHandler = undefined;
              },
            },
          },
        },
      });
    }, stub.baseUrl);
    const calls = () =>
      page.evaluate(
        () => (window as unknown as { telegramCalls: string[] }).telegramCalls
      );
    await page.goto(
      "/task-panel.html?group_id=grp_panel&workspace_id=wsp_panel&source=telegram"
    );
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    // Telegram's header takes the panel's dark background, not a light default.
    await expect
      .poll(async () => {
        const header = (await calls()).findLast((call) => call.startsWith("header "));
        if (!header) return 255;
        const hex = header.slice("header #".length);
        return Math.max(...[0, 2, 4].map((at) => parseInt(hex.slice(at, at + 2), 16)));
      })
      .toBeLessThan(64);

    // Changing the status filter gives the device's selection tick.
    await page.getByRole("button", { name: "In progress" }).click();
    expect(await calls()).toContain("haptic selection");
    await page.getByRole("button", { name: "All tasks" }).click();

    await page.getByRole("button", { name: "Night shift Task" }).click();
    await expect(page.getByRole("heading", { name: "Night shift Task" })).toBeVisible();
    expect(await calls()).toContain("back show");
    // Telegram's own back control replaces the in-page one.
    await expect(page.getByRole("button", { name: "All tasks" })).toHaveCount(0);
    // Deeper work continues in Comma Web on the same Task.
    const openInComma = page.getByRole("link", { name: "Open in Comma Web" });
    await expect(openInComma).toHaveAttribute(
      "href",
      new URL("/#/tasks/wsp_panel/grp_panel/cnv_panel", page.url()).href
    );

    await page.evaluate(() =>
      (window as unknown as { pressTelegramBack: () => void }).pressTelegramBack()
    );
    await expect(page.getByRole("button", { name: "Night shift Task" })).toBeVisible();
    expect((await calls()).at(-1)).toBe("back hide");
    // Returning shows the list already loaded instead of fetching it again.
    expect(listReads).toBe(1);
    // The host scheme is shown without replacing the reader's stored Comma theme.
    expect(
      await page.evaluate(() => JSON.stringify({ ...localStorage }))
    ).not.toContain('\\"theme\\":\\"dark\\"');
  } finally {
    await stub.close();
  }
});
