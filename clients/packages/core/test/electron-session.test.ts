// The Electron session lifecycle in the core (session/electron-lifecycle.ts): what Main's session service did, on a
// TestClock, against Main as the core sees it (testing/fake-main.ts: the credential store by reference, the bearers
// kept out of the core, the gate, the Google window) and a server that sees the bearer Main attaches.
import {
  sessionExpectation,
  type SessionLifecycleSnapshot,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import { HostError } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { Effect, Result } from "effect";
import { describe, expect, it } from "vitest";
import type { Core } from "../src/core.ts";
import type { SessionAuthorityResume } from "../src/host.ts";
import { FakeMain, type StoredCredential } from "../src/testing/fake-main.ts";
import {
  FakeCommaApi,
  FakeHost,
  inProcessOpener,
  json,
  offline,
  PRODUCT_PATH,
  productCall,
  type SeenRequest,
  startTestCore,
  TestTime,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const audienceA = "https://api.comma.test";
const audienceB = "https://api-b.comma.test";

const bearer = (request: SeenRequest) =>
  (request.headers?.find(([k]) => k === "authorization")?.[1] ?? "").replace(
    "Bearer ",
    ""
  );

function storedCredential(overrides: Partial<StoredCredential> = {}): StoredCredential {
  return {
    audience: audienceA,
    email: "peng@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "session-1",
    token: "main_secret",
    userId: "user-1",
    ...overrides,
  };
}

function currentSession() {
  return {
    expires_at: 1_900_000_100,
    session_id: "session-1",
    user: { email: "peng@example.com", id: "user-1", name: "Peng", status: "active" },
  };
}

function issuedSession(
  options: { sessionId?: string; token?: string; userId?: string } = {}
) {
  return {
    ...currentSession(),
    session_id: options.sessionId ?? "session-1",
    token: options.token ?? "issued_secret",
    user: { ...currentSession().user, id: options.userId ?? "user-1" },
  };
}

/** Outputs as two runs compare them, at each instant in any order. */
const byTime = (outputs: Parameters<typeof comparable>[0]) =>
  comparable(outputs)
    .map((output) => JSON.stringify(output))
    .sort();

const googleAttempt = {
  attempt_id: "google-attempt-1",
  client_id: "desktop-client",
  nonce: "backend-nonce",
  platform: "electron",
};

type Setup = ReturnType<typeof setup>;

/** A core running Electron's session lifecycle against a fake Main: `stored` is what Main's store holds at start. */
function setup(
  options: {
    stored?: StoredCredential;
    pending?: StoredCredential[];
    origin?: string;
    resumed?: SessionAuthorityResume;
    showsKeptAccount?: boolean;
    android?: boolean;
    ios?: boolean;
    api?: FakeCommaApi;
    time?: TestTime;
    before?: (t: { api: FakeCommaApi; main: FakeMain }) => void;
  } = {}
) {
  const api = options.api ?? new FakeCommaApi();
  const host = new FakeHost({
    sessionSource: "core",
    api,
    ...(options.time ? { time: options.time } : {}),
  });
  const main = new FakeMain(host, {
    ...(options.origin ? { origin: options.origin } : {}),
    ...(options.resumed ? { resumed: options.resumed } : {}),
    ...(options.showsKeptAccount ? { showsKeptAccount: true } : {}),
    ...(options.android ? { clientKind: "android", clientPlatform: "android" } : {}),
    ...(options.ios ? { clientKind: "ios", clientPlatform: "ios" } : {}),
  });
  if (options.stored) main.active = options.stored;
  if (options.pending) main.pending = [...options.pending];
  options.before?.({ api, main });
  const core = startTestCore(host, { coalesceMs: 0 });
  return harness(core, host, main);
}

function harness(core: Core, host: FakeHost, main: FakeMain) {
  const time = host.time!;
  const lifecycle = core.electronSession!;
  /** Every phase the lifecycle published, in order. */
  const phases: string[] = [];
  core.session.onChange(() => {
    const phase = lifecycle.snapshot().phase;
    if (phases.at(-1) !== phase) phases.push(phase);
  });
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  return {
    core,
    client,
    host,
    main,
    api: host.api,
    time,
    lifecycle,
    phases,
    state: () => lifecycle.snapshot(),
    /** A call from a window, answered once `ms` of the core's time passed. */
    async ask<T>(name: string, params: unknown = {}, ms = 50): Promise<T> {
      const answer = client.call(name, params);
      await time.pass(ms);
      return (await answer) as T;
    },
    /** One of the lifecycle's operations, started now; its outcome when it has one. */
    start<A>(effect: Effect.Effect<A>): Promise<A> {
      return core.runner.run(effect);
    },
    /** One of the lifecycle's operations, its outcome after `ms`. */
    async run<A>(effect: Effect.Effect<A>, ms = 50): Promise<A> {
      const done = core.runner.run(effect);
      await time.pass(ms);
      return done;
    },
    expected() {
      return sessionExpectation(lifecycle.snapshot() as TerminalSessionSnapshot);
    },
    /** A product request a window asks the core for (through Main's `/v1` proxy); its outcome after `ms`. */
    async product(ms = 20) {
      const done = productCall(client);
      await time.pass(ms);
      return done;
    },
    logouts: () => host.api.seen("POST", "/v1/comma/auth/logout").map(bearer),
    /** A window shows the connection's recovery: what the core says of it, and a way to stop showing it. */
    showRecovery() {
      let state: unknown;
      const stop = client.subscribe(
        { topic: "sessionRecovery" },
        (value) => (state = value),
        () => undefined
      );
      return { state: () => state, stop };
    },
  };
}

/** The server's session probe: the session a bearer names, or 401. */
function serveSessions(api: FakeCommaApi, sessions: Record<string, unknown>) {
  api.on("GET", "/v1/comma/auth/session", (request: SeenRequest) => {
    const session = sessions[bearer(request)];
    return session ? json(200, session) : json(401, { error: "unauthorized" });
  });
}

function serveEmail(
  api: FakeCommaApi,
  issue: (body: { code?: string }) => unknown = () => issuedSession()
) {
  api.on("POST", "/v1/comma/auth/email/login", (request: SeenRequest) => ({
    status: 200,
    headers: [["content-type", "application/json"]],
    body: new TextEncoder().encode(
      JSON.stringify({
        challenge_id: `challenge-${(request.body as { email?: string }).email}`,
        code: "123456",
      })
    ),
  }));
  api.on("POST", "/v1/comma/auth/email/verify", (request: SeenRequest) =>
    json(200, issue(request.body as { code?: string }))
  );
  api.on("POST", "/v1/comma/auth/logout", json(200, { signed_out: true }));
}

async function startedSignedOut(t: Setup) {
  await t.time.pass(20);
  expect(t.state().phase).toBe("signed_out");
}

/** An emailed code requested: its attempt and challenge. */
async function requested(t: Setup, email = "peng@example.com") {
  const result = await t.run(
    t.lifecycle.requestEmailLogin({ email, expected: t.expected() as never })
  );
  if (!result.ok) throw new Error(`Expected an auth attempt: ${result.error.code}`);
  return result.value;
}

describe("the Electron session lifecycle", () => {
  it("keeps a stored credential's lease shut until the startup probe confirms it, and sends its bearer only from Main", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => serveSessions(api, { main_secret: currentSession() }),
    });
    expect(t.state().phase).toBe("initializing");
    expect(t.main.gateLease()).toBeNull();
    expect(t.core.session.lease()).toBeNull();

    await t.time.pass(20);

    expect(t.state()).toMatchObject({ generation: 1, phase: "signed_in" });
    expect(t.main.gateLease()).toMatchObject({
      audience: audienceA,
      generation: 1,
      sessionId: "session-1",
    });
    expect(t.api.seen("GET", "/v1/comma/auth/session").map(bearer)).toEqual([
      "main_secret",
    ]);
    expect(t.main.leaks(t.core.recorder!.dump())).toEqual([]);
  });

  it("gives up a 200 probe whose body never completes after 5 s and settles initialization", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.holdBody("GET", "/v1/comma/auth/session");
      },
    });
    await t.time.pass(4_990);
    expect(t.state().phase).toBe("initializing");
    await t.time.pass(20);
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable" },
    });
    expect(t.main.gateLease()).toBeNull();
  });

  it("probes the stored credential again on a retry after a failed startup probe, and no more once settled", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.on("GET", "/v1/comma/auth/session", () =>
          api.seen("GET", "/v1/comma/auth/session").length === 1
            ? json(503, { error: "unavailable" })
            : json(200, currentSession())
        );
      },
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("indeterminate");
    expect(t.main.gateLease()).toBeNull();

    expect(
      await t.run(t.lifecycle.reconcile({ reason: "manual_retry" }))
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in" },
    });
    // An unqualified retry is not admitted once the state settled.
    expect(
      await t.run(t.lifecycle.reconcile({ reason: "manual_retry" }))
    ).toMatchObject({
      ok: false,
      error: { code: "conflict" },
    });
    expect(t.api.seen("GET", "/v1/comma/auth/session")).toHaveLength(2);
  });

  it("recovers the connection while a window shows it: at 0, 1, 3, 10 and 30 seconds, then again when asked", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" })),
    });
    const probes = () => t.api.seen("GET", "/v1/comma/auth/session").length;
    await t.time.pass(20);
    expect(t.state().phase).toBe("indeterminate");
    // No window shows it: the core waits.
    await t.time.pass(60_000, 1_000);
    expect(probes()).toBe(1);

    const shown = t.showRecovery();
    await t.time.pass(20);
    expect(shown.state()).toBe("trying");
    expect(probes()).toBe(2);
    await t.time.pass(44_000, 500);
    expect(probes()).toBe(6);
    expect(shown.state()).toBe("exhausted");
    await t.time.pass(120_000, 5_000);
    expect(probes()).toBe(6);

    // The person tries again: a new burst, until the server answers.
    t.api.on("GET", "/v1/comma/auth/session", json(200, currentSession()));
    serveSessions(t.api, { main_secret: currentSession() });
    await t.ask("session.recover");
    await t.time.pass(100);
    expect(t.state().phase).toBe("signed_in");
    expect(shown.state()).toBeNull();
    shown.stop();
  });

  it("stops recovering as soon as no window shows it", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" })),
    });
    const probes = () => t.api.seen("GET", "/v1/comma/auth/session").length;
    await t.time.pass(20);
    const shown = t.showRecovery();
    await t.time.pass(1_100, 100);
    expect(probes()).toBe(3);
    shown.stop();
    await t.time.pass(120_000, 5_000);
    expect(probes()).toBe(3);
  });

  it("shows a stored credential's kept account while its check cannot reach the server, for a host that asks, and confirms it on a retry", async () => {
    const t = setup({
      stored: storedCredential(),
      showsKeptAccount: true,
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", () =>
          api.seen("GET", "/v1/comma/auth/session").length === 1
            ? json(503, { error: "unavailable" })
            : json(200, currentSession())
        ),
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("indeterminate");
    // What the device keeps for the account is open and shown; no request can go out for it.
    expect(t.core.session.value()).toMatchObject({
      phase: "signed_in",
      userId: "user-1",
    });
    const kept = t.core.session.current();
    expect(kept).not.toBeNull();
    expect(t.core.session.withheld()).toBe(false);
    expect(t.core.session.lease()).toBeNull();
    expect(t.main.gateLease()).toBeNull();

    expect(
      await t.run(t.lifecycle.reconcile({ reason: "manual_retry" }))
    ).toMatchObject({ ok: true, value: { phase: "signed_in" } });
    expect(t.core.session.current()).toBe(kept);
    expect(t.core.session.lease()).not.toBeNull();
    expect(t.host.deleted).toEqual([]);
  });

  it("closes and deletes a kept account whose stored credential the server refuses", async () => {
    const t = setup({
      stored: storedCredential(),
      showsKeptAccount: true,
      before: ({ api }) => serveSessions(api, {}),
    });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    expect(t.core.session.value().phase).toBe("signed_out");
    expect(t.core.session.current()).toBeNull();
    expect(t.host.deleted).toHaveLength(1);
  });

  it("signs out of a kept account while the server cannot be reached, and queues its credential for revocation", async () => {
    const t = setup({
      stored: storedCredential(),
      showsKeptAccount: true,
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" })),
    });
    await t.time.pass(20);
    const undecided = t.state();
    expect(undecided.phase).toBe("indeterminate");
    expect(
      await t.run(
        t.lifecycle.signOut({
          expected: {
            authorityInstanceId: undecided.authority.authorityInstanceId,
            expectedSessionId: null,
            generation: undecided.generation,
          },
        })
      )
    ).toMatchObject({ ok: true, value: { phase: "signed_out" } });
    expect(t.main.active).toBeNull();
    expect(t.main.pending.map((pending) => pending.token)).toEqual(["main_secret"]);
    expect(t.core.session.current()).toBeNull();
  });

  it("shows nothing of a stored credential's account before the server confirms it, unless the host asks", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" })),
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("indeterminate");
    expect(t.core.session.value().phase).toBe("unknown");
    expect(t.core.session.current()).toBeNull();
  });

  it("removes a credential the startup probe finds refused, and never opens the lease", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => serveSessions(api, {}),
    });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    expect(t.main.active).toBeNull();
    expect(t.main.told.some((told) => told.lease !== null)).toBe(false);
  });

  it.each(["sign_out", "current_401"] as const)(
    "does not reopen a confirmed session after a %s wins over a probe under way",
    async (winner) => {
      const t = setup({
        stored: storedCredential(),
        before: ({ api }) => {
          serveSessions(api, { main_secret: currentSession() });
          api.on("POST", "/v1/comma/auth/logout", json(200, { signed_out: true }));
        },
      });
      await t.time.pass(20);
      const signedIn = t.state();
      const lease = t.core.session.lease()!;
      const release = t.api.hold("GET", "/v1/comma/auth/session");
      const reconcile = t.start(
        t.lifecycle.reconcile({ expected: t.expected(), reason: "focus" })
      );
      await t.time.pass(10);

      if (winner === "sign_out")
        await t.run(
          t.lifecycle.signOut({ expected: sessionExpectation(signedIn as never) })
        );
      else {
        // Main saw the 401 on its `/v1` proxy: its gate closed, and it tells the core.
        t.core.hostRejected({ ...lease }, 401);
        await t.time.pass(20);
      }
      const intent = t.phases.indexOf(
        winner === "sign_out" ? "signing_out" : "invalidating"
      );
      expect(intent).toBeGreaterThanOrEqual(0);
      expect(t.state().phase).toBe("signed_out");

      release();
      await t.time.pass(20);
      expect(await reconcile).toMatchObject({ ok: false, error: { code: "conflict" } });
      expect(t.phases.slice(intent)).not.toContain("signed_in");
      expect(t.state().phase).toBe("signed_out");
      expect(t.main.gateLease()).toBeNull();
    }
  );

  for (const endpoint of ["bootstrap", "ensure"] as const) {
    it.each([401, 403, 404])(
      `ends the Electron session only for a current ${endpoint} 401 (%i)`,
      async (status) => {
        const path =
          endpoint === "bootstrap"
            ? "/v1/comma/me/bootstrap"
            : "/v1/comma/groups/grp_1/assistant-chat";
        const t = setup({
          stored: storedCredential(),
          before: ({ api }) => {
            serveSessions(api, { main_secret: currentSession() });
            api.on("POST", "/v1/comma/me/bootstrap", {
              status: "ready",
              workspace: {
                group_id: "grp_1",
                id: "wsp_1",
                name: "Main",
                status: "ready",
              },
            });
            api.on("POST", path, json(status, { error: "refused" }));
          },
        });
        await t.time.pass(0);
        expect(t.state().phase).toBe("signed_in");
        const lease = t.main.gateLease();
        const resolution = t.client
          .call("chat.resolveWorkspaceChat", {})
          .catch((error: unknown) => error);
        await t.time.pass(50);
        if (status === 401)
          expect(await resolution).toMatchObject({ code: "session_changed" });
        else expect(await resolution).toEqual({ status: "hidden" });
        expect(t.api.seen("POST", path)).toHaveLength(1);
        if (status === 401) {
          expect(t.state()).toMatchObject({
            phase: "signed_out",
            reason: "unauthorized",
          });
          expect(t.main.gateLease()).toBeNull();
          expect(t.main.active).toBeNull();
        } else {
          expect(t.state().phase).toBe("signed_in");
          expect(t.main.gateLease()).toEqual(lease);
          expect(t.main.active?.token).toBe("main_secret");
          expect(t.phases).not.toContain("invalidating");
        }
      }
    );
  }

  it("clears a credential for another server before sign-in, without sending its bearer", async () => {
    const t = setup({ origin: audienceB, stored: storedCredential() });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "no_session" });
    expect(t.api.requests).toEqual([]);
    expect(t.main.active).toBeNull();
    expect(t.main.pending).toEqual([]);
  });

  it("drops another server's queued revocations and keeps this server's session", async () => {
    const t = setup({
      origin: audienceB,
      stored: storedCredential({ audience: audienceB, token: "current_secret" }),
      pending: [storedCredential()],
      before: ({ api }) => serveSessions(api, { current_secret: currentSession() }),
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("signed_in");
    expect(t.main.active).toMatchObject({
      audience: audienceB,
      token: "current_secret",
    });
    expect(t.main.pending).toEqual([]);
    expect(t.api.requests.map(bearer)).toEqual(["current_secret"]);
  });

  it("drops another server's queued revocations and keeps this server's revocation work", async () => {
    const t = setup({
      origin: audienceB,
      pending: [
        storedCredential(),
        storedCredential({ audience: audienceB, token: "pending_current" }),
      ],
      before: ({ api }) =>
        api.on("POST", "/v1/comma/auth/logout", json(503, { error: "unavailable" })),
    });
    await t.time.pass(50);
    expect(t.state().phase).toBe("signed_out");
    expect(t.main.pending).toEqual([
      expect.objectContaining({ audience: audienceB, token: "pending_current" }),
    ]);
    expect(t.logouts().length).toBeGreaterThan(0);
    expect(new Set(t.logouts())).toEqual(new Set(["pending_current"]));
  });

  it("reports a failed cleanup of another server's credential and retries it before sign-in", async () => {
    const t = setup({
      origin: audienceB,
      stored: storedCredential(),
      before: ({ main }) => main.failNext("retainAudience"),
    });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_mutation_uncertain" },
    });
    expect(t.main.active).toMatchObject({ audience: audienceA });
    expect(
      await t.run(t.lifecycle.reconcile({ reason: "manual_retry" }))
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });
    expect(t.api.requests).toEqual([]);
  });

  it("treats a probe that reflects a bearer as a protocol mismatch and keeps the lease shut", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", {
          ...currentSession(),
          token: "reflected",
        }),
    });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
    expect(t.main.gateLease()).toBeNull();
    // Main kept the reflected bearer out of the core; the core let it go; the stored credential stays.
    expect(t.main.issued.size).toBe(0);
    expect(t.main.active).toMatchObject({ token: "main_secret" });
    expect(t.main.leaks(t.core.recorder!.dump())).toEqual([]);
  });

  it("accepts a probe with fields a newer server added", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", {
          ...currentSession(),
          workspace_hint: "wsp_new",
        }),
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("signed_in");
  });

  it("refuses a sign-in for a stale expectation before any request", async () => {
    const t = setup();
    await startedSignedOut(t);
    const expected = t.expected();
    expect(
      await t.run(
        t.lifecycle.requestEmailLogin({
          email: "peng@example.com",
          expected: { ...expected, generation: expected.generation + 1 } as never,
        })
      )
    ).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(t.api.requests).toEqual([]);
  });

  it("signs in with an emailed code: the attempt and the session carry no bearer, Main keeps it", async () => {
    const t = setup({
      before: ({ api }) =>
        serveEmail(api, (body) => {
          expect(body).toEqual({
            challenge_id: "challenge-peng@example.com",
            client_kind: "electron",
            client_platform: "macos",
            code: "123456",
          });
          return issuedSession();
        }),
    });
    await startedSignedOut(t);
    const challenge = await requested(t);
    expect(challenge.challengeId).toBe("challenge-peng@example.com");
    // The development server's code is not handed on.
    expect(JSON.stringify(challenge)).not.toContain("123456");

    const verified = await t.ask<{ ok: boolean; value: SessionLifecycleSnapshot }>(
      "session.email.verify",
      { attempt: challenge.attempt, challengeId: challenge.challengeId, code: "123456" }
    );
    expect(verified).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
    expect(JSON.stringify(verified)).not.toContain("issued_secret");
    expect(t.main.active).toMatchObject({
      audience: audienceA,
      sessionId: "session-1",
      token: "issued_secret",
    });
    expect(
      t.api.requests.every((r) =>
        r.headers?.some(([k, v]) => k === "x-comma-session-transport" && v === "bearer")
      )
    ).toBe(true);
  });

  it("signs in an Android client with the ID token its account chooser gave", async () => {
    const t = setup({
      android: true,
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", (request: SeenRequest) => {
          expect(request.body).toEqual({ platform: "android" });
          return json(200, { ...googleAttempt, platform: "android" });
        });
        api.on("POST", "/v1/comma/auth/google", (request: SeenRequest) => {
          expect(request.body).toEqual({
            attempt_id: "google-attempt-1",
            client_kind: "android",
            client_platform: "android",
            credential: "google-id-token",
            nonce: "backend-nonce",
          });
          return json(200, issuedSession());
        });
      },
    });
    t.main.google = () =>
      Effect.succeed({ grant: "grant-1", idToken: "google-id-token" });
    await startedSignedOut(t);
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({ ok: true, value: { status: "signed_in" } });
    expect(t.state().authority.kind).toBe("android_keystore");
    expect(t.main.active?.token).toBe("issued_secret");
    expect(t.main.googleDone).toEqual([["grant-1", true]]);
  });

  it("signs in an iPhone with the identity token its Sign in with Apple sheet gave", async () => {
    const t = setup({
      ios: true,
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/apple/attempt", (request: SeenRequest) => {
          expect(request.body).toEqual({});
          return json(200, {
            attempt_id: "apple-attempt-1",
            client_id: "surf.comma.ios",
            expires_at: 1_900_000_000,
            nonce: "apple-nonce",
          });
        });
        api.on("POST", "/v1/comma/auth/apple", (request: SeenRequest) => {
          expect(request.body).toEqual({
            attempt_id: "apple-attempt-1",
            client_kind: "ios",
            client_platform: "ios",
            identity_token: "apple-identity-token",
          });
          return json(200, issuedSession());
        });
      },
    });
    const shown: unknown[] = [];
    const apple = t.main.apple;
    t.main.apple = (input) => {
      shown.push(input);
      return apple(input);
    };
    await startedSignedOut(t);
    // The iPhone has no Google sign-in.
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({ ok: false, error: { code: "unsupported" } });
    expect(await t.ask("session.apple", { expected: t.expected() })).toMatchObject({
      ok: true,
      value: { status: "signed_in", snapshot: { phase: "signed_in" } },
    });
    expect(shown).toEqual([{ clientId: "surf.comma.ios", nonce: "apple-nonce" }]);
    expect(t.state().authority.kind).toBe("swiftui_keychain");
    expect(t.main.active?.token).toBe("issued_secret");
  });

  it("links an Apple ID to the existing account with the emailed code", async () => {
    const t = setup({
      ios: true,
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/apple/attempt", {
          attempt_id: "apple-attempt-1",
          client_id: "surf.comma.ios",
          nonce: "apple-nonce",
        });
        api.on("POST", "/v1/comma/auth/apple", {
          challenge_id: "link-challenge",
          email: "peng@example.com",
          status: "otp_required",
        });
        api.on("POST", "/v1/comma/auth/apple/link/verify", (request: SeenRequest) => {
          expect(request.body).toEqual({
            challenge_id: "link-challenge",
            client_kind: "ios",
            client_platform: "ios",
            code: "123456",
          });
          return json(200, issuedSession());
        });
      },
    });
    await startedSignedOut(t);
    const linking = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string; status: string };
    }>("session.apple", { expected: t.expected() });
    expect(linking).toMatchObject({
      ok: true,
      value: { challengeId: "link-challenge", status: "otp_required" },
    });
    expect(t.core.session.value()).toMatchObject({
      attempt: {
        method: "apple",
        challenge: { challengeId: "link-challenge", purpose: "apple_link" },
      },
    });
    expect(
      await t.ask("session.apple.linkVerify", {
        attempt: linking.value.attempt,
        challengeId: "link-challenge",
        code: "123456",
      })
    ).toMatchObject({ ok: true, value: { phase: "signed_in" } });
    expect(t.main.active?.token).toBe("issued_secret");
  });

  it("stays signed out without asking the server again when the Apple sheet is closed", async () => {
    const t = setup({
      ios: true,
      before: ({ api }) =>
        api.on("POST", "/v1/comma/auth/apple/attempt", {
          attempt_id: "apple-attempt-1",
          client_id: "surf.comma.ios",
          nonce: "apple-nonce",
        }),
    });
    t.main.apple = () => Effect.fail(new HostError("the person closed the sheet"));
    await startedSignedOut(t);
    expect(await t.ask("session.apple", { expected: t.expected() })).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(t.api.requests.map((r) => r.path)).toEqual(["/v1/comma/auth/apple/attempt"]);
    expect(t.state().phase).toBe("signed_out");
  });

  it("signs in with Google through Main's window, the bearer kept in Main", async () => {
    const t = setup({
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", (request: SeenRequest) => {
          expect(request.body).toEqual({ platform: "electron" });
          return json(200, googleAttempt);
        });
        api.on("POST", "/v1/comma/auth/google", (request: SeenRequest) => {
          expect(request.body).toEqual({
            attempt_id: "google-attempt-1",
            authorization_code: "google-authorization-code",
            client_kind: "electron",
            client_platform: "macos",
            code_verifier: "google-code-verifier",
            nonce: "backend-nonce",
            redirect_uri: "http://127.0.0.1:43123/oauth2/callback",
          });
          return json(200, issuedSession());
        });
      },
    });
    const opened: unknown[] = [];
    const google = t.main.google;
    t.main.google = (input) => {
      opened.push(input);
      return google(input);
    };
    await startedSignedOut(t);
    const result = await t.ask("session.google.desktop", { expected: t.expected() });
    expect(opened).toEqual([{ clientId: "desktop-client", nonce: "backend-nonce" }]);
    expect(result).toMatchObject({
      ok: true,
      value: {
        snapshot: {
          phase: "signed_in",
          principal: { userId: "user-1" },
          session: { audience: audienceA, sessionId: "session-1" },
        },
        status: "signed_in",
      },
    });
    expect(JSON.stringify(result)).not.toContain("issued_secret");
    expect(t.main.active).toMatchObject({ token: "issued_secret" });
    expect(t.api.requests.map((r) => r.path)).toEqual([
      "/v1/comma/auth/google/attempt",
      "/v1/comma/auth/google",
    ]);
    expect(t.main.googleDone).toEqual([["grant-1", true]]);
  });

  it("replaces an emailed code under way with a Google sign-in, which signs in without the code", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/google/attempt", json(200, googleAttempt));
        api.on("POST", "/v1/comma/auth/google", json(200, issuedSession()));
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "person@example.com");
    expect(t.core.session.value().attempt?.challenge?.purpose).toBe("email_login");
    // The person edits the address, then picks Google instead: the code's attempt gives way.
    expect(
      await t.ask("session.google.desktop", { expected: first.attempt.expected })
    ).toMatchObject({ ok: true, value: { status: "signed_in" } });
    expect(t.state().phase).toBe("signed_in");
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")).toHaveLength(0);
    expect(t.core.session.value().attempt ?? null).toBeNull();
    expect(t.main.googleDone).toEqual([["grant-1", true]]);
  });

  it("shows the window's failure page when the server refuses Google's code", async () => {
    const t = setup({
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", googleAttempt);
        api.on(
          "POST",
          "/v1/comma/auth/google",
          json(503, { error: "google_provider_unavailable" })
        );
      },
    });
    await startedSignedOut(t);
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({
      ok: false,
      error: { code: "provider_unavailable", retryable: true },
    });
    expect(t.main.googleDone).toEqual([["grant-1", false]]);
    expect(t.api.requests).toHaveLength(2);
    expect(t.state().phase).toBe("signed_out");
  });

  it("answers a failed Google preparation without a retry and without opening the window", async () => {
    const t = setup({
      before: ({ api }) =>
        api.on("POST", "/v1/comma/auth/google/attempt", json(503, {})),
    });
    let opened = 0;
    t.main.google = () => {
      opened += 1;
      return Effect.never;
    };
    await startedSignedOut(t);
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({
      ok: false,
      error: { code: "provider_unavailable" },
    });
    expect(t.api.requests).toHaveLength(1);
    expect(opened).toBe(0);
    expect(t.state().phase).toBe("signed_out");
  });

  it("keeps one Google attempt through linking with an emailed code", async () => {
    const t = setup({
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", googleAttempt);
        api.on("POST", "/v1/comma/auth/google", {
          challenge_id: "link-challenge",
          email: "peng@example.com",
          status: "otp_required",
        });
        api.on("POST", "/v1/comma/auth/google/link/verify", (request: SeenRequest) => {
          expect(request.body).toEqual({
            challenge_id: "link-challenge",
            client_kind: "electron",
            client_platform: "macos",
            code: "123456",
          });
          return json(200, issuedSession());
        });
      },
    });
    await startedSignedOut(t);
    const linked = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string; status: string };
    }>("session.google.desktop", { expected: t.expected() });
    expect(linked).toMatchObject({
      ok: true,
      value: {
        challengeId: "link-challenge",
        email: "peng@example.com",
        status: "otp_required",
      },
    });
    expect(t.main.active).toBeNull();
    // Every window sees the code the sign-in waits for.
    expect(t.core.session.value().attempt).toMatchObject({
      challenge: { challengeId: "link-challenge", purpose: "google_link" },
    });

    const verified = await t.ask("session.google.linkVerify", {
      attempt: linked.value.attempt,
      challengeId: "link-challenge",
      code: "123456",
    });
    expect(verified).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
    expect(JSON.stringify(verified)).not.toContain("issued_secret");
    expect(t.main.active).toMatchObject({ token: "issued_secret" });
    expect(t.api.requests.map((r) => r.path)).toEqual([
      "/v1/comma/auth/google/attempt",
      "/v1/comma/auth/google",
      "/v1/comma/auth/google/link/verify",
    ]);
  });

  it("keeps the first code usable when resending to the same address is rate limited", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/login", () =>
          api.seen("POST", "/v1/comma/auth/email/login").length === 2
            ? {
                status: 429,
                headers: [
                  ["content-type", "application/json"],
                  ["retry-after", "60"],
                ],
                body: new TextEncoder().encode(
                  JSON.stringify({ error: "rate_limited" })
                ),
              }
            : json(200, { challenge_id: "challenge-1" })
        );
      },
    });
    await startedSignedOut(t);
    const generation = t.state().generation;
    const first = await requested(t, "person@example.com");
    // The resend waits out the core's delay; then the server refuses it.
    await t.time.pass(60_000);
    expect(
      await t.run(
        t.lifecycle.requestEmailLogin({
          email: "person@example.com",
          expected: first.attempt.expected,
          resend: true,
        })
      )
    ).toMatchObject({
      ok: false,
      error: { code: "rate_limited", retryAfterMs: 60_000, retryable: true },
    });
    expect(t.state()).toMatchObject({ generation, phase: "authenticating" });
    expect(
      await t.run(
        t.lifecycle.verifyEmailLogin({
          attempt: first.attempt,
          challengeId: first.challengeId,
          code: "123456",
        })
      )
    ).toMatchObject({ ok: true, value: { phase: "signed_in" } });
  });

  it("counts a code's resend delay and life down on the core's clock, and refuses an early resend itself", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/login", {
          challenge_id: "challenge-1",
          expires_in: 900,
          resend_after: 30,
        });
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "person@example.com");
    const challenge = () => t.core.session.value().attempt?.challenge;
    expect(challenge()).toMatchObject({
      challengeId: "challenge-1",
      resendInSeconds: 30,
    });
    await t.time.pass(950);
    expect(challenge()).toMatchObject({ resendInSeconds: 29 });

    expect(
      await t.run(
        t.lifecycle.requestEmailLogin({
          email: "Person@Example.com",
          expected: first.attempt.expected,
          resend: true,
        })
      )
    ).toMatchObject({ ok: false, error: { code: "rate_limited", retryable: true } });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);

    await t.time.pass(29_000);
    expect(challenge()?.resendInSeconds).toBeUndefined();
    expect(challenge()?.expired).toBeUndefined();
    await t.time.pass(870_000);
    expect(challenge()).toMatchObject({ challengeId: "challenge-1", expired: true });
  });

  it("goes back to the code under way for the same address without asking the server, and sends another only on resend", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/login", {
          challenge_id: "challenge-1",
          expires_in: 900,
          resend_after: 60,
        });
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "person@example.com");
    const request = (email: string, resend?: true) =>
      t.run(
        t.lifecycle.requestEmailLogin({
          email,
          expected: first.attempt.expected,
          ...(resend ? { resend } : {}),
        })
      );
    // The address typed again, as a person who edited it and changed their mind: the same code, no request.
    expect(await request(" Person@Example.com ")).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-1", resumed: true },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);
    // A resend before the code's delay is up is held by the core.
    expect(await request("person@example.com", true)).toMatchObject({
      ok: false,
      error: { code: "rate_limited" },
    });
    await t.time.pass(60_000);
    expect(await request("person@example.com", true)).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-1" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(2);
    // A code that stopped working is not gone back to: the address asks for a new one.
    await t.time.pass(900_000);
    expect(await request("person@example.com")).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-1" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(3);
  });

  it("counts a resend's wait as the longer of the code's delay and the address's retry-after, and does not hold the address of a code that still works", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/login", () =>
          api.seen("POST", "/v1/comma/auth/email/login").length === 1
            ? json(200, {
                challenge_id: "challenge-1",
                expires_in: 900,
                resend_after: 60,
              })
            : {
                status: 429,
                headers: [
                  ["content-type", "application/json"],
                  ["retry-after", "45"],
                ],
                body: new TextEncoder().encode(
                  JSON.stringify({ error: "rate_limited" })
                ),
              }
        );
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "person@example.com");
    const value = () => t.core.session.value();
    await t.time.pass(25_000);
    expect(value().attempt?.challenge).toMatchObject({ resendInSeconds: 35 });
    await t.time.pass(35_000);
    expect(
      await t.run(
        t.lifecycle.requestEmailLogin({
          email: "person@example.com",
          expected: first.attempt.expected,
          resend: true,
        })
      )
    ).toMatchObject({
      ok: false,
      error: { code: "rate_limited", retryAfterMs: 45_000 },
    });
    // The refused resend keeps the code; its next resend waits for the address's retry-after.
    expect(value().attempt?.challenge).toMatchObject({
      challengeId: "challenge-1",
      resendInSeconds: 45,
    });
    // The address is not held while its code works: typing it again goes back to that code.
    expect(value().emailCooldown).toBeNull();
    expect(
      await t.run(
        t.lifecycle.requestEmailLogin({
          email: "person@example.com",
          expected: first.attempt.expected,
        })
      )
    ).toMatchObject({ ok: true, value: { challengeId: "challenge-1", resumed: true } });
    expect(
      await t.run(
        t.lifecycle.verifyEmailLogin({
          attempt: first.attempt,
          challengeId: "challenge-1",
          code: "123456",
        })
      )
    ).toMatchObject({ ok: true, value: { phase: "signed_in" } });
  });

  it("holds an address the server told to wait until its retry-after, counting it down", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/login", () =>
          api.seen("POST", "/v1/comma/auth/email/login").length === 1
            ? {
                status: 429,
                headers: [
                  ["content-type", "application/json"],
                  ["retry-after", "35"],
                ],
                body: new TextEncoder().encode(
                  JSON.stringify({ error: "rate_limited" })
                ),
              }
            : json(200, { challenge_id: "challenge-1" })
        );
      },
    });
    await startedSignedOut(t);
    const request = (email: string) =>
      t.run(t.lifecycle.requestEmailLogin({ email, expected: t.expected() as never }));
    expect(await request("person@example.com")).toMatchObject({
      ok: false,
      error: { code: "rate_limited", retryAfterMs: 35_000 },
    });
    expect(t.core.session.value().emailCooldown).toEqual({
      email: "person@example.com",
      seconds: 35,
    });
    await t.time.pass(10_000);
    expect(t.core.session.value().emailCooldown).toMatchObject({ seconds: 25 });
    expect(await request("person@example.com")).toMatchObject({
      ok: false,
      error: { code: "rate_limited" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);

    await t.time.pass(25_000);
    expect(t.core.session.value().emailCooldown).toBeNull();
    expect(await request("person@example.com")).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-1" },
    });
  });

  it("holds a replacement's failure until the sign-in it superseded has settled, and queues that one's credential", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api, () =>
          issuedSession({
            sessionId: "session-superseded",
            token: "secret-superseded",
            userId: "user-superseded",
          })
        );
        api.on(
          "POST",
          "/v1/comma/auth/logout",
          offline("the revocation does not get through")
        );
        api.on("POST", "/v1/comma/auth/email/login", () =>
          api.seen("POST", "/v1/comma/auth/email/login").length === 2
            ? json(429, { error: "rate_limited" })
            : json(200, { challenge_id: "challenge-1" })
        );
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "first@example.com");
    const release = t.api.hold("POST", "/v1/comma/auth/email/verify");
    const verification = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: first.attempt,
        challengeId: first.challengeId,
        code: "123456",
      })
    );
    await t.time.pass(10);
    let replacementSettled = false;
    const replacement = t
      .start(
        t.lifecycle.requestEmailLogin({
          email: "replacement@example.com",
          expected: first.attempt.expected,
        })
      )
      .finally(() => (replacementSettled = true));
    await t.time.pass(50);
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(2);
    expect(replacementSettled).toBe(false);

    release();
    await t.time.pass(50);
    expect(await verification).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(await replacement).toMatchObject({
      ok: false,
      error: { code: "rate_limited" },
    });
    expect(t.main.pending).toEqual([
      expect.objectContaining({
        sessionId: "session-superseded",
        token: "secret-superseded",
      }),
    ]);
  });

  it("settles signed out when a retryable Google start fails, and lets the next one start", async () => {
    const t = setup({
      before: ({ api }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", () =>
          api.seen("POST", "/v1/comma/auth/google/attempt").length === 1
            ? json(429, { error: "rate_limited" })
            : json(200, googleAttempt)
        );
        api.on("POST", "/v1/comma/auth/google", {
          challenge_id: "link-challenge",
          email: "person@example.com",
          status: "otp_required",
        });
      },
    });
    await startedSignedOut(t);
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({
      ok: false,
      error: { code: "rate_limited", retryable: true },
    });
    expect(t.state().phase).toBe("signed_out");
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({
      ok: true,
      value: { challengeId: "link-challenge", status: "otp_required" },
    });
  });

  it("keeps the attempt after a wrong code, so the right one signs in", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/verify", () =>
          api.seen("POST", "/v1/comma/auth/email/verify").length === 1
            ? json(401, { error: "invalid_verification_code" })
            : json(200, issuedSession())
        );
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t);
    const input = { attempt: challenge.attempt, challengeId: challenge.challengeId };
    expect(
      await t.run(t.lifecycle.verifyEmailLogin({ ...input, code: "000000" }))
    ).toMatchObject({
      ok: false,
      error: {
        code: "invalid_challenge",
        recovery: "retry_operation",
        retryable: true,
      },
    });
    expect(t.state().phase).toBe("authenticating");
    expect(
      await t.run(t.lifecycle.verifyEmailLogin({ ...input, code: "123456" }))
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
  });

  it("does not send a code the server refused for the challenge again, and lets a code that got no answer go again", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        api.on("POST", "/v1/comma/auth/email/verify", (request: SeenRequest) => {
          const { code } = request.body as { code?: string };
          if (code === "000000")
            return json(401, { error: "invalid_verification_code" });
          // The first try of the right code does not get through.
          return api.seen("POST", "/v1/comma/auth/email/verify").length === 2
            ? offline("the verification does not get through")
            : json(200, issuedSession());
        });
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t);
    const verify = (code: string) =>
      t.ask("session.email.verify", {
        attempt: challenge.attempt,
        challengeId: challenge.challengeId,
        code,
      });
    const retrySameCode = () =>
      t.core.session.value().attempt?.challenge?.retrySameCode;
    expect(await verify("000000")).toMatchObject({
      ok: false,
      error: { code: "invalid_challenge" },
    });
    expect(retrySameCode()).toBeUndefined();
    // The refused code typed again: the same answer, no request.
    expect(await verify("000000")).toMatchObject({
      ok: false,
      error: { code: "invalid_challenge" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")).toHaveLength(1);
    expect(await verify("123456")).toMatchObject({
      ok: false,
      error: { code: "network_unavailable" },
    });
    expect(retrySameCode()).toBe(true);
    expect(await verify("123456")).toMatchObject({
      ok: true,
      value: { phase: "signed_in" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")).toHaveLength(3);
  });

  it("lets only one verification of a challenge run at a time", async () => {
    const t = setup({ before: ({ api }) => serveEmail(api) });
    await startedSignedOut(t);
    const challenge = await requested(t);
    const input = {
      attempt: challenge.attempt,
      challengeId: challenge.challengeId,
      code: "123456",
    };
    const release = t.api.hold("POST", "/v1/comma/auth/email/verify");
    const first = t.start(t.lifecycle.verifyEmailLogin(input));
    await t.time.pass(10);
    expect(await t.run(t.lifecycle.verifyEmailLogin(input))).toMatchObject({
      ok: false,
      error: { code: "conflict" },
    });
    release();
    await t.time.pass(20);
    expect(await first).toMatchObject({ ok: true, value: { phase: "signed_in" } });
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")).toHaveLength(1);
  });

  it("queues a credential whose commit a replacement sign-in overtook, and commits the replacement's", async () => {
    const t = setup({
      before: ({ api }) =>
        serveEmail(api, (body) =>
          body.code === "111111"
            ? issuedSession({
                sessionId: "session-first",
                token: "secret-first",
                userId: "user-first",
              })
            : issuedSession({
                sessionId: "session-replacement",
                token: "secret-replacement",
                userId: "user-replacement",
              })
        ),
    });
    await startedSignedOut(t);
    const first = await requested(t, "first@example.com");
    const releaseCommit = t.main.holdNext("commit");
    const firstVerification = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: first.attempt,
        challengeId: first.challengeId,
        code: "111111",
      })
    );
    await t.time.pass(20);
    expect(t.main.changes).toContain("commit");

    const replacement = await t.run(
      t.lifecycle.requestEmailLogin({
        email: "replacement@example.com",
        expected: first.attempt.expected,
      })
    );
    if (!replacement.ok) throw new Error("Expected a replacement attempt.");
    releaseCommit();
    await t.time.pass(20);
    expect(await firstVerification).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });

    expect(
      await t.run(
        t.lifecycle.verifyEmailLogin({
          attempt: replacement.value.attempt,
          challengeId: replacement.value.challengeId,
          code: "222222",
        })
      )
    ).toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        principal: { userId: "user-replacement" },
        session: { sessionId: "session-replacement" },
      },
    });
    expect(t.main.active).toMatchObject({
      sessionId: "session-replacement",
      token: "secret-replacement",
    });
    // The overtaken commit landed first; it was queued for revocation, and revoked at the server.
    await t.time.pass(50);
    expect(t.logouts()).toEqual(["secret-first"]);
    expect(t.main.pending).toEqual([]);
  });

  it("queues an overtaken credential nothing else could revoke in the same write that commits its replacement", async () => {
    const t = setup({
      before: ({ api, main }) => {
        serveEmail(api, (body) =>
          body.code === "111111"
            ? issuedSession({
                sessionId: "session-a",
                token: "secret-a",
                userId: "user-a",
              })
            : issuedSession({
                sessionId: "session-b",
                token: "secret-b",
                userId: "user-b",
              })
        );
        api.on(
          "POST",
          "/v1/comma/auth/logout",
          offline("injected direct cleanup failure")
        );
        main.failNext("quarantine");
      },
    });
    await startedSignedOut(t);
    const first = await requested(t, "a@example.com");
    const releaseFirstCommit = t.main.holdNext("commit", "fail");
    const firstCommit = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: first.attempt,
        challengeId: first.challengeId,
        code: "111111",
      })
    );
    await t.time.pass(20);
    const replacement = await t.run(
      t.lifecycle.requestEmailLogin({
        email: "b@example.com",
        expected: first.attempt.expected,
      })
    );
    if (!replacement.ok) throw new Error("Expected a replacement attempt.");
    const replacementCommit = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: replacement.value.attempt,
        challengeId: replacement.value.challengeId,
        code: "222222",
      })
    );
    await t.time.pass(20);
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")).toHaveLength(2);

    releaseFirstCommit();
    await t.time.pass(50);
    expect(await firstCommit).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(await replacementCommit).toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        principal: { userId: "user-b" },
        session: { sessionId: "session-b" },
      },
    });
    expect(t.main.active).toMatchObject({ sessionId: "session-b", token: "secret-b" });
    expect(t.main.pending).toEqual([
      expect.objectContaining({
        audience: audienceA,
        sessionId: "session-a",
        token: "secret-a",
      }),
    ]);
  });

  it("leaves a cancelled sign-in undecided when its issued credential cannot be queued or revoked", async () => {
    const t = setup({
      before: ({ api, main }) => {
        serveEmail(api, () =>
          issuedSession({ sessionId: "session-a", token: "secret-a", userId: "user-a" })
        );
        api.on(
          "POST",
          "/v1/comma/auth/logout",
          offline("injected direct cleanup failure")
        );
        for (let i = 0; i < 3; i++) main.failNext("quarantine");
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t, "a@example.com");
    const releaseCommit = t.main.holdNext("commit", "fail");
    const verification = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: challenge.attempt,
        challengeId: challenge.challengeId,
        code: "111111",
      })
    );
    await t.time.pass(20);
    const cancellation = t.start(
      t.lifecycle.cancelAuthAttempt({ attempt: challenge.attempt })
    );
    await t.time.pass(0);
    expect(t.state().phase).toBe("signing_out");
    releaseCommit();
    await t.time.pass(50);

    expect(await verification).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(await cancellation).toMatchObject({
      ok: false,
      error: { code: "credential_mutation_uncertain" },
    });
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_mutation_uncertain", operation: "authenticate" },
    });
    expect(t.main.active).toBeNull();
    // Main still holds the bearer: nothing has settled it (Main's own close refuses to exit with it).
    expect([...t.main.issued.values()].map((c) => c.token)).toEqual(["secret-a"]);
  });

  it("lets sign-out win over a sign-in whose answer comes late, and queues that credential", async () => {
    const t = setup({ before: ({ api }) => serveEmail(api) });
    await startedSignedOut(t);
    const challenge = await requested(t);
    const release = t.api.hold("POST", "/v1/comma/auth/email/verify");
    const verification = t.start(
      t.lifecycle.verifyEmailLogin({
        attempt: challenge.attempt,
        challengeId: challenge.challengeId,
        code: "123456",
      })
    );
    await t.time.pass(10);
    const signOut = t.start(
      t.lifecycle.signOut({ expected: challenge.attempt.expected })
    );
    await t.time.pass(0);
    expect(t.state().phase).toBe("signing_out");

    release();
    await t.time.pass(50);
    expect(await signOut).toMatchObject({ ok: true, value: { phase: "signed_out" } });
    expect(await verification).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(t.main.active).toBeNull();
    // Queued, then revoked by the drain that followed the sign-out.
    expect(t.logouts()).toContain("issued_secret");
    expect(t.state().phase).toBe("signed_out");
  });

  it("closes Main's gate before the sign-out's revocation at the server ends", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.on("POST", "/v1/comma/auth/logout", json(200, { signed_out: true }));
      },
    });
    await t.time.pass(20);
    const lease = t.core.session.lease()!;
    expect(t.main.admits(lease)).toBe(true);
    const release = t.api.hold("POST", "/v1/comma/auth/logout");

    const signedOut = await t.ask("session.signOut", { expected: t.expected() });
    expect(signedOut).toMatchObject({
      ok: true,
      value: {
        cleanup: { revocation: "pending" },
        phase: "signed_out",
        reason: "user_signed_out",
      },
    });
    expect(t.main.pending).toEqual([expect.objectContaining({ token: "main_secret" })]);
    expect(t.main.active).toBeNull();
    expect(t.main.admits(lease)).toBe(false);
    expect(t.logouts()).toEqual(["main_secret"]);

    release();
    await t.time.pass(20);
    expect(t.main.pending).toEqual([]);
    expect(t.state().cleanup).toEqual({ revocation: "idle" });
  });

  it("revokes a credential queued while an earlier revocation is under way", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.on("POST", "/v1/comma/auth/logout", json(200, { signed_out: true }));
      },
    });
    await t.time.pass(20);
    const release = t.api.hold("POST", "/v1/comma/auth/logout");
    await t.ask("session.signOut", { expected: t.expected() });
    t.main.pending.push(
      storedCredential({ sessionId: "late-session", token: "late-session-secret" })
    );
    const drain = t.start(t.lifecycle.retryPendingRevocations());
    release();
    await t.time.pass(20);
    await drain;
    expect(t.logouts()).toEqual(["main_secret", "late-session-secret"]);
    expect(t.main.pending).toEqual([]);
    expect(t.state().cleanup).toEqual({ revocation: "idle" });
  });

  it("gives up a revocation that hangs after 5 s and keeps its record", async () => {
    const t = setup({
      pending: [storedCredential({ sessionId: "hung-session", token: "hung-secret" })],
      before: ({ api }) =>
        api.on("POST", "/v1/comma/auth/logout", () => new Promise(() => {})),
    });
    await t.time.pass(5_100);
    expect(t.logouts()).toEqual(["hung-secret"]);
    expect(t.main.pending).toEqual([expect.objectContaining({ token: "hung-secret" })]);
    expect(t.state().cleanup).toEqual({ revocation: "pending", pendingCount: 1 });
  });

  it("drops a revocation the server answers 401 and keeps one it refuses otherwise", async () => {
    const t = setup({
      pending: [
        storedCredential({
          sessionId: "already-revoked-session",
          token: "already-revoked",
        }),
        storedCredential({ sessionId: "forbidden-session", token: "forbidden" }),
      ],
      before: ({ api }) =>
        api.on("POST", "/v1/comma/auth/logout", (request: SeenRequest) =>
          bearer(request) === "already-revoked"
            ? json(401, { error: "unauthorized" })
            : json(403, { error: "forbidden" })
        ),
    });
    await t.time.pass(50);
    expect(t.main.pending).toEqual([
      expect.objectContaining({ sessionId: "forbidden-session", token: "forbidden" }),
    ]);
    expect(t.state().cleanup).toEqual({ revocation: "pending", pendingCount: 1 });
  });

  it("keeps a revoked record whose removal fails, and goes on with the others", async () => {
    const t = setup({
      pending: [
        storedCredential({ sessionId: "write-failed-session", token: "write-failed" }),
        storedCredential({
          sessionId: "later-session",
          token: "later-already-revoked",
        }),
      ],
      before: ({ api, main }) => {
        api.on("POST", "/v1/comma/auth/logout", json(401, { error: "unauthorized" }));
        main.failNext("revoked");
      },
    });
    await t.time.pass(50);
    expect(t.logouts()).toEqual(["write-failed", "later-already-revoked"]);
    expect(t.main.pending).toEqual([
      expect.objectContaining({
        sessionId: "write-failed-session",
        token: "write-failed",
      }),
    ]);
  });

  it("revokes at the server a credential Main could neither keep nor queue", async () => {
    const t = setup({
      before: ({ api, main }) => {
        serveEmail(api, () => issuedSession({ token: "unaccepted-secret" }));
        main.failNext("commit");
        main.failNext("quarantine");
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t);
    const result = await t.run(
      t.lifecycle.verifyEmailLogin({
        attempt: challenge.attempt,
        challengeId: challenge.challengeId,
        code: "123456",
      })
    );
    expect(result).toMatchObject({
      ok: false,
      error: { code: "credential_mutation_uncertain", recovery: "reconcile" },
    });
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_mutation_uncertain", operation: "authenticate" },
    });
    expect(t.logouts()).toEqual(["unaccepted-secret"]);
    expect(t.main.pending).toEqual([]);
    expect(t.main.active).toBeNull();
    expect(t.main.issued.size).toBe(0);
  });

  it("keeps a credential nothing could settle, and settles it on the next retry before showing signed out", async () => {
    const t = setup({
      before: ({ api, main }) => {
        serveEmail(api, () =>
          issuedSession({ sessionId: "session-a", token: "secret-a", userId: "user-a" })
        );
        api.on(
          "POST",
          "/v1/comma/auth/logout",
          offline("injected direct cleanup failure")
        );
        main.failNext("commit");
        main.failNext("quarantine");
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t, "a@example.com");
    expect(
      await t.run(
        t.lifecycle.verifyEmailLogin({
          attempt: challenge.attempt,
          challengeId: challenge.challengeId,
          code: "111111",
        })
      )
    ).toMatchObject({ ok: false, error: { code: "credential_mutation_uncertain" } });
    expect(t.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_mutation_uncertain", operation: "authenticate" },
    });
    expect(t.main.pending).toEqual([]);
    expect(t.logouts()).toEqual(["secret-a"]);

    expect(
      await t.run(t.lifecycle.reconcile({ reason: "manual_retry" }))
    ).toMatchObject({
      ok: true,
      value: { cleanup: { revocation: "pending" }, phase: "signed_out" },
    });
    expect(t.main.pending).toEqual([
      expect.objectContaining({
        audience: audienceA,
        sessionId: "session-a",
        token: "secret-a",
      }),
    ]);
    expect(t.main.issued.size).toBe(0);
  });

  // --- The boundary with Main --------------------------------------------------------------------------------------

  it("never has a bearer among what it was told, sent or kept, through sign-in, a probe, a refusal and sign-out", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        serveSessions(api, { issued_secret: currentSession() });
        api.on("POST", PRODUCT_PATH, json(200, { cleared: true }));
      },
    });
    await startedSignedOut(t);
    const challenge = await requested(t);
    await t.run(
      t.lifecycle.verifyEmailLogin({
        attempt: challenge.attempt,
        challengeId: challenge.challengeId,
        code: "123456",
      })
    );
    await t.ask("session.reconcile", { reason: "focus" });
    expect(Result.isSuccess(await t.product())).toBe(true);
    await t.ask("session.signOut", { expected: t.expected() });
    await t.time.pass(50);

    // The server saw the bearer, from Main; the core's whole log (every input, output and answer) never did.
    expect(t.api.seen("GET", "/v1/comma/auth/session").map(bearer)).toEqual([
      "issued_secret",
    ]);
    expect(t.logouts()).toEqual(["issued_secret"]);
    const log = t.core.recorder!.dump();
    expect(log).not.toContain("issued_secret");
    expect(log).not.toContain("Bearer");
    expect(JSON.stringify(t.core.session.value())).not.toContain("issued_secret");
    expect(JSON.stringify(t.main.told)).not.toContain("issued_secret");
  });

  it("moves Main's gate before any window or request acts on a new generation, and Main refuses the old one", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.on("POST", PRODUCT_PATH, json(200, { cleared: true }));
        api.on("POST", "/v1/comma/auth/logout", json(200, { signed_out: true }));
      },
    });
    await t.time.pass(20);
    const first = t.core.session.lease()!;
    expect(t.main.admits(first)).toBe(true);
    expect(Result.isSuccess(await t.product())).toBe(true);

    // A window's request made with the lease it saw is refused by Main once the core moved past it: the gate moved
    // in the same step the core published, before any window heard of it.
    t.core.hostRejected({ ...first }, 401);
    expect(t.main.admits(first)).toBe(false);
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    const outputs = t.core.recorder!.outputs;
    for (const [i, output] of outputs.entries()) {
      if (output.kind !== "emit") continue;
      const revision = JSON.stringify(output.message).match(/"revision":(\d+)/)?.[1];
      if (!revision) continue;
      const told = outputs
        .slice(0, i)
        .some(
          (o) =>
            o.kind === "gate" &&
            (o.snapshot as SessionLifecycleSnapshot).revision >= Number(revision)
        );
      expect(told).toBe(true);
    }
    expect(t.main.told.at(-1)).toMatchObject({
      lease: null,
      snapshot: { phase: "signed_out" },
    });
    // Main's refusal reaches the core as a refused request (409 lease unavailable), and it runs nothing for it.
    expect(t.api.seen("POST", PRODUCT_PATH)).toHaveLength(1);
  });

  it("goes on with the lease Main kept when the core restarts and finds the same session", async () => {
    const time = new TestTime();
    const api = new FakeCommaApi();
    serveSessions(api, { main_secret: currentSession() });
    const before = setup({ stored: storedCredential(), api, time });
    await time.pass(20);
    const lease = before.core.session.lease()!;
    const told = before.main.told.length;
    // The core's process went: Main keeps its gate, read only, and serves the lease it confirmed.
    before.core.close();
    expect(before.main.admits(lease)).toBe(true);

    const after = setup({
      stored: before.main.active!,
      api,
      time,
      resumed: before.main.resume()!,
    });
    expect(after.main.told).toEqual([]);
    await time.pass(20);
    expect(after.state()).toMatchObject({
      authority: { authorityInstanceId: lease.authorityInstanceId },
      generation: lease.generation,
      phase: "signed_in",
    });
    expect(after.main.gateLease()).toEqual(lease);
    // The restart never closed the gate it kept.
    expect(after.main.told.every((t) => t.lease !== null)).toBe(true);
    expect(told).toBeGreaterThan(0);
  });

  it("opens a new generation after a restart when Main closed its gate on a 401 while the core was away", async () => {
    const time = new TestTime();
    const api = new FakeCommaApi();
    serveSessions(api, { main_secret: currentSession() });
    const before = setup({ stored: storedCredential(), api, time });
    await time.pass(20);
    const lease = before.core.session.lease()!;
    before.core.close();
    // Main saw a 401 while no core ran: its gate closed fail-closed (the session it hands over is none).
    const resumed = { ...before.main.resume()!, sessionId: null };

    const after = setup({ stored: before.main.active!, api, time, resumed });
    await time.pass(20);
    expect(after.state()).toMatchObject({
      generation: lease.generation + 1,
      phase: "signed_in",
    });
    expect(after.main.gateLease()).toMatchObject({ generation: lease.generation + 1 });
  });

  it("keeps a signed-in session through a focus probe that cannot reach the server, and probes again after 1 s", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => serveSessions(api, { main_secret: currentSession() }),
    });
    await t.time.pass(20);
    const lease = t.core.session.lease();
    t.api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" }));
    expect(await t.ask("session.reconcile", { reason: "focus" })).toMatchObject({
      ok: false,
      error: { code: "session_probe_unavailable" },
    });
    expect(t.state().phase).toBe("signed_in");
    expect(t.core.session.lease()).toBe(lease);
    serveSessions(t.api, { main_secret: currentSession() });
    await t.time.pass(1_000);
    expect(t.api.seen("GET", "/v1/comma/auth/session")).toHaveLength(3);
    expect(t.core.session.lease()).toBe(lease);
  });

  it("refuses session calls from a window its host does not let sign in or out, and hears its refusals", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => serveSessions(api, { main_secret: currentSession() }),
    });
    await t.time.pass(20);
    // A window that may not sign in or out: Main hands its channel over without the session.
    const side = new CoreClient(
      (onMessage) => {
        const client = t.core.connect("win_side", { session: false });
        t.host.listen(client, (message) => queueMicrotask(() => onMessage(message)));
        return {
          post: (message) =>
            queueMicrotask(() => t.core.receive(client, structuredClone(message))),
          close: () => t.core.disconnect(client),
        };
      },
      { schedule: () => undefined }
    );
    const refused = expect(
      side.call("session.signOut", { expected: t.expected() })
    ).rejects.toMatchObject({ code: "forbidden" });
    await t.time.pass(20);
    await refused;
    expect(t.state().phase).toBe("signed_in");
    const lease = t.core.session.lease()!;
    const rejected = side.call("session.rejected", {
      generation: lease.generation,
      sessionId: lease.sessionId,
      status: 401,
    });
    await t.time.pass(20);
    await rejected;
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    side.close();
  });

  it("plays a recorded sign-in again to the same outputs", async () => {
    const t = setup({
      before: ({ api }) => {
        serveEmail(api);
        serveSessions(api, { issued_secret: currentSession() });
      },
    });
    await startedSignedOut(t);
    // Only what a window asked is in the log: the sign-in goes through the calls.
    const challenge = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string };
    }>("session.email.request", { email: "peng@example.com", expected: t.expected() });
    await t.ask("session.email.verify", {
      attempt: challenge.value.attempt,
      challengeId: challenge.value.challengeId,
      code: "123456",
    });
    await t.ask("session.reconcile", { reason: "focus" });
    await t.time.pass(50);
    const recorded = t.core.recorder!;
    const again = await replay(recorded, {
      sessionSource: "core",
      coalesceMs: 0,
      until: t.time.now(),
    });
    // The same outputs at the same times; within one instant, a forked revocation drain and a call's answer may
    // interleave either way.
    expect(byTime(again.outputs)).toEqual(byTime(recorded.outputs));
    expect(again.core.electronSession!.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: "session-1" },
    });
  });
});
