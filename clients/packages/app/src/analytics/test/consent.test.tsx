import { gunzipSync } from "node:zlib";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";

// The real PostHog SDK, with its requests answered here: what the switch
// in Settings changes is what reaches the network.
const posthogHost = "https://posthog.comma.test";

const signedIn: SessionLifecycleSnapshot = {
  authority: { authorityInstanceId: "test", kind: "electron_main" },
  contractVersion: 1,
  generation: 1,
  revision: 1,
  cleanup: { revocation: "idle" },
  phase: "signed_in",
  principal: { userId: "analytics-user", email: "private@example.com" },
  session: {
    audience: "https://comma.test",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "secret-session-id",
  },
};

// The bodies PostHog received, read as event names by `sent()`.
const bodies: Promise<string[]>[] = [];
const sent = async () => (await Promise.all(bodies)).flat();

async function bodyEvents(body: BodyInit | null | undefined): Promise<string[]> {
  if (body == null) return [];
  let bytes = Buffer.from(await new Response(body).arrayBuffer());
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes);
  const data = JSON.parse(bytes.toString());
  const batch: { event: string }[] = Array.isArray(data)
    ? data
    : (data.batch ?? [data]);
  return batch.map((event) => event.event);
}

let analytics: typeof import("../client");

beforeEach(async () => {
  localStorage.clear();
  bodies.length = 0;
  vi.stubGlobal("COMMA_DEFINED_POSTHOG_KEY", "phc_test");
  vi.stubGlobal("COMMA_DEFINED_POSTHOG_HOST", posthogHost);
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url.startsWith(posthogHost)) bodies.push(bodyEvents(init?.body));
      return new Response("{}", { status: 200 });
    })
  );
  // Without the browser's async gzip the SDK compresses as it sends, so each
  // request is made within the timer that sends it.
  vi.stubGlobal("CompressionStream", undefined);
  // The SDK keeps the fetch it finds when it loads: load it after the stubs.
  vi.resetModules();
  analytics = await import("../client");
  window.history.replaceState(null, "", "/#/");
});

let dispose = () => {};
afterEach(() => {
  dispose();
  vi.unstubAllGlobals();
});

function start(enabled: boolean) {
  dispose = analytics.startCommaAnalytics({
    enabled,
    runtime: "web",
    lifecycle: { getSnapshotSync: () => signedIn, subscribe: () => () => {} },
  });
}

// Longer than any of the SDK's timers, with its compression and fetch settled.
const flush = () => vi.advanceTimersByTimeAsync(10_000);

it("sends nothing while the setting is off, from launch or from the moment it is switched off", async () => {
  const { captureCommaPageView, reportCommaClientError, setCommaAnalyticsEnabled } =
    analytics;
  // Off at launch: the SDK is not started and nothing is sent.
  start(false);
  await flush();
  expect(await sent()).toEqual([]);
  expect(localStorage.length).toBe(0);

  // On: the window's open reaches PostHog.
  setCommaAnalyticsEnabled(true);
  await flush();
  expect(await sent()).toContain("comma_client_opened");

  // Off: from that moment nothing leaves, neither an event captured just
  // before nor one captured after, errors included.
  window.history.replaceState(null, "", "/#/settings");
  captureCommaPageView();
  bodies.length = 0;
  setCommaAnalyticsEnabled(false);
  window.history.replaceState(null, "", "/#/inbox");
  captureCommaPageView();
  reportCommaClientError(new Error("after opt-out"), "unhandled_error");
  await flush();
  expect(await sent()).toEqual([]);

  // On again: reporting resumes without a second open.
  setCommaAnalyticsEnabled(true);
  window.history.replaceState(null, "", "/#/tasks");
  captureCommaPageView();
  await flush();
  expect(await sent()).toContain("$pageview");
  expect(await sent()).not.toContain("comma_client_opened");
});
