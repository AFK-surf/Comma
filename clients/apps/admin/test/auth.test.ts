import {
  Deferred,
  Duration,
  Effect,
  Exit,
  Layer,
  ManagedRuntime,
  Queue,
  Stream,
  SubscriptionRef,
} from "effect";
import { TestClock } from "effect/testing";
import { describe, expect, it } from "vitest";
import { fakeTimersStepWhenIdle } from "@comma/test-utils/settle";
import { AdminApi, AdminApiLive } from "../src/adminApi";
import { AdminBrowser } from "../src/adminBrowser";
import { AdminAuth, AdminAuthLive, GoogleIdentity, type AuthState } from "../src/auth";
import { fakeFetchLayer, flush, jsonResponse, type FakeFetch } from "./http";

// The file's timers run on the test's clock, which moves to the next timer
// whenever the test waits.
fakeTimersStepWhenIdle();

const apiBaseUrl = "https://salix.example";
const firstSession = "11111111-1111-4111-8111-111111111111";
const secondSession = "22222222-2222-4222-8222-222222222222";

interface Sent {
  body: unknown;
  credentials: RequestCredentials | undefined;
  expected: string | undefined;
  headers: Record<string, string>;
  method: string;
  path: string;
  signal: AbortSignal | undefined;
}

type Server = (request: Sent) => Response | Promise<Response>;

const sessionOf = (sessionId: string, email = "owner@example.com") =>
  jsonResponse({
    expires_at: 4_102_444_800,
    session_id: sessionId,
    user: { email, id: "usr_owner", status: "active" },
  });
const unauthorized = () => jsonResponse({ error: "unauthorized" }, 401);
const unreachable = () => Promise.reject(new TypeError("Failed to fetch"));
/** A request the server never answers; it rejects when aborted. */
const silent = (request: Sent) =>
  new Promise<Response>((_resolve, reject) => {
    request.signal?.addEventListener("abort", () => reject(request.signal?.reason), {
      once: true,
    });
  });

function authHarness(server: Server) {
  const sent: Sent[] = [];
  let respond = server;
  const fetch: FakeFetch = async (input, init = {}) => {
    const url = new URL(input);
    const headers = { ...(init.headers as Record<string, string>) };
    const request: Sent = {
      body: typeof init.body === "string" ? JSON.parse(init.body) : undefined,
      credentials: init.credentials,
      expected: headers["x-comma-expected-auth-session-id"],
      headers,
      method: init.method ?? "GET",
      path: url.pathname,
      signal: init.signal ?? undefined,
    };
    sent.push(request);
    return respond(request);
  };
  const rendered: Array<{
    clientId: string;
    nonce: string;
    onCredential: (credential: string | undefined) => void;
  }> = [];
  const online = Effect.runSync(Queue.unbounded<void>());
  const browser = AdminBrowser.of({
    copy: () => Effect.void,
    setLocale: () => Effect.void,
    href: Effect.succeed(`${apiBaseUrl}/`),
    narrow: Effect.succeed(false),
    online: Stream.fromQueue(online),
    popstate: Stream.never,
    push: () => Effect.void,
    replaceParams: () => Effect.void,
  });
  const clock = TestClock.layer();
  const http = fakeFetchLayer(apiBaseUrl, fetch);
  const auth = AdminAuthLive.pipe(
    Layer.provide(
      Layer.mergeAll(
        http,
        clock,
        Layer.succeed(AdminBrowser, browser),
        Layer.succeed(
          GoogleIdentity,
          GoogleIdentity.of({
            render: ({ clientId, nonce, onCredential }) =>
              Effect.sync(() => void rendered.push({ clientId, nonce, onCredential })),
          })
        )
      )
    )
  );
  const api = AdminApiLive.pipe(Layer.provide(Layer.merge(http, auth)));
  const runtime = ManagedRuntime.make(Layer.mergeAll(auth, api, clock));
  const service = runtime.runSync(AdminAuth);
  const phases: Array<AuthState["phase"]> = [];
  const states: AuthState[] = [];
  runtime.runFork(
    SubscriptionRef.changes(service.state).pipe(
      Stream.runForEach((state) =>
        Effect.sync(() => {
          // A transition: a new phase, or another lease.
          const last = states.at(-1);
          if (
            last?.phase !== state.phase ||
            (state.phase === "signed_in" &&
              last.phase === "signed_in" &&
              last.lease !== state.lease)
          ) {
            phases.push(state.phase);
          }
          states.push(state);
        })
      )
    )
  );
  const run = async <A, E>(command: Effect.Effect<A, E, AdminApi | AdminAuth>) => {
    const exit = await runtime.runPromiseExit(command);
    await flush();
    return exit;
  };
  return {
    api: runtime.runSync(AdminApi),
    auth: service,
    phases,
    rendered,
    run,
    sent,
    /** Starts `command` without waiting for it. */
    fork: async <A, E>(command: Effect.Effect<A, E, AdminApi | AdminAuth>) => {
      const fiber = runtime.runFork(command);
      await flush();
      return fiber;
    },
    online: async () => {
      Effect.runSync(Queue.offer(online, undefined));
      await flush();
    },
    advance: async (millis: number) => {
      await runtime.runPromise(TestClock.adjust(Duration.millis(millis)));
      await flush();
    },
    serve: (next: Server) => {
      respond = next;
    },
    state: () => SubscriptionRef.getUnsafe(service.state),
  };
}

const signedOutLogin = (state: AuthState) => {
  if (state.phase !== "signed_out")
    throw new Error(`Expected signed_out, got ${state.phase}`);
  return state.login;
};

const leaseOf = (state: AuthState) => {
  if (state.phase !== "signed_in")
    throw new Error(`Expected signed_in, got ${state.phase}`);
  return state.lease;
};

describe("AdminAuth", () => {
  it("reads the Cookie's Session once at startup and makes product requests for it", async () => {
    const admin = authHarness((request) =>
      request.path === "/v1/comma/auth/session"
        ? sessionOf(firstSession)
        : jsonResponse({ data: [], has_more: false, next_cursor: null })
    );

    await admin.run(admin.auth.start);
    await admin.run(admin.auth.start);

    expect(leaseOf(admin.state())).toMatchObject({
      email: "owner@example.com",
      sessionId: firstSession,
      userId: "usr_owner",
    });
    expect(admin.sent).toHaveLength(1);
    expect(admin.sent[0]).toMatchObject({
      credentials: "include",
      expected: "unknown",
      headers: expect.objectContaining({
        accept: "application/json",
        "x-comma-session-lifecycle-version": "1",
        "x-comma-session-transport": "cookie",
      }),
      method: "GET",
      path: "/v1/comma/auth/session",
    });

    await admin.run(admin.api.listUsers());
    expect(admin.sent[1]).toMatchObject({
      credentials: "include",
      expected: firstSession,
      headers: expect.objectContaining({
        "x-comma-session-lifecycle-version": "1",
        "x-comma-session-transport": "cookie",
      }),
      path: "/v1/comma/admin/users",
    });
  });

  it("signs out through the server and ends the lease", async () => {
    const admin = authHarness((request) => {
      if (request.path === "/v1/comma/auth/session") return sessionOf(firstSession);
      if (request.path === "/v1/comma/auth/logout") {
        return jsonResponse({ signed_out: true });
      }
      return jsonResponse({ error: "unavailable" }, 503);
    });
    await admin.run(admin.auth.start);
    const lease = leaseOf(admin.state());

    await admin.run(admin.auth.signOut);

    expect(admin.sent[1]).toMatchObject({
      body: {},
      expected: firstSession,
      method: "POST",
      path: "/v1/comma/auth/logout",
    });
    expect(admin.phases).toEqual([
      "initializing",
      "signed_in",
      "signing_out",
      "signed_out",
    ]);
    expect(Deferred.isDoneUnsafe(lease.closed)).toBe(true);
    const requestsBefore = admin.sent.length;
    const afterSignOut = await admin.run(admin.api.listUsers());
    expect(Exit.isFailure(afterSignOut) && afterSignOut.cause).toBeTruthy();
    expect(JSON.stringify(afterSignOut)).toContain("AdminSessionClosed");
    expect(
      admin.sent.slice(requestsBefore).map((request) => request.path)
    ).not.toContain("/v1/comma/admin/users");
  });

  it("signs in with an emailed code", async () => {
    const admin = authHarness((request) => {
      switch (request.path) {
        case "/v1/comma/auth/session":
          return unauthorized();
        case "/v1/comma/auth/google/attempt":
          return jsonResponse({ error: "unavailable" }, 503);
        case "/v1/comma/auth/email/login":
          return jsonResponse({ challenge_id: "challenge_email" });
        case "/v1/comma/auth/email/verify":
          return (request.body as { code: string }).code === "123456"
            ? sessionOf(firstSession)
            : jsonResponse({ error: "invalid_challenge" }, 401);
        default:
          return jsonResponse({ error: "unexpected" }, 500);
      }
    });
    await admin.run(admin.auth.start);
    expect(
      admin.sent.filter((request) => request.path === "/v1/comma/auth/session")
    ).toHaveLength(1);
    expect(signedOutLogin(admin.state())).toMatchObject({
      google: "unavailable",
      step: { kind: "email" },
    });
    expect(
      admin.sent.find((request) => request.path === "/v1/comma/auth/google/attempt")
    ).toMatchObject({ body: { platform: "web" }, expected: "none", method: "POST" });

    await admin.run(admin.auth.requestCode);
    expect(signedOutLogin(admin.state()).error).toBe("Enter an email.");

    await admin.run(admin.auth.setEmail("  owner@example.com "));
    await admin.run(admin.auth.requestCode);
    expect(admin.sent.at(-1)).toMatchObject({
      body: { email: "owner@example.com" },
      expected: "none",
      method: "POST",
      path: "/v1/comma/auth/email/login",
    });
    expect(signedOutLogin(admin.state())).toMatchObject({
      email: "owner@example.com",
      notice: "Verification code sent.",
      step: { challengeId: "challenge_email", kind: "code", purpose: "email_login" },
    });

    await admin.run(admin.auth.setCode("654321"));
    await admin.run(admin.auth.verifyCode);
    expect(admin.sent.at(-1)).toMatchObject({
      body: {
        challenge_id: "challenge_email",
        client_kind: "web",
        code: "654321",
      },
      expected: "none",
      method: "POST",
      path: "/v1/comma/auth/email/verify",
    });
    expect(signedOutLogin(admin.state())).toMatchObject({
      busy: false,
      error: "That verification code is invalid. Please try again.",
      step: { kind: "code" },
    });

    await admin.run(admin.auth.setCode("123456"));
    await admin.run(admin.auth.verifyCode);
    expect(leaseOf(admin.state()).sessionId).toBe(firstSession);
  });

  it("counts the resend wait down on the Clock and resends the code at 0", async () => {
    let challenges = 0;
    const admin = authHarness((request) => {
      switch (request.path) {
        case "/v1/comma/auth/session":
          return unauthorized();
        case "/v1/comma/auth/email/login":
          challenges += 1;
          // The first answer says when to resend; the second leaves it to the default.
          return jsonResponse(
            challenges === 1
              ? { challenge_id: "challenge_1", resend_after: 3 }
              : { challenge_id: "challenge_2" }
          );
        default:
          return jsonResponse({ error: "unavailable" }, 503);
      }
    });
    const logins = () =>
      admin.sent.filter((request) => request.path === "/v1/comma/auth/email/login");
    await admin.run(admin.auth.start);
    await admin.run(admin.auth.setEmail("owner@example.com"));
    await admin.run(admin.auth.requestCode);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(3);

    await admin.run(admin.auth.resendCode);
    expect(logins()).toHaveLength(1);
    await admin.advance(999);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(3);
    await admin.advance(1);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(2);
    await admin.advance(1_999);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(1);
    await admin.run(admin.auth.resendCode);
    expect(logins()).toHaveLength(1);
    await admin.advance(1);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(0);

    await admin.run(admin.auth.resendCode);
    expect(logins()).toHaveLength(2);
    expect(logins()[1]).toMatchObject({
      body: { email: "owner@example.com" },
      expected: "none",
    });
    expect(signedOutLogin(admin.state())).toMatchObject({
      notice: "Verification code sent.",
      resendSeconds: 60,
      step: { challengeId: "challenge_2", kind: "code", purpose: "email_login" },
    });
    await admin.advance(59_000);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(1);
    await admin.advance(1_000);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(0);
  });

  it("waits out a rate-limited request's Retry-After on the Clock", async () => {
    let limited = true;
    const admin = authHarness((request) => {
      switch (request.path) {
        case "/v1/comma/auth/session":
          return unauthorized();
        case "/v1/comma/auth/email/login":
          return limited
            ? new Response(JSON.stringify({ error: "rate_limited" }), {
                headers: { "content-type": "application/json", "retry-after": "5" },
                status: 429,
              })
            : jsonResponse({ challenge_id: "challenge_1", resend_after: 30 });
        default:
          return jsonResponse({ error: "unavailable" }, 503);
      }
    });
    const logins = () =>
      admin.sent.filter((request) => request.path === "/v1/comma/auth/email/login");
    await admin.run(admin.auth.start);
    await admin.run(admin.auth.setEmail("owner@example.com"));

    await admin.run(admin.auth.requestCode);
    expect(signedOutLogin(admin.state())).toMatchObject({
      error: "Too many attempts. Please wait before trying again.",
      retryWait: { email: "owner@example.com", seconds: 5 },
      step: { kind: "email" },
    });
    await admin.run(admin.auth.requestCode);
    expect(logins()).toHaveLength(1);
    await admin.advance(4_000);
    expect(signedOutLogin(admin.state()).retryWait).toEqual({
      email: "owner@example.com",
      seconds: 1,
    });
    await admin.advance(1_000);
    expect(signedOutLogin(admin.state()).retryWait).toBeUndefined();

    // A resend refused the same way waits for the Retry-After instead.
    limited = false;
    await admin.run(admin.auth.requestCode);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(30);
    await admin.advance(30_000);
    limited = true;
    await admin.run(admin.auth.resendCode);
    expect(logins()).toHaveLength(3);
    expect(signedOutLogin(admin.state())).toMatchObject({
      error: "Too many attempts. Please wait before trying again.",
      resendSeconds: 5,
      step: { challengeId: "challenge_1", kind: "code" },
    });
    await admin.advance(5_000);
    expect(signedOutLogin(admin.state()).resendSeconds).toBe(0);
  });

  it("signs in with Google and links the account by an emailed code when asked", async () => {
    const admin = authHarness((request) => {
      switch (request.path) {
        case "/v1/comma/auth/session":
          return unauthorized();
        case "/v1/comma/auth/google/attempt":
          return jsonResponse({
            attempt_id: "google_attempt",
            client_id: "google-client",
            nonce: "nonce-1",
            platform: "web",
          });
        case "/v1/comma/auth/google":
          return jsonResponse({
            challenge_id: "challenge_link",
            code: "246810",
            email: "owner@gmail.com",
            status: "otp_required",
          });
        case "/v1/comma/auth/google/link/verify":
          return sessionOf(firstSession, "owner@gmail.com");
        default:
          return jsonResponse({ error: "unexpected" }, 500);
      }
    });
    await admin.run(admin.auth.start);
    await admin.fork(admin.auth.showGoogleButton({} as HTMLElement));

    expect(admin.rendered).toMatchObject([
      { clientId: "google-client", nonce: "nonce-1" },
    ]);
    expect(signedOutLogin(admin.state()).google).toBe("ready");

    admin.rendered[0]?.onCredential("google-id-token");
    await flush();
    expect(admin.sent.at(-1)).toMatchObject({
      body: {
        attempt_id: "google_attempt",
        client_kind: "web",
        credential: "google-id-token",
        nonce: "nonce-1",
      },
      expected: "none",
      method: "POST",
      path: "/v1/comma/auth/google",
    });
    expect(signedOutLogin(admin.state())).toMatchObject({
      code: "246810",
      email: "owner@gmail.com",
      notice: "Verification code sent.",
      step: { challengeId: "challenge_link", kind: "code", purpose: "google_link" },
    });

    await admin.run(admin.auth.verifyCode);
    expect(admin.sent.at(-1)).toMatchObject({
      body: { challenge_id: "challenge_link", code: "246810" },
      path: "/v1/comma/auth/google/link/verify",
    });
    expect(leaseOf(admin.state()).email).toBe("owner@gmail.com");
  });

  it("shows a refused Google sign-in and prepares a new attempt on retry", async () => {
    let attempts = 0;
    const admin = authHarness((request) => {
      switch (request.path) {
        case "/v1/comma/auth/session":
          return unauthorized();
        case "/v1/comma/auth/google/attempt":
          attempts += 1;
          return jsonResponse({
            attempt_id: `google_attempt_${attempts}`,
            client_id: "google-client",
            nonce: `nonce-${attempts}`,
            platform: "web",
          });
        case "/v1/comma/auth/google":
          return jsonResponse({ error: "unauthorized" }, 401);
        default:
          return jsonResponse({ error: "unexpected" }, 500);
      }
    });
    await admin.run(admin.auth.start);
    await admin.fork(admin.auth.showGoogleButton({} as HTMLElement));

    admin.rendered[0]?.onCredential(undefined);
    await flush();
    expect(signedOutLogin(admin.state())).toMatchObject({
      error: "Google did not return a sign-in credential. Please try again.",
      google: "unavailable",
    });

    admin.rendered[0]?.onCredential("google-id-token");
    await flush();
    expect(signedOutLogin(admin.state())).toMatchObject({
      error: "Sign-in could not be completed. Please try again.",
      google: "unavailable",
    });

    await admin.run(admin.auth.retryGoogle);
    expect(attempts).toBe(2);
    expect(admin.rendered.at(-1)).toMatchObject({ nonce: "nonce-2" });
    expect(signedOutLogin(admin.state())).toMatchObject({ error: "", google: "ready" });
  });

  it("asks an unreachable server again on the Clock, then waits for the operator", async () => {
    const admin = authHarness(() => unreachable());
    const probes = () =>
      admin.sent.filter((request) => request.path === "/v1/comma/auth/session").length;

    // Startup waits on the Clock between its probes, so it runs on its own.
    await admin.fork(admin.auth.start);
    expect(probes()).toBe(1);
    expect(admin.state().phase).toBe("initializing");
    await admin.advance(249);
    expect(probes()).toBe(1);
    await admin.advance(1);
    // The second startup probe, then the first reconnect probe at once.
    expect(probes()).toBe(3);
    expect(admin.state().phase).toBe("connecting");

    const schedule = [
      [250, 4],
      [1_000, 5],
      [250, 6],
      [3_000, 7],
      [250, 8],
      [10_000, 9],
      [250, 10],
      [30_000, 11],
    ] as const;
    for (const [millis, count] of schedule) {
      await admin.advance(millis - 1);
      expect(probes()).toBe(count - 1);
      await admin.advance(1);
      expect(probes()).toBe(count);
    }
    expect(admin.state().phase).toBe("connecting");
    await admin.advance(250);
    expect(probes()).toBe(12);
    expect(admin.state().phase).toBe("unavailable");
    await admin.advance(60_000);
    expect(probes()).toBe(12);

    // Back online: the server is asked again.
    admin.serve((request) =>
      request.path === "/v1/comma/auth/session"
        ? sessionOf(firstSession)
        : unreachable()
    );
    await admin.online();
    expect(probes()).toBe(13);
    expect(leaseOf(admin.state()).sessionId).toBe(firstSession);
  });

  it("gives up a lifecycle request after 8 s on the Clock", async () => {
    const admin = authHarness(silent);

    await admin.fork(admin.auth.start);
    expect(admin.sent).toHaveLength(1);
    await admin.advance(7_999);
    expect(admin.sent[0]?.signal?.aborted).toBe(false);
    await admin.advance(1);
    expect(admin.sent[0]?.signal?.aborted).toBe(true);
    await admin.advance(250);
    expect(admin.sent).toHaveLength(2);
  });

  it("ends the lease on a product 401 and adopts the Session the server confirms", async () => {
    const check = Promise.withResolvers<Response>();
    let probes = 0;
    const admin = authHarness((request) => {
      if (request.path === "/v1/comma/auth/session") {
        probes += 1;
        return probes === 1 ? sessionOf(firstSession) : check.promise;
      }
      if (request.path === "/v1/comma/admin/users") return unauthorized();
      return silent(request);
    });
    await admin.run(admin.auth.start);
    const lease = leaseOf(admin.state());
    await admin.fork(admin.api.listAuditEvents());
    expect(admin.sent.at(-1)?.path).toBe("/v1/comma/admin/audit-events");

    await admin.run(admin.api.listUsers());

    expect(Deferred.isDoneUnsafe(lease.closed)).toBe(true);
    expect(
      admin.sent.find((request) => request.path === "/v1/comma/admin/audit-events")
        ?.signal?.aborted
    ).toBe(true);
    expect(admin.state().phase).toBe("invalidating");
    expect(admin.sent.at(-1)).toMatchObject({
      expected: firstSession,
      path: "/v1/comma/auth/session",
    });

    check.resolve(sessionOf(firstSession));
    await flush();
    const renewed = leaseOf(admin.state());
    expect(renewed).not.toBe(lease);
    expect(renewed.sessionId).toBe(firstSession);
  });

  it("signs out when the server says a product 401's Session is gone", async () => {
    let probes = 0;
    const admin = authHarness((request) => {
      if (request.path === "/v1/comma/auth/session") {
        probes += 1;
        return probes === 1 ? sessionOf(firstSession) : unauthorized();
      }
      if (request.path === "/v1/comma/admin/users") return unauthorized();
      return jsonResponse({ error: "unavailable" }, 503);
    });
    await admin.run(admin.auth.start);

    await admin.run(admin.api.listUsers());

    expect(admin.state().phase).toBe("signed_out");
    expect(admin.phases).toEqual([
      "initializing",
      "signed_in",
      "invalidating",
      "signed_out",
    ]);
  });

  it("rebinds to the Cookie's new Session on a product 409 without leaving the dashboard", async () => {
    let cookieSession = firstSession;
    const admin = authHarness((request) => {
      if (request.path === "/v1/comma/auth/session") {
        return request.expected === "unknown" || request.expected === cookieSession
          ? sessionOf(cookieSession)
          : jsonResponse({ error: "session_changed" }, 409);
      }
      return request.expected === cookieSession
        ? jsonResponse({ data: [], has_more: false, next_cursor: null })
        : jsonResponse({ error: "session_changed" }, 409);
    });
    await admin.run(admin.auth.start);
    const lease = leaseOf(admin.state());

    cookieSession = secondSession;
    await admin.run(admin.api.listUsers());

    const probes = admin.sent
      .filter((request) => request.path === "/v1/comma/auth/session")
      .map((request) => request.expected);
    expect(probes).toEqual(["unknown", firstSession, "unknown"]);
    expect(leaseOf(admin.state()).sessionId).toBe(secondSession);
    expect(Deferred.isDoneUnsafe(lease.closed)).toBe(true);
    expect(admin.phases).toEqual(["initializing", "signed_in", "signed_in"]);

    await admin.run(admin.api.listUsers());
    expect(admin.sent.at(-1)).toMatchObject({
      expected: secondSession,
      path: "/v1/comma/admin/users",
    });
  });

  it("stays signed in when a 409 check cannot reach the server, and checks again on the Clock", async () => {
    let probes = 0;
    const admin = authHarness((request) => {
      if (request.path === "/v1/comma/auth/session") {
        probes += 1;
        return probes === 2 ? unreachable() : sessionOf(firstSession);
      }
      return jsonResponse({ error: "session_changed" }, 409);
    });
    await admin.run(admin.auth.start);
    const lease = leaseOf(admin.state());

    await admin.run(admin.api.listUsers());
    expect(probes).toBe(2);
    expect(admin.state().phase).toBe("signed_in");

    await admin.advance(999);
    expect(probes).toBe(2);
    await admin.advance(1);
    expect(probes).toBe(3);
    expect(leaseOf(admin.state())).toBe(lease);
    await admin.advance(60_000);
    expect(probes).toBe(3);
  });
});
