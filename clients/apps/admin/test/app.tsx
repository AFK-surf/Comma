// The whole Admin app in a test: its real services over a fake `fetch` (test/http.ts), a fake Google button and a
// TestClock.
import { render as renderDom } from "@comma/test-utils/render";
import { Effect, Layer, ManagedRuntime } from "effect";
import { TestClock } from "effect/testing";
import { AdminApp } from "../src/AdminApp";
import { AdminBrowser } from "../src/adminBrowser";
import { adminServices } from "../src/adminLayer";
import { AdminRuntimeProvider } from "../src/adminRuntime";
import { AdminAuth, GoogleIdentity } from "../src/auth";
import { fakeFetchLayer, jsonResponse, type FakeFetch } from "./http";
import { onTestFinished } from "vitest";
import { fakeBrowser, settle, onTestClock } from "./support";

export const adminTestApiBaseUrl = "http://127.0.0.1:4200";
export const adminTestSessionId = "11111111-1111-4111-8111-111111111111";

/** The session the auth endpoints answer with, for `email`. */
export function adminTestSession(email = "owner@example.com") {
  return jsonResponse({
    expires_at: 4_102_444_800,
    session_id: adminTestSessionId,
    user: { email, id: "usr_admin", status: "active" },
  });
}

/**
 * The whole Admin app over `fetch`: the real services, with the session endpoints answered here (signed in as
 * `email` unless `signedIn` is false) and every other request given to `fetch`. Google's button is a plain button
 * that returns `googleCredential`. The Clock is a TestClock.
 */
export async function mountAdminApp(
  fetch: FakeFetch,
  options: {
    auth?: (path: string, body: unknown) => Response | undefined;
    email?: string;
    googleCredential?: string;
    signedIn?: boolean;
  } = {}
) {
  const email = options.email ?? "owner@example.com";
  let signedIn = options.signedIn ?? true;
  const authRequests: Array<{
    body: unknown;
    expected: string | undefined;
    path: string;
  }> = [];
  const session = () => adminTestSession(email);
  const routed: FakeFetch = async (input, init) => {
    const path = new URL(input).pathname;
    if (!path.startsWith("/v1/comma/auth/")) return fetch(input, init);
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    const headers = (init?.headers ?? {}) as Record<string, string>;
    authRequests.push({
      body,
      expected: headers["x-comma-expected-auth-session-id"],
      path,
    });
    const answer = options.auth?.(path, body);
    if (answer) {
      if (answer.ok && path !== "/v1/comma/auth/email/login") signedIn = true;
      return answer;
    }
    switch (path) {
      case "/v1/comma/auth/session":
        return signedIn ? session() : jsonResponse({ error: "unauthorized" }, 401);
      case "/v1/comma/auth/logout":
        signedIn = false;
        return jsonResponse({ signed_out: true });
      case "/v1/comma/auth/google/attempt":
        return options.googleCredential
          ? jsonResponse({
              attempt_id: "google_attempt",
              client_id: "google-client",
              nonce: "google-nonce",
              platform: "web",
            })
          : jsonResponse({ error: "google_unavailable" }, 503);
      case "/v1/comma/auth/google":
        signedIn = true;
        return session();
      default:
        return jsonResponse({ error: "not_found" }, 404);
    }
  };
  const google = GoogleIdentity.of({
    render: ({ element, onCredential }) =>
      Effect.sync(() => {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = "Continue with Google (test)";
        button.addEventListener("click", () => onCredential(options.googleCredential));
        element.replaceChildren(button);
      }),
  });
  const layer = adminServices({
    browser: Layer.succeed(AdminBrowser, fakeBrowser().service),
    fetch: fakeFetchLayer(adminTestApiBaseUrl, routed),
    google: Layer.succeed(GoogleIdentity, google),
  }).pipe(Layer.provideMerge(TestClock.layer()));
  const runtime = ManagedRuntime.make(layer);
  onTestFinished(() => runtime.dispose());
  await onTestClock(runtime.runPromise(Effect.void));
  runtime.runFork(AdminAuth.use((auth) => auth.start));
  const view = renderDom(
    <AdminRuntimeProvider runtime={runtime}>
      <AdminApp apiBaseUrl={adminTestApiBaseUrl} />
    </AdminRuntimeProvider>
  );
  await settle();
  return {
    authRequests,
    runtime,
    view,
    /** Moves the TestClock by `millis`, then lets what is ready run. */
    advance: async (millis: number) => {
      await onTestClock(runtime.runPromise(TestClock.adjust(millis)));
      await settle();
    },
  };
}
