// The Electron session lifecycle in the core (session/electron-lifecycle.ts): what Main's session service did, on a
// TestClock, against Main as the core sees it (testing/fake-main.ts: the credential store by reference, the bearers
// kept out of the core, the gate, the Google window) and a server that sees the bearer Main attaches.
import { createHash } from "node:crypto";
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

function watchAccountValues(client: CoreClient) {
  const values: Record<string, unknown> = {};
  for (const topic of ["workspace", "onboardingWorkspace", "profile"]) {
    client.subscribe(
      { topic },
      (value) => {
        values[topic] = value;
      },
      () => undefined
    );
  }
  return values;
}

describe("the Electron session lifecycle", () => {
  it.each(["electron", "ios", "android"] as const)(
    "restores the %s account before the startup probe answers, and keeps its lease after confirmation",
    async (kind) => {
      let release!: () => void;
      const t = setup({
        stored: storedCredential(),
        ios: kind === "ios",
        android: kind === "android",
        before: ({ api }) => {
          serveSessions(api, { main_secret: currentSession() });
          release = api.hold("GET", "/v1/comma/auth/session");
        },
      });
      await t.time.pass(20);
      expect(t.state()).toMatchObject({
        phase: "signed_in",
        principal: { userId: "user-1" },
      });
      const account = t.core.session.current();
      const lease = t.core.session.lease();
      expect(account).not.toBeNull();
      expect(lease).not.toBeNull();
      expect(t.main.gateLease()).not.toBeNull();
      release();
      await t.time.pass(20);
      expect(t.core.session.current()).toBe(account);
      expect(t.core.session.lease()).toBe(lease);
      expect(t.main.leaks(t.core.recorder!.dump())).toEqual([]);
    }
  );

  it.each(["503", "offline", "timeout"] as const)(
    "keeps the restored account through a startup %s and reconnects in the background",
    async (failure) => {
      const t = setup({
        stored: storedCredential(),
        before: ({ api }) => {
          api.on(
            "GET",
            "/v1/comma/auth/session",
            failure === "offline"
              ? offline("network down")
              : json(503, { error: "unavailable" })
          );
          if (failure === "timeout") api.holdBody("GET", "/v1/comma/auth/session");
        },
      });
      await t.time.pass(failure === "timeout" ? 5_020 : 20);
      expect(t.state().phase).toBe("signed_in");
      const account = t.core.session.current();
      const lease = t.core.session.lease();
      expect(account).not.toBeNull();
      expect(t.core.session.withheld()).toBe(false);
      expect(lease).not.toBeNull();
      expect(t.main.active?.token).toBe("main_secret");
      // Stop holding response bodies before the background retry.
      serveSessions(t.api, { main_secret: currentSession() });
      await t.time.pass(1_100, 100);
      expect(t.api.seen("GET", "/v1/comma/auth/session").length).toBeGreaterThan(1);
      expect(t.state().phase).toBe("signed_in");
      expect(t.core.session.current()).toBe(account);
      expect(t.core.session.lease()).toBe(lease);
      expect(t.host.deleted).toEqual([]);
    }
  );

  it("opens the saved workspace and profile after a cold restart with no network", async () => {
    const workspace = {
      id: "wsp_1",
      group_id: "grp_1",
      name: "Saved",
      status: "ready",
    };
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, { main_secret: currentSession() });
        api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
        api.on("POST", "/v1/comma/me/bootstrap", { status: "ready", workspace });
        api.on("GET", "/v1/comma/me/profile", {
          id: "user-1",
          email: "peng@example.com",
          name: "Saved name",
        });
      },
    });
    const first = watchAccountValues(t.client);
    await t.time.pass(100);
    expect(first.onboardingWorkspace).toMatchObject({
      status: "ready",
      workspaceId: "wsp_1",
    });
    expect(first.profile).toMatchObject({ profile: { name: "Saved name" } });
    t.client.close();
    t.core.close();
    for (const [method, path] of [
      ["GET", "/v1/comma/auth/session"],
      ["GET", "/v1/comma/workspaces"],
      ["POST", "/v1/comma/me/bootstrap"],
      ["GET", "/v1/comma/me/profile"],
    ] as const)
      t.api.on(method, path, offline("network down"));
    // Force the database to finish opening after subscriptions, as on a cold native launch.
    t.host.openDbMs = 50;
    const again = harness(startTestCore(t.host, { coalesceMs: 0 }), t.host, t.main);
    const saved = watchAccountValues(again.client);
    await t.time.pass(200);
    expect(again.state().phase).toBe("signed_in");
    expect(saved.profile).toMatchObject({ profile: { name: "Saved name" } });
    expect(saved.workspace).toMatchObject({
      workspace: { id: "wsp_1", name: "Saved" },
    });
    expect(saved.onboardingWorkspace).toMatchObject({
      status: "ready",
      workspaceId: "wsp_1",
    });
    expect(t.host.deleted).toEqual([]);
  });

  it("signs out while the startup check cannot reach the server and queues revocation", async () => {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) =>
        api.on("GET", "/v1/comma/auth/session", json(503, { error: "unavailable" })),
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("signed_in");
    expect(await t.run(t.lifecycle.signOut({ expected: t.expected() }))).toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });
    expect(t.main.active).toBeNull();
    expect(t.main.pending.map((pending) => pending.token)).toEqual(["main_secret"]);
    expect(t.core.session.current()).toBeNull();
  });

  it("closes the restored account when the startup probe explicitly refuses its credential", async () => {
    let release!: () => void;
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveSessions(api, {});
        release = api.hold("GET", "/v1/comma/auth/session");
      },
    });
    await t.time.pass(20);
    expect(t.state().phase).toBe("signed_in");
    release();
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    expect(t.main.active).toBeNull();
    expect(t.main.gateLease()).toBeNull();
    expect(t.core.session.current()).toBeNull();
    expect(t.host.deleted).toHaveLength(1);
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
            native_proof: true,
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
            native_proof: true,
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

  it("uses the iOS Google attempt and native ID token through the same session chain", async () => {
    const t = setup({
      ios: true,
      before: ({ api, main }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", (request) => {
          expect(request.body).toEqual({ platform: "ios" });
          return json(200, { ...googleAttempt, platform: "ios" });
        });
        main.google = (input) => {
          expect(input).toEqual({ clientId: "desktop-client", nonce: "backend-nonce" });
          return Effect.succeed({ idToken: "ios-id-token", grant: "" });
        };
        api.on("POST", "/v1/comma/auth/google", (request) => {
          expect(request.body).toEqual({
            attempt_id: googleAttempt.attempt_id,
            nonce: "backend-nonce",
            credential: "ios-id-token",
            native_proof: true,
            client_kind: "ios",
            client_platform: "ios",
          });
          return json(200, issuedSession());
        });
      },
    });
    await startedSignedOut(t);
    const result = await t.ask("session.google.desktop", { expected: t.expected() });
    expect(result).toMatchObject({ ok: true, value: { status: "signed_in" } });
    expect(JSON.stringify(result)).not.toContain("issued_secret");
    expect(t.main.active?.token).toBe("issued_secret");
  });

  it("treats a closed Google sheet as cancellation without exchanging a token", async () => {
    const t = setup({
      ios: true,
      before: ({ api, main }) => {
        api.on("POST", "/v1/comma/auth/google/attempt", {
          ...googleAttempt,
          platform: "ios",
        });
        main.google = () => Effect.fail(new HostError("cancelled"));
      },
    });
    await startedSignedOut(t);
    expect(
      await t.ask("session.google.desktop", { expected: t.expected() })
    ).toMatchObject({
      ok: false,
      error: { code: "cancelled" },
    });
    expect(t.state().phase).toBe("signed_out");
    expect(t.main.active).toBeNull();
    expect(t.api.seen("POST", "/v1/comma/auth/google")).toHaveLength(0);
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

    const release = api.hold("GET", "/v1/comma/auth/session");
    const after = setup({ stored: before.main.active!, api, time, resumed });
    await time.pass(20);
    expect(after.core.session.lease()).toBeNull();
    release();
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

describe("accounts kept signed in on a bearer device", () => {
  const first = "account-api.comma.test-user-1";
  const second = "account-api.comma.test-user-2";

  /** Signed in as user-1 (stored), with the server knowing user-2's sign-in by emailed code too. */
  async function signedInAsFirst() {
    const t = setup({
      stored: storedCredential(),
      before: ({ api }) => {
        serveEmail(api, () =>
          issuedSession({
            sessionId: "session-2",
            token: "second_secret",
            userId: "user-2",
          })
        );
        serveSessions(api, {
          main_secret: currentSession(),
          second_secret: {
            ...currentSession(),
            session_id: "session-2",
            user: { ...currentSession().user, id: "user-2" },
          },
        });
      },
    });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({
      phase: "signed_in",
      principal: { userId: "user-1" },
    });
    return t;
  }

  /** Adds user-2: the account in use set aside, then signed in by emailed code. */
  async function addSecond(t: Setup) {
    const added = await t.ask<{ ok: boolean }>("session.addAccount", {
      expected: t.expected(),
    });
    expect(added).toMatchObject({ ok: true, value: { phase: "signed_out" } });
    const challenge = await requested(t);
    const verified = await t.ask<{ ok: boolean }>("session.email.verify", {
      attempt: challenge.attempt,
      challengeId: challenge.challengeId,
      code: "123456",
    });
    expect(verified).toMatchObject({
      ok: true,
      value: { phase: "signed_in", principal: { userId: "user-2" } },
    });
  }

  it("adds an account and switches between the two without signing in again, keeping each one's data", async () => {
    const t = await signedInAsFirst();
    await addSecond(t);
    expect(t.core.session.value().accounts).toEqual([
      { userId: "user-1", email: "peng@example.com" },
    ]);
    expect(t.main.active?.token).toBe("second_secret");
    expect(t.main.kept.map((k) => k.token)).toEqual(["main_secret"]);
    expect([...t.host.dbs.keys()]).toEqual(expect.arrayContaining([first, second]));

    const switched = await t.ask("session.switchAccount", { userId: "user-1" });
    expect(switched).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
    expect(t.core.session.value()).toMatchObject({
      phase: "signed_in",
      userId: "user-1",
      accounts: [{ userId: "user-2", email: "peng@example.com" }],
    });
    expect(t.main.active?.token).toBe("main_secret");
    expect(t.main.kept.map((k) => k.token)).toEqual(["second_secret"]);
    expect(t.main.gateLease()).toMatchObject({ sessionId: "session-1" });
    // The switched-to session is confirmed by the server with its own credential; nothing is revoked.
    expect(t.api.seen("GET", "/v1/comma/auth/session").map(bearer).at(-1)).toBe(
      "main_secret"
    );
    expect(t.logouts()).toEqual([]);
    expect(t.host.deleted).toEqual([]);
    expect(t.main.leaks(t.core.recorder!.dump())).toEqual([]);
  });

  it("deletes only the data of the account that signs out, and of a kept one signed out of the device", async () => {
    const t = await signedInAsFirst();
    await addSecond(t);
    // Signing out the account in use: user-1 stays kept.
    await t.ask("session.signOut", { expected: t.expected() });
    expect(t.state()).toMatchObject({ phase: "signed_out" });
    expect(t.core.session.value().accounts).toEqual([
      { userId: "user-1", email: "peng@example.com" },
    ]);
    await t.time.pass(20);
    expect(t.host.deleted).toEqual([second]);
    expect(t.logouts()).toEqual(["second_secret"]);

    // The kept one signed out of the device too.
    const forgotten = await t.ask("session.signOutAccount", { userId: "user-1" });
    expect(forgotten).toEqual({ ok: true, value: null });
    await t.time.pass(20);
    expect(t.core.session.value().accounts).toEqual([]);
    expect(t.main.kept).toEqual([]);
    expect(t.logouts()).toEqual(["second_secret", "main_secret"]);
    expect(t.host.deleted).toEqual([second, first]);
  });

  it("switches from the sign-in page back to the account set aside, giving up the sign-in under way", async () => {
    const t = await signedInAsFirst();
    await t.ask("session.addAccount", { expected: t.expected() });
    await requested(t);
    expect(t.state().phase).toBe("authenticating");
    const switched = await t.ask("session.switchAccount", { userId: "user-1" });
    expect(switched).toMatchObject({ ok: true, value: { phase: "signed_in" } });
    expect(t.core.session.value().accounts).toEqual([]);
    expect(t.core.session.value().attempt).toBeNull();
    expect(t.main.active?.token).toBe("main_secret");
    expect(t.host.deleted).toEqual([]);
  });

  it("signs out a kept account whose session the server ended when it is switched to, keeping the others", async () => {
    const t = await signedInAsFirst();
    await addSecond(t);
    serveSessions(t.api, {
      second_secret: {
        ...currentSession(),
        session_id: "session-2",
        user: { ...currentSession().user, id: "user-2" },
      },
    });
    await t.ask("session.switchAccount", { userId: "user-1" });
    await t.time.pass(20);
    expect(t.state()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    expect(t.main.active).toBeNull();
    expect(t.core.session.value().accounts).toEqual([
      { userId: "user-2", email: "peng@example.com" },
    ]);
    expect(t.host.deleted).toEqual([first]);
  });

  it("replaces a kept account's credential when that account signs in again", async () => {
    const t = await signedInAsFirst();
    await addSecond(t);
    await t.ask("session.addAccount", { expected: t.expected() });
    expect(t.main.kept.map((k) => k.userId)).toEqual(["user-1", "user-2"]);
    serveEmail(t.api, () =>
      issuedSession({ sessionId: "session-3", token: "third_secret", userId: "user-1" })
    );
    const challenge = await requested(t);
    await t.ask("session.email.verify", {
      attempt: challenge.attempt,
      challengeId: challenge.challengeId,
      code: "123456",
    });
    await t.time.pass(20);
    expect(t.main.active?.token).toBe("third_secret");
    expect(t.main.kept.map((k) => k.userId)).toEqual(["user-2"]);
    expect(t.logouts()).toEqual(["main_secret"]);
    expect(t.host.deleted).toEqual([]);
  });

  it("refuses to add an account beyond the store's limit, and to switch to one it does not keep", async () => {
    const t = await signedInAsFirst();
    t.main.kept = Array.from({ length: 7 }, (_, i) =>
      storedCredential({
        token: `kept_${i}`,
        userId: `kept-${i}`,
        sessionId: `kept-${i}`,
      })
    );
    await t.ask("session.reconcile", { reason: "focus" });
    expect(t.core.session.value().accounts).toHaveLength(7);
    expect(await t.ask("session.addAccount", { expected: t.expected() })).toMatchObject(
      { ok: false, error: { code: "conflict" } }
    );
    expect(await t.ask("session.switchAccount", { userId: "nobody" })).toMatchObject({
      ok: false,
      error: { code: "conflict" },
    });
    expect(t.state()).toMatchObject({
      phase: "signed_in",
      principal: { userId: "user-1" },
    });
  });
});

describe("protected app authentication", () => {
  const challenge = (method: "native" | "captcha", id = "abuse_action_1") => ({
    id,
    secret: "private_action_secret",
    expires_at: 2_000_000_000,
    method,
    enforce: true,
    action: "email_login",
    email: "peng@example.com",
    pow_difficulty: 4,
    captcha_url: `${audienceA}/v1/comma/auth/captcha?challenge_id=${id}&action=email_login`,
  });

  it("sends native proof and bounded PoW before email delivery, then verifies OTP without another proof", async () => {
    let proofs = 0;
    const t = setup({
      android: true,
      before: ({ api, main }) => {
        serveEmail(api);
        const ports = main.host.bearerSession!;
        ports.sha256 = (inputs) =>
          Effect.succeed(
            inputs.map(
              (input) => new Uint8Array(createHash("sha256").update(input).digest())
            )
          );
        ports.abuseProof = () => {
          proofs += 1;
          return Effect.succeed({
            provider: "play",
            play_token: "scripted_play_evidence",
          });
        };
      },
    });
    await startedSignedOut(t);
    let delivered = 0;
    t.api.on("POST", "/v1/comma/auth/email/login", (request: SeenRequest) => {
      const body = request.body as {
        abuse?: {
          provider: string;
          pow_nonce: string;
          challenge_id: string;
          challenge_secret: string;
        };
      };
      if (!body.abuse)
        return json(428, {
          error: "native_proof_required",
          challenge: challenge("native"),
        });
      const proof = body.abuse;
      const digest = createHash("sha256")
        .update(
          `comma-abuse:${proof.challenge_id}:${proof.challenge_secret}:${proof.pow_nonce}`
        )
        .digest();
      expect(proof.provider).toBe("play");
      expect(digest[0]! & 0xf0).toBe(0);
      delivered += 1;
      return json(200, { challenge_id: "protected_email_code" });
    });
    const challengeResult = await t.run(
      t.lifecycle.requestEmailLogin({
        email: "peng@example.com",
        expected: t.expected() as never,
      })
    );
    expect(challengeResult.ok).toBe(true);
    if (!challengeResult.ok) return;
    expect(t.core.session.value().attempt?.captcha).toBeUndefined();
    const verified = await t.run(
      t.lifecycle.verifyEmailLogin({
        attempt: challengeResult.value.attempt,
        challengeId: challengeResult.value.challengeId,
        code: "123456",
      })
    );
    expect(verified.ok).toBe(true);
    expect([proofs, delivered]).toEqual([1, 1]);
    expect(t.main.active?.token).toBe("issued_secret");
    expect(JSON.stringify(t.core.session.value())).not.toContain("issued_secret");
    await t.core.close();
  });

  it.each(["valid", "invalid", "unavailable", "missing_configuration"] as const)(
    "observes native %s evidence without CAPTCHA and preserves the email sign-in flow",
    async (outcome) => {
      let proofCalls = 0;
      let hashes = 0;
      let captchas = 0;
      const t = setup({
        android: true,
        before: ({ api, main }) => {
          serveEmail(api);
          const ports = main.host.bearerSession!;
          ports.sha256 = (inputs) => {
            hashes += 1;
            return Effect.succeed(
              inputs.map(
                (input) => new Uint8Array(createHash("sha256").update(input).digest())
              )
            );
          };
          ports.abuseProof = (proofChallenge) => {
            proofCalls += 1;
            if (outcome === "missing_configuration")
              expect(proofChallenge.google_cloud_project_number).toBeUndefined();
            return outcome === "unavailable" || outcome === "missing_configuration"
              ? Effect.fail(new HostError("native provider unavailable or cancelled"))
              : Effect.succeed({
                  provider: "play",
                  play_token:
                    outcome === "valid" ? "valid-observation" : "invalid-observation",
                });
          };
          ports.captcha = () => {
            captchas += 1;
            return Effect.succeed("unexpected");
          };
        },
      });
      await startedSignedOut(t);
      let observed = 0;
      t.api.on("POST", "/v1/comma/auth/email/login", (request: SeenRequest) => {
        const body = request.body as {
          native_proof: boolean;
          abuse?: { provider: string; pow_nonce?: string; play_token?: string };
        };
        expect(body.native_proof).toBe(true);
        if (!body.abuse)
          return json(428, {
            error: "native_proof_required",
            challenge: {
              ...challenge("native"),
              enforce: false,
              ...(outcome === "missing_configuration"
                ? {}
                : { google_cloud_project_number: "123" }),
            },
          });
        observed += 1;
        expect(body.abuse.provider).toBe(
          outcome === "valid" || outcome === "invalid" ? "play" : "unavailable"
        );
        expect(body.abuse.pow_nonce).toMatch(/^[0-9]{1,20}$/);
        return json(200, { challenge_id: "observed_email_code" });
      });
      const observedRequest = await t.run(
        t.lifecycle.requestEmailLogin({
          email: "peng@example.com",
          expected: t.expected() as never,
        })
      );
      expect(observedRequest.ok).toBe(true);
      if (!observedRequest.ok) return;
      expect(
        await t.run(
          t.lifecycle.verifyEmailLogin({
            attempt: observedRequest.value.attempt,
            challengeId: observedRequest.value.challengeId,
            code: "123456",
          })
        )
      ).toMatchObject({ ok: true });
      expect([proofCalls, observed, captchas]).toEqual([1, 1, 0]);
      expect(hashes).toBeGreaterThan(0);
      expect(t.core.session.value().attempt?.captcha).toBeUndefined();
      expect(t.main.active?.token).toBe("issued_secret");
      await t.core.close();
    }
  );

  it("continues observed OAuth registration with its credential and native intent without CAPTCHA", async () => {
    const t = setup({ android: true });
    await startedSignedOut(t);
    t.api.on("POST", "/v1/comma/auth/google/attempt", {
      ...googleAttempt,
      platform: "android",
    });
    t.main.google = () =>
      Effect.succeed({ idToken: "provider_token", grant: "native_google" });
    t.api.on(
      "POST",
      "/v1/comma/auth/google",
      json(428, {
        error: "native_proof_required",
        challenge: { ...challenge("native"), action: "registration", enforce: false },
        registration_continuation: "observation_continuation",
      })
    );
    t.api.on("POST", "/v1/comma/auth/registration/complete", (request: SeenRequest) => {
      expect(request.body).toMatchObject({
        registration_continuation: "observation_continuation",
        native_proof: true,
        abuse: { provider: "unavailable" },
      });
      return json(200, issuedSession());
    });
    expect(
      await t.run(t.lifecycle.signInWithGoogle({ expected: t.expected() as never }))
    ).toMatchObject({ ok: true, value: { status: "signed_in" } });
    expect(t.core.session.value().attempt?.captcha).toBeUndefined();
    expect(t.api.seen("POST", "/v1/comma/auth/google")).toHaveLength(1);
    await t.core.close();
  });

  it("submits unavailable observation when the native SDK reaches its existing budget", async () => {
    let proofStarted = false;
    const t = setup({
      android: true,
      before: ({ api, main }) => {
        serveEmail(api);
        main.host.bearerSession!.sha256 = (inputs) =>
          Effect.succeed(
            inputs.map(
              (input) => new Uint8Array(createHash("sha256").update(input).digest())
            )
          );
        main.host.bearerSession!.abuseProof = () => {
          proofStarted = true;
          return Effect.never;
        };
      },
    });
    await startedSignedOut(t);
    t.api.on("POST", "/v1/comma/auth/email/login", (request: SeenRequest) => {
      const body = request.body as { abuse?: { provider: string } };
      if (!body.abuse)
        return json(428, {
          error: "native_proof_required",
          challenge: { ...challenge("native"), enforce: false },
        });
      expect(body.abuse.provider).toBe("unavailable");
      return json(200, { challenge_id: "timed_out_observation_code" });
    });
    const done = t.start(
      t.lifecycle.requestEmailLogin({
        email: "peng@example.com",
        expected: t.expected() as never,
      })
    );
    await t.time.pass(20);
    expect(proofStarted).toBe(true);
    await t.time.pass(29_979);
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);
    await t.time.pass(1);
    const outcome = await done;
    expect(outcome.ok).toBe(true);
    if (!outcome.ok) return;
    expect(
      await t.run(
        t.lifecycle.verifyEmailLogin({
          attempt: outcome.value.attempt,
          challengeId: outcome.value.challengeId,
          code: "123456",
        })
      )
    ).toMatchObject({ ok: true });
    expect(t.core.session.value().attempt?.captcha).toBeUndefined();
    await t.core.close();
  });

  it("cancels the whole auth attempt while observation waits without submitting unavailable evidence", async () => {
    const t = setup({
      android: true,
      before: ({ main }) => {
        main.host.bearerSession!.sha256 = (inputs) =>
          Effect.succeed(
            inputs.map(
              (input) => new Uint8Array(createHash("sha256").update(input).digest())
            )
          );
        main.host.bearerSession!.abuseProof = () => Effect.never;
      },
    });
    await startedSignedOut(t);
    t.api.on(
      "POST",
      "/v1/comma/auth/email/login",
      json(428, {
        error: "native_proof_required",
        challenge: { ...challenge("native"), enforce: false },
      })
    );
    const done = t.start(
      t.lifecycle.requestEmailLogin({
        email: "peng@example.com",
        expected: t.expected() as never,
      })
    );
    await t.time.pass(20);
    const attempt = t.core.session.value().attempt!;
    expect(
      await t.run(t.lifecycle.cancelAuthAttempt({ attempt: attempt.ref }))
    ).toMatchObject({ ok: true });
    expect(await done).toMatchObject({ ok: false, error: { code: "cancelled" } });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);
    expect(t.core.session.value().attempt?.captcha).toBeUndefined();
    await t.core.close();
  });

  it("keeps an OAuth continuation through native failure and CAPTCHA without another OAuth interaction", async () => {
    const t = setup({ android: true });
    await startedSignedOut(t);
    t.api.on("POST", "/v1/comma/auth/google/attempt", {
      ...googleAttempt,
      platform: "android",
    });
    t.main.google = () =>
      Effect.succeed({ idToken: "provider_token", grant: "native_google" });
    t.api.on(
      "POST",
      "/v1/comma/auth/google",
      json(428, {
        error: "native_proof_required",
        challenge: { ...challenge("native"), action: "registration" },
        registration_continuation: "registration_private_attempt",
      })
    );
    t.api.on("POST", "/v1/comma/auth/registration/complete", (request: SeenRequest) => {
      const body = request.body as {
        registration_continuation: string;
        abuse: { provider: string; captcha_token?: string };
      };
      expect(body.registration_continuation).toBe("registration_private_attempt");
      expect(body).not.toHaveProperty("credential");
      if (body.abuse.provider === "unavailable")
        return json(428, {
          error: "captcha_required",
          challenge: {
            ...challenge("captcha", "abuse_captcha_2"),
            action: "registration",
            captcha_url: `${audienceA}/v1/comma/auth/captcha?challenge_id=abuse_captcha_2&action=registration`,
          },
          registration_continuation: "registration_private_attempt",
        });
      expect(body.abuse.captcha_token).toBe("scripted_captcha_token");
      return json(200, issuedSession());
    });
    const done = t.start(
      t.lifecycle.signInWithGoogle({ expected: t.expected() as never })
    );
    await t.time.pass(30);
    const attempt = t.core.session.value().attempt!;
    expect(attempt.captcha?.challengeId).toBe("abuse_captcha_2");
    expect(JSON.stringify(attempt)).not.toContain("private_action_secret");
    expect(JSON.stringify(attempt)).not.toContain("registration_private_attempt");
    expect(
      await t.ask("session.captcha.answer", {
        attempt: attempt.ref,
        challengeId: "stale",
        token: "scripted_captcha_token",
      })
    ).toBe(false);
    expect(
      await t.ask("session.captcha.answer", {
        attempt: attempt.ref,
        challengeId: "abuse_captcha_2",
        token: "scripted_captcha_token",
      })
    ).toBe(true);
    expect((await done).ok).toBe(true);
    expect(t.api.seen("POST", "/v1/comma/auth/google")).toHaveLength(1);
    expect(t.main.active?.token).toBe("issued_secret");
    await t.core.close();
  });

  it("cancels a public CAPTCHA without making the protected send", async () => {
    const t = setup();
    await startedSignedOut(t);
    t.api.on(
      "POST",
      "/v1/comma/auth/email/login",
      json(428, { error: "captcha_required", challenge: challenge("captcha") })
    );
    const done = t.start(
      t.lifecycle.requestEmailLogin({
        email: "peng@example.com",
        expected: t.expected() as never,
      })
    );
    await t.time.pass(20);
    const attempt = t.core.session.value().attempt!;
    await t.ask("session.captcha.answer", {
      attempt: attempt.ref,
      challengeId: "abuse_action_1",
      token: null,
    });
    expect(await done).toMatchObject({ ok: false, error: { code: "cancelled" } });
    expect(t.api.seen("POST", "/v1/comma/auth/email/login")).toHaveLength(1);
    expect(t.main.active).toBeNull();
    await t.core.close();
  });
});
