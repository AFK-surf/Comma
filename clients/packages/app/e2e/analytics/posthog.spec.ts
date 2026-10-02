import { gunzipSync } from "node:zlib";
import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../../e2e/helpers/browser-auth";

type Event = { event: string; properties: Record<string, unknown> };
const apiBaseUrl = "http://127.0.0.1:65534";

async function captureEvents(
  page: Page,
  offline = false,
  deferInitialPageview = false
) {
  // The SDK excludes webdriver and HeadlessChrome client hints. Exercise normal-browser
  // ingestion without disabling the production bot filter.
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => false });
    Object.defineProperty(navigator, "userAgentData", { get: () => undefined });
  });
  const events: Event[] = [];
  const requests: string[] = [];
  let initialPageviewHeld!: () => void;
  const waitForInitialPageview = new Promise<void>((complete) => {
    initialPageviewHeld = complete;
  });
  let releaseInitialPageview!: () => void;
  const initialPageviewReleased = new Promise<void>((complete) => {
    releaseInitialPageview = complete;
  });
  await page.route("https://posthog.comma.test/**", async (route) => {
    const request = route.request();
    requests.push(request.url());
    if (offline) {
      await route.abort();
      return;
    }
    let body = request.postDataBuffer();
    if (body?.length) {
      if (body[0] === 0x1f && body[1] === 0x8b) body = gunzipSync(body);
      const data = JSON.parse(body.toString());
      const batch: Event[] = Array.isArray(data) ? data : (data.batch ?? [data]);
      if (
        deferInitialPageview &&
        batch.some(
          (event) =>
            event.event === "$pageview" && event.properties.route === "/settings"
        )
      ) {
        initialPageviewHeld();
        await initialPageviewReleased;
      }
      events.push(...batch);
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ status: 1 }),
      headers: { "access-control-allow-origin": "*" },
    });
  });
  return { events, requests, waitForInitialPageview, releaseInitialPageview };
}

const privateProfile = {
  id: "analytics-user",
  email: "private@example.com",
  name: "Private Person",
  avatar_id: null,
  locale: "en",
};

function fulfillApi(route: Route, body: unknown) {
  const origin = route.request().headers().origin ?? "http://127.0.0.1:4187";
  return route.fulfill({
    status: route.request().method() === "OPTIONS" ? 204 : 200,
    headers: {
      "access-control-allow-origin": origin,
      "access-control-allow-credentials": "true",
      "access-control-allow-headers": "content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "content-type": "application/json",
    },
    body: route.request().method() === "OPTIONS" ? "" : JSON.stringify(body),
  });
}

async function installSession(page: Page) {
  await page.route(`${apiBaseUrl}/v1/**`, (route) => fulfillApi(route, { data: [] }));
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "private@example.com",
    token: "comma_sess_private",
    userId: "analytics-user",
  });
  // The session helper serves the profile from a reachable backend only. This
  // backend is the page's routes, so the profile route goes last and wins.
  await page.route(`${apiBaseUrl}/v1/comma/me/profile`, (route) =>
    fulfillApi(route, privateProfile)
  );
}

for (const deferInitialPageview of [false, true]) {
  test(`the real SDK sends sanitized routes and identity, without automatic DOM capture${deferInitialPageview ? " when initial ingestion arrives last" : ""}`, async ({
    page,
  }) => {
    let documentRequests = 0;
    page.on("request", (request) => {
      if (
        request.isNavigationRequest() &&
        request.frame() === page.mainFrame() &&
        request.resourceType() === "document"
      )
        documentRequests++;
    });
    const { events, requests, waitForInitialPageview, releaseInitialPageview } =
      await captureEvents(page, false, deferInitialPageview);
    await installSession(page);
    await page.goto("/?private_query=private-value#/settings");
    await page.getByRole("button", { name: "Profile", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Edit name: Private Person" })
    ).toBeVisible();
    await expect
      .poll(() => ({ events: events.map((event) => event.event), requests }))
      .toMatchObject({ events: expect.arrayContaining(["$identify"]) });
    expect(
      events.find((event) => event.event === "$identify")?.properties.distinct_id
    ).toBe("analytics-user");

    // SDK batches are independent requests. Keep one actual initial batch in flight
    // while the next navigation is captured, without replacing or flushing the SDK.
    if (deferInitialPageview) await waitForInitialPageview;

    await page.evaluate(() => {
      location.hash =
        "/tasks/workspace-private/group-private/conversation-private?text=private-value";
    });
    await expect
      .poll(() =>
        events.some(
          (event) =>
            event.event === "$pageview" &&
            event.properties.route === "/tasks/:workspaceId/:groupId/:conversationId"
        )
      )
      .toBe(true);
    releaseInitialPageview();
    await expect
      .poll(() =>
        events.filter(
          (event) =>
            event.event === "$pageview" && event.properties.route === "/settings"
        )
      )
      .toHaveLength(1);
    expect(documentRequests).toBe(1);
    const payload = JSON.stringify(events);
    for (const event of events) {
      expect(event.properties).toMatchObject({
        runtime: "web",
        channel: "dev",
        window_role: "main-window",
        app_version: "0.0.1",
        build_sha: expect.stringMatching(/^[a-f0-9]{40}$/),
      });
    }
    for (const privateValue of [
      "private@example.com",
      "Private Person",
      "private-value",
      "workspace-private",
      "group-private",
      "conversation-private",
      "comma_sess_private",
    ]) {
      expect(payload).not.toContain(privateValue);
    }
    expect(
      events.some((event) =>
        ["$autocapture", "$snapshot", "$exception"].includes(event.event)
      )
    ).toBe(false);
    expect(requests.some((url) => /flags|config|record/.test(url))).toBe(false);
  });
}

test("real SDK exceptions are redacted, readiness is emitted once, and a fatal React error is critical", async ({
  page,
}) => {
  const { events } = await captureEvents(page);
  await installSession(page);
  await page.goto("/#/settings");
  await expect
    .poll(() => events.filter(({ event }) => event === "comma_client_ready").length)
    .toBe(1);
  await page.evaluate(async (fixtureUrl) => {
    const { crashRenderer } = await import(fixtureUrl);
    crashRenderer();
  }, "/assets/fatal-fixture.js");
  await expect
    .poll(() => events.filter(({ event }) => event === "$exception").length)
    .toBe(1);
  const exception = events.find(({ event }) => event === "$exception")!;
  expect(exception.properties).toMatchObject({
    error_kind: "react_uncaught",
    severity: "critical",
    distinct_id: "analytics-user",
  });
  expect(JSON.stringify(exception)).not.toContain("private");
  expect(JSON.stringify(exception)).not.toContain("comma_sess_secret");
  expect(exception.properties.$exception_list).toMatchObject([
    {
      type: "TypeError",
      stacktrace: {
        type: "raw",
        frames: [
          {
            platform: "web:javascript",
            function: "redacted",
            filename: "comma://assets/index-abc123.js",
            lineno: 42,
            colno: 7,
          },
        ],
      },
    },
  ]);
});

test("the app remains usable when PostHog is unreachable", async ({ page }) => {
  await captureEvents(page, true);
  await installSession(page);
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Edit name: Private Person" })
  ).toBeVisible();
});
