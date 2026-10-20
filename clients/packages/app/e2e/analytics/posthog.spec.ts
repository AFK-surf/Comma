import { gunzipSync } from "node:zlib";
import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../../e2e/helpers/browser-auth";
import {
  apiBaseUrl,
  posthogHost,
  startPosthogCapture,
  type Event,
} from "./posthog-capture";

// The test's PostHog: what the SDK sends reaches it whole, a beacon of a page
// that is leaving included (./posthog-capture.ts).
let capture: Awaited<ReturnType<typeof startPosthogCapture>> | undefined;
test.afterEach(async () => {
  await capture?.close();
  capture = undefined;
});

test("hosted web build joins website first touch without an injected project token", async ({
  page,
}) => {
  const { events } = await captureEvents(page);
  // Different origins have separate localStorage but share the SDK's cookie.
  // Exercise the real website and app entry points, not a replacement SDK fixture.
  await page.goto(
    "http://127.0.0.1:4188/?utm_source=slack&utm_medium=social&utm_campaign=launch&email=private@example.com&utm_content=private-content"
  );
  await expect.poll(() => events.filter((e) => e.event === "$pageview").length).toBe(1);
  const visitor = events[0]!.properties.distinct_id;
  await page.goto(
    "http://127.0.0.1:4188/download?utm_source=overwrite&utm_campaign=overwrite"
  );
  await page.route("**/download/mac", (route) =>
    route.fulfill({ status: 200, body: "download fixture" })
  );
  await page.locator(".download-cta").click();
  // Both events of this page reach the test's PostHog before the test leaves
  // it: the pageview leaves in a beacon of its own as the page goes.
  await expect
    .poll(
      () =>
        events.some((e) => e.event === "comma_website_download_clicked") &&
        events.some(
          (e) => e.event === "$pageview" && e.properties.route === "/download"
        )
    )
    .toBe(true);
  await installSession(page);
  await page.goto("/?utm_source=overwrite#/settings");
  await expect.poll(() => events.some((e) => e.event === "$identify")).toBe(true);
  const identity = events.find((e) => e.event === "$identify")!;
  expect(identity.properties).toMatchObject({
    distinct_id: "analytics-user",
    $anon_distinct_id: visitor,
    token: events[0]!.properties.token,
  });
  expect(identity.$set_once).toMatchObject({
    initial_utm_source: "slack",
    initial_utm_medium: "social",
    initial_utm_campaign: "launch",
    initial_landing_page: "/",
  });
  // A pageview names its own visit's campaign; later visits never replace the
  // first touch, on any event or on the person.
  const download = events.find(
    (e) => e.event === "$pageview" && e.properties.route === "/download"
  )!;
  expect(download.properties).toMatchObject({
    utm_source: "overwrite",
    utm_campaign: "overwrite",
  });
  for (const e of events)
    for (const fields of [e.properties, e.$set_once ?? {}])
      for (const [key, value] of Object.entries(fields))
        if (key.startsWith("initial_")) expect(value).not.toBe("overwrite");
  const serialized = JSON.stringify(events);
  for (const value of ["private@example.com", "private-content", "comma_sess_private"])
    expect(serialized).not.toContain(value);
  // A second account must not inherit the first account's campaign or anonymous ID.
  const other = { ...privateProfile, id: "second-analytics-user" };
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: other.email,
    token: "comma_sess_second",
    userId: other.id,
  });
  await page.route(`${apiBaseUrl}/v1/comma/me/profile`, (route) =>
    fulfillApi(route, other)
  );
  await page.reload();
  await expect.poll(() => events.filter((e) => e.event === "$identify").length).toBe(2);
  const next = events.filter((e) => e.event === "$identify")[1]!;
  expect(next.properties.distinct_id).toBe(other.id);
  expect(next.properties.$anon_distinct_id).not.toBe(visitor);
  expect(next.$set_once).not.toHaveProperty("initial_utm_campaign");
});

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
  capture = await startPosthogCapture();
  const { events, requests } = capture;
  let initialPageviewHeld!: () => void;
  const waitForInitialPageview = new Promise<void>((complete) => {
    initialPageviewHeld = complete;
  });
  let releaseInitialPageview!: () => void;
  const initialPageviewReleased = new Promise<void>((complete) => {
    releaseInitialPageview = complete;
  });
  // The page's side of the SDK's requests: none reach the server when PostHog
  // is unreachable, and the app's first /settings pageview can be held back.
  // Otherwise nothing intercepts them: a beacon the browser sends as its page
  // goes has no page left to continue it from, and an intercepted one is lost.
  if (offline || deferInitialPageview)
    await page.route(`${posthogHost}/**`, async (route) => {
      if (offline) {
        requests.push(route.request().url());
        await route.abort();
        return;
      }
      if (deferInitialPageview) {
        let body = route.request().postDataBuffer();
        if (body?.length) {
          if (body[0] === 0x1f && body[1] === 0x8b) body = gunzipSync(body);
          const data = JSON.parse(body.toString());
          const batch: Event[] = Array.isArray(data) ? data : (data.batch ?? [data]);
          if (
            batch.some(
              (event) =>
                event.event === "$pageview" && event.properties.route === "/settings"
            )
          ) {
            initialPageviewHeld();
            await initialPageviewReleased;
          }
        }
      }
      await route.continue();
    });
  return {
    events,
    requests,
    waitForInitialPageview,
    releaseInitialPageview,
    waitForEvents: capture.waitForEvents,
  };
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
        channel: "prod",
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

test("visible replies reach PostHog with the committed message ID and no conversation content", async ({
  page,
}) => {
  const { events } = await captureEvents(page);
  await installSession(page);
  await page.goto("/#/settings");
  await expect.poll(() => events.some(({ event }) => event === "$identify")).toBe(true);
  await page.evaluate(async (fixtureUrl) => {
    const { showReply } = await import(fixtureUrl);
    showReply();
  }, "/assets/reply-fixture.js");
  await expect
    .poll(
      () => events.filter(({ event }) => event === "comma_reply_first_visible").length
    )
    .toBe(1);
  const reply = events.find(({ event }) => event === "comma_reply_first_visible")!;
  expect(reply.properties).toMatchObject({
    distinct_id: "analytics-user",
    source_message_id: "msg1_1234567890123456789",
    surface: "route",
  });
  expect(JSON.stringify(reply)).not.toContain("private");
});

test("desktop launch observation survives SDK resets without counting renderer reloads", async ({
  page,
}) => {
  const { events, waitForEvents } = await captureEvents(page);
  const start = async (kind: "new_profile" | "version_changed", eventId: string) => {
    await page.evaluate(
      async ({ snapshot, fixtureUrl }) => {
        const { startLaunch } = await import(fixtureUrl);
        startLaunch(snapshot);
      },
      { snapshot: { kind, eventId }, fixtureUrl: "/assets/launch-fixture.js" }
    );
  };
  await page.goto("/launch.html");
  await start("new_profile", "first-main-launch");
  await waitForEvents("comma_desktop_launched", 1);
  await page.reload();
  await start("new_profile", "first-main-launch");
  await waitForEvents("comma_client_opened", 2);
  expect(
    events.filter((event) => event.event === "comma_desktop_launched")
  ).toHaveLength(1);
  await page.reload();
  await start("version_changed", "second-main-launch");
  await waitForEvents("comma_desktop_launched", 2);
  expect(
    events
      .filter((event) => event.event === "comma_desktop_launched")
      .map((event) => event.properties.launch_kind)
  ).toEqual(["new_profile", "version_changed"]);
  expect(JSON.stringify(events)).not.toContain("main-launch");
});
