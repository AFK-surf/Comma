import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sessionExpectation,
  sessionProductLease,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DesktopGoogleAuthProvider } from "../google-desktop-auth";

const electronMocks = vi.hoisted(() => ({
  encryptionAvailable: true,
  decryptString: vi.fn((value: Buffer) => value.toString("utf8")),
  encryptString: vi.fn((plain: string) => Buffer.from(plain, "utf8")),
}));

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir() },
  safeStorage: {
    decryptString: electronMocks.decryptString,
    encryptString: electronMocks.encryptString,
    isEncryptionAvailable: () => electronMocks.encryptionAvailable,
  },
}));

vi.mock("electron-log/main", () => ({
  default: { warn: vi.fn() },
}));

import { ElectronMainSessionService } from "../modules/session";
import { SecureSessionStore } from "../secure-store";

const audienceA = "https://api-a.comma.example";
const audienceB = "https://api-b.comma.example";

describe("ElectronMainSessionService", () => {
  let dir: string;

  beforeEach(async () => {
    electronMocks.encryptionAvailable = true;
    dir = await mkdtemp(join(tmpdir(), "comma-main-session-"));
  });

  afterEach(async () => {
    await rm(dir, { force: true, recursive: true });
  });

  it("keeps a persisted bearer closed until strict startup reconciliation", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("authorization")).toBe(
        "Bearer main_secret"
      );
      expect(init).toMatchObject({
        credentials: "omit",
        method: "GET",
        redirect: "manual",
      });
      return jsonResponse(currentSession());
    });
    const service = createService(store, fetchMock, audienceA);

    expect(service.state().phase).toBe("initializing");
    expect(service.acquireProductCredential(presenceExpectation(0))).toBeNull();

    await expect(service.initialize()).resolves.toMatchObject({
      ok: true,
      value: { generation: 1, phase: "signed_in" },
    });
    const lease = sessionProductLease(service.state());
    expect(lease).toBeDefined();
    expect(
      lease &&
        service.acquireProductCredential({
          authorityInstanceId: lease.authorityInstanceId,
          expectedAudience: lease.audience,
          expectedSessionId: lease.sessionId,
          generation: lease.generation,
        })
    ).toMatchObject({
      audience: audienceA,
      token: "main_secret",
    });
    expect(JSON.stringify(service.state())).not.toContain("main_secret");
  });

  it("bounds a 200 probe whose JSON body never completes and settles initialization", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const responseHeadersReceived = deferred<void>();
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
        responseHeadersReceived.resolve();
        return hangingJsonResponse(init?.signal);
      }
    );
    const service = createService(store, fetchMock, audienceA, {
      remoteTimeoutMs: 10,
    });

    const initialization = service.initialize();
    await responseHeadersReceived.promise;

    await expect(initialization).resolves.toMatchObject({
      error: { code: "session_probe_unavailable" },
      ok: false,
    });
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(service.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable" },
    });
    expect(service.acquireProductCredential(presenceExpectation(0))).toBeNull();
  });

  it("rechecks the stored credential after a failed startup probe without a guessed identity", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ error: "unavailable" }, 503))
      .mockResolvedValueOnce(jsonResponse(currentSession()));
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    expect(service.state().phase).toBe("indeterminate");
    expect(service.acquireProductCredential(presenceExpectation(0))).toBeNull();

    await expect(service.reconcile({ reason: "manual_retry" })).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_in" },
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    // An unqualified retry must not remain authorized once the state settles.
    await expect(service.reconcile({ reason: "manual_retry" })).resolves.toMatchObject({
      ok: false,
      error: { code: "conflict" },
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("durably removes a startup 401 and never opens product acquisition", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi.fn(async () => jsonResponse({ error: "unauthorized" }, 401));
    const service = createService(store, fetchMock, audienceA);

    await expect(service.initialize()).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out", reason: "unauthorized" },
    });
    expect(store.getVaultSnapshot()).toMatchObject({ status: "readable" });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
    expect(service.acquireProductCredential(presenceExpectation(1))).toBeNull();
  });

  it.each(["sign_out", "current_401"] as const)(
    "does not reopen a reconciled bearer after %s intent wins",
    async (winner) => {
      const store = await openStore();
      await store.setSession(storedCredential());
      const delayedProbe = deferred<Response>();
      const delayedProbeStarted = deferred<void>();
      let probes = 0;
      const snapshots: SessionLifecycleSnapshot[] = [];
      const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
        const path = new URL(String(input)).pathname;
        if (path === "/v1/comma/auth/session") {
          probes += 1;
          if (probes === 1) return jsonResponse(currentSession());
          delayedProbeStarted.resolve();
          return delayedProbe.promise;
        }
        if (path === "/v1/comma/auth/logout") {
          return jsonResponse({ signed_out: true });
        }
        throw new Error(`Unexpected path ${path}`);
      });
      const service = createService(store, fetchMock, audienceA, {
        onSnapshotChanged: (snapshot) => snapshots.push(snapshot),
      });
      await service.initialize();
      const signedIn = service.state();
      if (signedIn.phase !== "signed_in") {
        throw new Error("Expected a reconciled Session.");
      }
      const projectedLease = sessionProductLease(signedIn);
      if (!projectedLease) throw new Error("Expected a product lease projection.");
      const lease = service.acquireProductCredential({
        authorityInstanceId: projectedLease.authorityInstanceId,
        expectedAudience: projectedLease.audience,
        expectedSessionId: projectedLease.sessionId,
        generation: projectedLease.generation,
      });
      if (!lease) throw new Error("Expected an active Main credential lease.");

      const reconcile = service.reconcile({
        expected: sessionExpectation(signedIn),
        reason: "focus",
      });
      await delayedProbeStarted.promise;

      if (winner === "sign_out") {
        await service.signOut({ expected: sessionExpectation(signedIn) });
      } else {
        await service.reportUnauthorized(lease);
      }
      const winningPhase = winner === "sign_out" ? "signing_out" : "invalidating";
      const intentIndex = snapshots.findIndex(
        (snapshot) => snapshot.phase === winningPhase
      );
      expect(intentIndex).toBeGreaterThanOrEqual(0);
      expect(service.state().phase).toBe("signed_out");

      delayedProbe.resolve(jsonResponse(currentSession()));
      await expect(reconcile).resolves.toMatchObject({
        error: { code: "conflict" },
        ok: false,
      });
      expect(
        snapshots.slice(intentIndex).some((snapshot) => snapshot.phase === "signed_in")
      ).toBe(false);
      expect(service.state().phase).toBe("signed_out");
      expect(service.acquireProductCredential(presenceExpectation(1))).toBeNull();
      await service.retryPendingRevocations();
      await service.close();
    }
  );

  it("clears a previous environment before login without sending its bearer", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi.fn();
    const service = createService(store, fetchMock, audienceB);

    expect(service.acquireProductCredential(presenceExpectation(0))).toBeNull();
    await expect(service.initialize()).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out", reason: "no_session" },
    });
    await service.retryPendingRevocations();
    expect(fetchMock).not.toHaveBeenCalled();
    const reopened = await openStore();
    expect(reopened.getVaultSnapshot()).toMatchObject({
      status: "readable",
      pendingRevocations: [],
    });
    expect(reopened.getVaultSnapshot()).not.toHaveProperty("active");
    const restarted = createService(reopened, fetchMock, audienceB);
    await expect(restarted.initialize()).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });
  });

  it("removes foreign pending revocations while preserving the current environment", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    await store.beginSignOut();
    await store.setSession({
      ...storedCredential(),
      audience: audienceB,
      token: "current_secret",
    });
    const fetchMock = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse(currentSession())
    );
    const service = createService(store, fetchMock, audienceB);
    await expect(service.initialize()).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_in" },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      active: { audience: audienceB, token: "current_secret" },
      pendingRevocations: [],
    });
    for (const [url, init] of fetchMock.mock.calls as unknown as [URL, RequestInit][]) {
      expect(url.origin).toBe(audienceB);
      expect(new Headers(init.headers).get("authorization")).toBe(
        "Bearer current_secret"
      );
    }
  });

  it("clears foreign pending-only credentials and retains current revocation work", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    await store.beginSignOut();
    await store.setSession({
      ...storedCredential(),
      audience: audienceB,
      token: "pending_current",
    });
    await store.beginSignOut();
    const fetchMock = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({ error: "unavailable" }, 503)
    );
    const service = createService(store, fetchMock, audienceB);
    await expect(service.initialize()).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });
    await service.retryPendingRevocations();
    expect((await openStore()).getVaultSnapshot()).toMatchObject({
      pendingRevocations: [{ audience: audienceB, token: "pending_current" }],
    });
    expect(fetchMock).toHaveBeenCalled();
    for (const [url, init] of fetchMock.mock.calls) {
      expect(String(url)).toBe(audienceB + "/v1/comma/auth/logout");
      expect(new Headers(init?.headers).get("authorization")).toBe(
        "Bearer pending_current"
      );
    }
  });

  it("reports a failed environment cleanup and retries before permitting login", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const cleanup = vi
      .spyOn(store, "compareAndSetVault")
      .mockRejectedValueOnce(new Error("disk unavailable"));
    const fetchMock = vi.fn();
    const service = createService(store, fetchMock, audienceB);
    await expect(service.initialize()).resolves.toMatchObject({
      ok: false,
      error: { code: "credential_mutation_uncertain" },
    });
    expect(service.state().phase).toBe("indeterminate");
    expect(store.getVaultSnapshot()).toMatchObject({ active: { audience: audienceA } });
    cleanup.mockRestore();
    await expect(
      service.reconcile({
        reason: "manual_retry",
      })
    ).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("treats a reflected bearer field as protocol mismatch and keeps the gate shut", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi.fn(async () =>
      jsonResponse({ ...currentSession(), token: "reflected" })
    );
    const service = createService(store, fetchMock, audienceA);

    await expect(service.initialize()).resolves.toMatchObject({
      error: { code: "protocol_mismatch" },
      ok: false,
    });
    expect(service.state()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
    expect(service.acquireProductCredential(presenceExpectation(0))).toBeNull();
  });

  it("accepts a session probe with fields added by a newer backend", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const fetchMock = vi.fn(async () =>
      jsonResponse({ ...currentSession(), workspace_hint: "wsp_new" })
    );
    const service = createService(store, fetchMock, audienceA);

    await expect(service.initialize()).resolves.toMatchObject({ ok: true });
    expect(service.state()).toMatchObject({ phase: "signed_in" });
  });

  it("rejects stale auth intent before network even without secure persistence", async () => {
    electronMocks.encryptionAvailable = false;
    const store = await openStore();
    const fetchMock = vi.fn();
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);

    await expect(
      service.requestEmailLogin({
        email: "peng@example.com",
        expected: { ...expected, generation: expected.generation + 1 } as never,
      })
    ).resolves.toMatchObject({
      error: { code: "conflict" },
      ok: false,
    });

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([true, false])(
    "returns a token-free auth attempt and commits a strict issued Session with OS encryption %s",
    async (available) => {
      electronMocks.encryptionAvailable = available;
      const store = await openStore();
      const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = new URL(String(input)).pathname;
        expect(new Headers(init?.headers).get("x-comma-session-transport")).toBe(
          "bearer"
        );
        if (path === "/v1/comma/auth/email/login") {
          return jsonResponse({
            challenge_id: "challenge-1",
            code: "123456",
          });
        }
        if (path === "/v1/comma/auth/email/verify") {
          expect(requestBody(init)).toEqual({
            challenge_id: "challenge-1",
            client_kind: "electron",
            client_platform: expect.stringMatching(/^(linux|macos|unknown|windows)$/),
            code: "123456",
          });
          return jsonResponse(issuedSession());
        }
        throw new Error(`Unexpected path ${path}`);
      });
      const service = createService(store, fetchMock, audienceA);
      await service.initialize();
      const expected = sessionExpectation(service.state() as never);

      const requested = await service.requestEmailLogin({
        email: "peng@example.com",
        expected: expected as never,
      });
      expect(requested).toMatchObject({
        ok: true,
        value: { challengeId: "challenge-1" },
      });
      expect(JSON.stringify(requested)).not.toContain("123456");
      if (!requested.ok) throw new Error("Expected auth attempt.");

      const verified = await service.verifyEmailLogin({
        attempt: requested.value.attempt,
        challengeId: requested.value.challengeId,
        code: "123456",
      });
      expect(verified).toMatchObject({
        ok: true,
        value: {
          phase: "signed_in",
          session: { sessionId: "session-1" },
        },
      });
      expect(JSON.stringify(verified)).not.toContain("issued_secret");
      expect(store.getVaultSnapshot()).toMatchObject({
        active: {
          audience: audienceA,
          sessionId: "session-1",
          token: "issued_secret",
        },
        status: "readable",
      });
    }
  );

  it.each([true, false])(
    "keeps Google OIDC and the issued bearer inside Main with OS encryption %s",
    async (available) => {
      electronMocks.encryptionAvailable = available;
      const store = await openStore();
      const requestedUrls: string[] = [];
      const complete = vi.fn();
      const googleAuth: DesktopGoogleAuthProvider = {
        authenticate: vi.fn(async () => ({
          authorizationCode: "google-authorization-code",
          codeVerifier: "google-code-verifier",
          complete,
          redirectUri: "http://127.0.0.1:43123/oauth2/callback",
        })),
      };
      const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        requestedUrls.push(String(input));
        const path = new URL(String(input)).pathname;
        if (path === "/v1/comma/auth/google/attempt") {
          expect(requestBody(init)).toEqual({ platform: "electron" });
          return jsonResponse({
            attempt_id: "google-attempt-1",
            client_id: "desktop-client",
            nonce: "backend-nonce",
            platform: "electron",
          });
        }
        if (path === "/v1/comma/auth/google") {
          expect(requestBody(init)).toEqual({
            attempt_id: "google-attempt-1",
            authorization_code: "google-authorization-code",
            client_kind: "electron",
            client_platform: expect.stringMatching(/^(linux|macos|unknown|windows)$/),
            code_verifier: "google-code-verifier",
            nonce: "backend-nonce",
            redirect_uri: "http://127.0.0.1:43123/oauth2/callback",
          });
          return jsonResponse(issuedSession());
        }
        throw new Error(`Unexpected path ${path}`);
      });
      const service = createService(store, fetchMock, audienceA, { googleAuth });
      await service.initialize();

      const result = await service.signInWithGoogle({
        expected: sessionExpectation(service.state() as never) as never,
      });

      expect(googleAuth.authenticate).toHaveBeenCalledWith({
        clientId: "desktop-client",
        nonce: "backend-nonce",
        signal: expect.any(AbortSignal),
      });
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
      expect(store.getVaultSnapshot()).toMatchObject({
        active: { audience: audienceA, token: "issued_secret" },
        status: "readable",
      });
      expect(requestedUrls).toEqual([
        `${audienceA}/v1/comma/auth/google/attempt`,
        `${audienceA}/v1/comma/auth/google`,
      ]);
      expect(complete).toHaveBeenCalledOnce();
      expect(complete).toHaveBeenCalledWith(true);
    }
  );

  it("shows the loopback failure page when the server rejects Google code exchange", async () => {
    const store = await openStore();
    const complete = vi.fn();
    const googleAuth: DesktopGoogleAuthProvider = {
      authenticate: vi.fn(async () => ({
        authorizationCode: "google-authorization-code",
        codeVerifier: "google-code-verifier",
        complete,
        redirectUri: "http://127.0.0.1:43123/oauth2/callback",
      })),
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/google/attempt") {
        return jsonResponse({
          attempt_id: "google-attempt-1",
          client_id: "desktop-client",
          nonce: "backend-nonce",
          platform: "electron",
        });
      }
      if (path === "/v1/comma/auth/google") {
        return new Response(JSON.stringify({ error: "google_provider_unavailable" }), {
          headers: { "content-type": "application/json" },
          status: 503,
        });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA, { googleAuth });
    await service.initialize();

    await expect(
      service.signInWithGoogle({
        expected: sessionExpectation(service.state() as never) as never,
      })
    ).resolves.toMatchObject({
      error: { code: "provider_unavailable", retryable: true },
      ok: false,
    });

    expect(complete).toHaveBeenCalledOnce();
    expect(complete).toHaveBeenCalledWith(false);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(service.state().phase).toBe("signed_out");
  });

  it("returns Google preparation failure without automatic retry or opening the browser", async () => {
    const store = await openStore();
    const googleAuth = { authenticate: vi.fn() };
    const fetchMock = vi.fn(async () => new Response("{}", { status: 503 }));
    const service = createService(store, fetchMock, audienceA, { googleAuth });
    await service.initialize();
    await expect(
      service.signInWithGoogle({
        expected: sessionExpectation(service.state() as never) as never,
      })
    ).resolves.toMatchObject({ ok: false, error: { code: "provider_unavailable" } });
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(googleAuth.authenticate).not.toHaveBeenCalled();
    expect(service.state().phase).toBe("signed_out");
  });

  it("keeps one exact Google auth attempt through OTP linking", async () => {
    const store = await openStore();
    const googleAuth: DesktopGoogleAuthProvider = {
      authenticate: vi.fn(async () => ({
        authorizationCode: "google-authorization-code",
        codeVerifier: "google-code-verifier",
        complete: vi.fn(),
        redirectUri: "http://127.0.0.1:43123/oauth2/callback",
      })),
    };
    const requestedPaths: string[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      requestedPaths.push(path);
      if (path === "/v1/comma/auth/google/attempt") {
        return jsonResponse({
          attempt_id: "google-attempt-1",
          client_id: "desktop-client",
          nonce: "backend-nonce",
          platform: "electron",
        });
      }
      if (path === "/v1/comma/auth/google") {
        expect(requestBody(init)).toEqual({
          attempt_id: "google-attempt-1",
          authorization_code: "google-authorization-code",
          client_kind: "electron",
          client_platform: expect.stringMatching(/^(linux|macos|unknown|windows)$/),
          code_verifier: "google-code-verifier",
          nonce: "backend-nonce",
          redirect_uri: "http://127.0.0.1:43123/oauth2/callback",
        });
        return jsonResponse({
          challenge_id: "link-challenge",
          email: "peng@example.com",
          status: "otp_required",
        });
      }
      if (path === "/v1/comma/auth/google/link/verify") {
        expect(requestBody(init)).toEqual({
          challenge_id: "link-challenge",
          client_kind: "electron",
          client_platform: expect.stringMatching(/^(linux|macos|unknown|windows)$/),
          code: "123456",
        });
        return jsonResponse(issuedSession());
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA, { googleAuth });
    await service.initialize();

    const linked = await service.signInWithGoogle({
      expected: sessionExpectation(service.state() as never) as never,
    });
    expect(linked).toMatchObject({
      ok: true,
      value: {
        challengeId: "link-challenge",
        email: "peng@example.com",
        status: "otp_required",
      },
    });
    if (!linked.ok || linked.value.status !== "otp_required") {
      throw new Error("Expected Google OTP link attempt.");
    }
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");

    const verified = await service.verifyGoogleLink({
      attempt: linked.value.attempt,
      challengeId: linked.value.challengeId,
      code: "123456",
    });

    expect(verified).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
    expect(JSON.stringify(verified)).not.toContain("issued_secret");
    expect(store.getVaultSnapshot()).toMatchObject({
      active: { token: "issued_secret" },
      status: "readable",
    });
    expect(requestedPaths).toEqual([
      "/v1/comma/auth/google/attempt",
      "/v1/comma/auth/google",
      "/v1/comma/auth/google/link/verify",
    ]);
  });

  it("settles signed out when a retryable replacement email challenge fails", async () => {
    const store = await openStore();
    let requestCount = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        requestCount += 1;
        if (requestCount === 2) {
          return new Response(JSON.stringify({ error: "rate_limited" }), {
            headers: {
              "content-type": "application/json",
              "retry-after": "60",
            },
            status: 429,
          });
        }
        return jsonResponse({ challenge_id: `challenge-${requestCount}` });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);

    const first = await service.requestEmailLogin({
      email: "person@example.com",
      expected: expected as never,
    });
    if (!first.ok) throw new Error("Expected first auth attempt.");

    await expect(
      service.requestEmailLogin({
        email: "person@example.com",
        expected: first.value.attempt.expected,
      })
    ).resolves.toMatchObject({
      error: {
        code: "rate_limited",
        retryAfterMs: 60_000,
        retryable: true,
      },
      ok: false,
    });
    expect(service.state()).toMatchObject({
      generation: expected.generation,
      phase: "signed_out",
    });

    await expect(
      service.verifyEmailLogin({
        attempt: first.value.attempt,
        challengeId: first.value.challengeId,
        code: "123456",
      })
    ).resolves.toMatchObject({ error: { code: "conflict" }, ok: false });

    const replacement = await service.requestEmailLogin({
      email: "person@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    expect(replacement).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-3" },
    });
  });

  it("keeps superseded issuance behind the failed replacement settlement barrier", async () => {
    const store = await openStore();
    const verificationStarted = deferred<void>();
    const issuance = deferred<Response>();
    let requestCount = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        requestCount += 1;
        if (requestCount === 2) {
          return new Response(JSON.stringify({ error: "rate_limited" }), {
            headers: { "content-type": "application/json" },
            status: 429,
          });
        }
        return jsonResponse({ challenge_id: "challenge-1" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        verificationStarted.resolve();
        return issuance.promise;
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);
    const first = await service.requestEmailLogin({
      email: "first@example.com",
      expected: expected as never,
    });
    if (!first.ok) throw new Error("Expected first auth attempt.");
    const verification = service.verifyEmailLogin({
      attempt: first.value.attempt,
      challengeId: first.value.challengeId,
      code: "123456",
    });
    await verificationStarted.promise;

    let replacementSettled = false;
    const replacement = service
      .requestEmailLogin({
        email: "replacement@example.com",
        expected: first.value.attempt.expected,
      })
      .finally(() => {
        replacementSettled = true;
      });
    await vi.waitFor(() => expect(requestCount).toBe(2));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(replacementSettled).toBe(false);

    issuance.resolve(
      jsonResponse(
        issuedSession({
          sessionId: "session-superseded",
          token: "secret-superseded",
          userId: "user-superseded",
        })
      )
    );
    await expect(verification).resolves.toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });
    await expect(replacement).resolves.toMatchObject({
      error: { code: "rate_limited" },
      ok: false,
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [
        {
          sessionId: "session-superseded",
          token: "secret-superseded",
        },
      ],
      status: "readable",
    });
    await expect(service.close()).resolves.toBeUndefined();
  });

  it("settles signed out when a retryable Google start fails", async () => {
    const store = await openStore();
    const googleAuth: DesktopGoogleAuthProvider = {
      authenticate: vi.fn(async () => ({
        authorizationCode: "google-authorization-code",
        codeVerifier: "google-code-verifier",
        complete: vi.fn(),
        redirectUri: "http://127.0.0.1:43123/oauth2/callback",
      })),
    };
    let attemptCount = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/google/attempt") {
        attemptCount += 1;
        if (attemptCount === 1) {
          return new Response(JSON.stringify({ error: "rate_limited" }), {
            headers: { "content-type": "application/json" },
            status: 429,
          });
        }
        return jsonResponse({
          attempt_id: "google-attempt-2",
          client_id: "desktop-client",
          nonce: "backend-nonce",
          platform: "electron",
        });
      }
      if (path === "/v1/comma/auth/google") {
        return jsonResponse({
          challenge_id: "link-challenge",
          email: "person@example.com",
          status: "otp_required",
        });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA, { googleAuth });
    await service.initialize();

    await expect(
      service.signInWithGoogle({
        expected: sessionExpectation(service.state() as never) as never,
      })
    ).resolves.toMatchObject({
      error: { code: "rate_limited", retryable: true },
      ok: false,
    });
    expect(service.state().phase).toBe("signed_out");

    await expect(
      service.signInWithGoogle({
        expected: sessionExpectation(service.state() as never) as never,
      })
    ).resolves.toMatchObject({
      ok: true,
      value: { challengeId: "link-challenge", status: "otp_required" },
    });
  });

  it("keeps the exact auth attempt after a retryable invalid code", async () => {
    const store = await openStore();
    let verificationCount = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-1" });
      }
      if (path === "/v1/comma/auth/email/verify" && verificationCount++ === 0) {
        return jsonResponse({ error: "invalid_verification_code" }, 401);
      }
      if (path === "/v1/comma/auth/email/verify") return jsonResponse(issuedSession());
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "peng@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");
    const verificationInput = {
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "000000",
    };

    await expect(service.verifyEmailLogin(verificationInput)).resolves.toMatchObject({
      error: {
        code: "invalid_challenge",
        recovery: "retry_operation",
        retryable: true,
      },
      ok: false,
    });
    expect(service.state().phase).toBe("authenticating");
    await expect(
      service.verifyEmailLogin({ ...verificationInput, code: "123456" })
    ).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: "session-1" } },
    });
  });

  it("admits only one verifier for an exact auth challenge", async () => {
    const store = await openStore();
    const verificationStarted = deferred<void>();
    const issuance = deferred<Response>();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-1" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        verificationStarted.resolve();
        return issuance.promise;
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "peng@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");
    const verificationInput = {
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "123456",
    };

    const first = service.verifyEmailLogin(verificationInput);
    await verificationStarted.promise;
    await expect(service.verifyEmailLogin(verificationInput)).resolves.toMatchObject({
      error: { code: "conflict" },
      ok: false,
    });

    issuance.resolve(jsonResponse(issuedSession()));
    await expect(first).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_in" },
    });
    expect(
      fetchMock.mock.calls.filter(
        ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/email/verify"
      )
    ).toHaveLength(1);
  });

  it("quarantines an issued bearer when a replacement auth attempt wins during durable commit", async () => {
    const store = await openStore();
    const commitStarted = deferred<void>();
    const releaseCommit = deferred<void>();
    const committedSetSession = store.setSession.bind(store);
    vi.spyOn(store, "setSession").mockImplementationOnce(async (credential) => {
      commitStarted.resolve();
      await releaseCommit.promise;
      await committedSetSession(credential);
    });
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        const email = String((requestBody(init) as { email?: string }).email);
        return jsonResponse({ challenge_id: `challenge-${email}` });
      }
      if (path === "/v1/comma/auth/email/verify") {
        const code = String((requestBody(init) as { code?: string }).code);
        return jsonResponse(
          issuedSession({
            sessionId: code === "111111" ? "session-first" : "session-replacement",
            token: code === "111111" ? "secret-first" : "secret-replacement",
            userId: code === "111111" ? "user-first" : "user-replacement",
          })
        );
      }
      if (path === "/v1/comma/auth/logout") {
        return jsonResponse({ signed_out: true });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);
    const first = await service.requestEmailLogin({
      email: "first@example.com",
      expected: expected as never,
    });
    if (!first.ok) throw new Error("Expected first auth attempt.");
    const firstVerification = service.verifyEmailLogin({
      attempt: first.value.attempt,
      challengeId: first.value.challengeId,
      code: "111111",
    });
    await commitStarted.promise;

    const replacement = await service.requestEmailLogin({
      email: "replacement@example.com",
      expected: first.value.attempt.expected,
    });
    if (!replacement.ok) throw new Error("Expected replacement auth attempt.");
    releaseCommit.resolve();
    await expect(firstVerification).resolves.toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });

    await expect(
      service.verifyEmailLogin({
        attempt: replacement.value.attempt,
        challengeId: replacement.value.challengeId,
        code: "222222",
      })
    ).resolves.toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        principal: { userId: "user-replacement" },
        session: { sessionId: "session-replacement" },
      },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-replacement",
        token: "secret-replacement",
      },
      status: "readable",
    });
  });

  it("atomically records an unrevoked stale credential before publishing its replacement", async () => {
    const store = await openStore();
    const firstCommitStarted = deferred<void>();
    const releaseFirstCommit = deferred<void>();
    vi.spyOn(store, "setSession").mockImplementationOnce(async () => {
      firstCommitStarted.resolve();
      await releaseFirstCommit.promise;
      throw new Error("injected first credential write failure");
    });
    vi.spyOn(store, "queueRevocation").mockResolvedValueOnce(false);
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        const email = String((requestBody(init) as { email?: string }).email);
        return jsonResponse({ challenge_id: `challenge-${email}` });
      }
      if (path === "/v1/comma/auth/email/verify") {
        const code = String((requestBody(init) as { code?: string }).code);
        return jsonResponse(
          issuedSession({
            sessionId: code === "111111" ? "session-a" : "session-b",
            token: code === "111111" ? "secret-a" : "secret-b",
            userId: code === "111111" ? "user-a" : "user-b",
          })
        );
      }
      if (path === "/v1/comma/auth/logout") {
        throw new Error("injected direct cleanup failure");
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);
    const first = await service.requestEmailLogin({
      email: "a@example.com",
      expected: expected as never,
    });
    if (!first.ok) throw new Error("Expected first auth attempt.");
    const firstCommit = service.verifyEmailLogin({
      attempt: first.value.attempt,
      challengeId: first.value.challengeId,
      code: "111111",
    });
    await firstCommitStarted.promise;

    const replacement = await service.requestEmailLogin({
      email: "b@example.com",
      expected: first.value.attempt.expected,
    });
    if (!replacement.ok) throw new Error("Expected replacement auth attempt.");
    const replacementCommit = service.verifyEmailLogin({
      attempt: replacement.value.attempt,
      challengeId: replacement.value.challengeId,
      code: "222222",
    });
    await vi.waitFor(() => {
      expect(
        fetchMock.mock.calls.filter(
          ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/email/verify"
        )
      ).toHaveLength(2);
    });

    releaseFirstCommit.resolve();
    await expect(firstCommit).resolves.toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });
    await expect(replacementCommit).resolves.toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        principal: { userId: "user-b" },
        session: { sessionId: "session-b" },
      },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      active: { sessionId: "session-b", token: "secret-b" },
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "session-a",
          token: "secret-a",
        },
      ],
      status: "readable",
    });
    expect(
      (
        await SecureSessionStore.open(join(dir, "secure-session.bin"))
      ).getVaultSnapshot()
    ).toMatchObject({
      active: { sessionId: "session-b", token: "secret-b" },
      pendingRevocations: [{ sessionId: "session-a", token: "secret-a" }],
      status: "readable",
    });
    await service.retryPendingRevocations();
  });

  it("keeps cancellation indeterminate when an issued credential cannot be quarantined", async () => {
    const store = await openStore();
    const commitStarted = deferred<void>();
    const releaseCommit = deferred<void>();
    vi.spyOn(store, "setSession").mockImplementationOnce(async () => {
      commitStarted.resolve();
      await releaseCommit.promise;
      throw new Error("injected credential write failure");
    });
    const queueRevocation = vi.spyOn(store, "queueRevocation").mockResolvedValue(false);
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-a" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        return jsonResponse(
          issuedSession({
            sessionId: "session-a",
            token: "secret-a",
            userId: "user-a",
          })
        );
      }
      if (path === "/v1/comma/auth/logout") {
        throw new Error("injected direct cleanup failure");
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "a@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");
    const verification = service.verifyEmailLogin({
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "111111",
    });
    await commitStarted.promise;

    const cancellation = service.cancelAuthAttempt({
      attempt: requested.value.attempt,
    });
    expect(service.state().phase).toBe("signing_out");
    releaseCommit.resolve();

    await expect(verification).resolves.toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });
    await expect(cancellation).resolves.toMatchObject({
      error: { code: "credential_mutation_uncertain" },
      ok: false,
    });
    expect(service.state()).toMatchObject({
      phase: "indeterminate",
      problem: {
        code: "credential_mutation_uncertain",
        operation: "authenticate",
      },
    });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
    await expect(service.close()).rejects.toThrow(
      "issued credential that could not be quarantined"
    );
    expect(store.queueRevocation).toHaveBeenCalledTimes(3);
    expect(
      fetchMock.mock.calls.filter(
        ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/logout"
      )
    ).toHaveLength(2);
    queueRevocation.mockRestore();
    await expect(service.close()).resolves.toBeUndefined();
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "session-a",
          token: "secret-a",
        },
      ],
      status: "readable",
    });
  });

  it("makes sign-out win over a delayed login issuance and quarantines the bearer", async () => {
    const store = await openStore();
    const issuance = deferred<Response>();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-1" });
      }
      if (path === "/v1/comma/auth/email/verify") return issuance.promise;
      if (path === "/v1/comma/auth/logout") return jsonResponse({ signed_out: true });
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const expected = sessionExpectation(service.state() as never);
    const requested = await service.requestEmailLogin({
      email: "peng@example.com",
      expected: expected as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");

    const verification = service.verifyEmailLogin({
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "123456",
    });
    const signOut = service.signOut({
      expected: requested.value.attempt.expected,
    });
    expect(service.state()).toMatchObject({ phase: "signing_out" });

    issuance.resolve(jsonResponse(issuedSession()));
    await expect(signOut).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_out" },
    });

    await expect(verification).resolves.toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });
    await service.retryPendingRevocations();
    await vi.waitFor(() => {
      expect(store.getVaultSnapshot()).toMatchObject({ status: "readable" });
      expect(store.getVaultSnapshot()).not.toHaveProperty("active");
    });
    expect(service.state().phase).toBe("signed_out");
  });

  it("closes the local product gate before remote sign-out cleanup completes", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const revokeStarted = deferred<void>();
    const releaseRevoke = deferred<void>();
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/session") return jsonResponse(currentSession());
      if (path === "/v1/comma/auth/logout") {
        expect(new Headers(init?.headers).get("authorization")).toBe(
          "Bearer main_secret"
        );
        revokeStarted.resolve();
        await releaseRevoke.promise;
        return jsonResponse({ signed_out: true });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();

    const signedOut = await service.signOut({
      expected: sessionExpectation(service.state() as never) as never,
    });

    expect(signedOut).toMatchObject({
      ok: true,
      value: {
        cleanup: { revocation: "pending" },
        phase: "signed_out",
        reason: "user_signed_out",
      },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "pending" },
      pendingRevocations: [{ audience: audienceA, token: "main_secret" }],
      status: "readable",
    });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
    expect(service.acquireProductCredential(presenceExpectation(1))).toBeNull();

    await revokeStarted.promise;
    releaseRevoke.resolve();
    await service.retryPendingRevocations();
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "idle" },
      pendingRevocations: [],
      status: "readable",
    });
  });

  it("drains a revocation queued while an earlier exact cleanup is in flight", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const firstRevokeStarted = deferred<void>();
    const releaseFirstRevoke = deferred<void>();
    const revokedTokens: string[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/session") return jsonResponse(currentSession());
      if (path === "/v1/comma/auth/logout") {
        const token = bearerToken(init);
        revokedTokens.push(token);
        if (token === "main_secret") {
          firstRevokeStarted.resolve();
          await releaseFirstRevoke.promise;
        }
        return jsonResponse({ signed_out: true });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    await service.signOut({
      expected: sessionExpectation(service.state() as never) as never,
    });
    await firstRevokeStarted.promise;
    expect(
      await store.queueRevocation({
        audience: audienceA,
        sessionId: "late-session",
        token: "late-session-secret",
      })
    ).toBe(true);
    const cleanup = service.retryPendingRevocations();

    releaseFirstRevoke.resolve();
    await cleanup;

    expect(revokedTokens).toEqual(["main_secret", "late-session-secret"]);
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "idle" },
      pendingRevocations: [],
      status: "readable",
    });
  });

  it("bounds a hung remote cleanup and retains its durable retry record", async () => {
    const store = await openStore();
    expect(
      await store.queueRevocation({
        audience: audienceA,
        sessionId: "hung-session",
        token: "hung-secret",
      })
    ).toBe(true);
    const revokeStarted = deferred<void>();
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
        revokeStarted.resolve();
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("aborted", "AbortError")),
            { once: true }
          );
        });
      }
    );
    const service = createService(store, fetchMock, audienceA, {
      remoteTimeoutMs: 10,
    });

    await service.initialize();
    await revokeStarted.promise;
    await service.retryPendingRevocations();

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "pending" },
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "hung-session",
          token: "hung-secret",
        },
      ],
      status: "readable",
    });
  });

  it("drops terminal 401 cleanup and retains a non-terminal failure", async () => {
    const store = await openStore();
    await store.queueRevocation({
      audience: audienceA,
      sessionId: "already-revoked-session",
      token: "already-revoked",
    });
    await store.queueRevocation({
      audience: audienceA,
      sessionId: "forbidden-session",
      token: "forbidden",
    });
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) =>
      bearerToken(init) === "already-revoked"
        ? jsonResponse({ error: "unauthorized" }, 401)
        : jsonResponse({ error: "forbidden" }, 403)
    );
    const service = createService(store, fetchMock, audienceA);

    await service.initialize();
    await service.retryPendingRevocations();

    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "pending" },
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "forbidden-session",
          token: "forbidden",
        },
      ],
      status: "readable",
    });
  });

  it("retains a terminal cleanup whose durable completion fails and continues later records", async () => {
    const store = await openStore();
    await store.queueRevocation({
      audience: audienceA,
      sessionId: "write-failed-session",
      token: "write-failed",
    });
    await store.queueRevocation({
      audience: audienceA,
      sessionId: "later-session",
      token: "later-already-revoked",
    });
    const completeRevocation = store.completeRevocation.bind(store);
    vi.spyOn(store, "completeRevocation").mockImplementation(async (pending) => {
      const token = typeof pending === "string" ? pending : pending.token;
      if (token === "write-failed") {
        throw new Error("encrypted queue write failed");
      }
      await completeRevocation(pending);
    });
    const attemptedTokens: string[] = [];
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      attemptedTokens.push(bearerToken(init));
      return jsonResponse({ error: "unauthorized" }, 401);
    });
    const service = createService(store, fetchMock, audienceA);

    await service.initialize();
    await service.retryPendingRevocations();

    expect(attemptedTokens).toEqual(["write-failed", "later-already-revoked"]);
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "pending" },
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "write-failed-session",
          token: "write-failed",
        },
      ],
      status: "readable",
    });
  });

  it("revokes an issued bearer that cannot be persisted into Main custody", async () => {
    const store = await openStore();
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-1" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        return jsonResponse(issuedSession({ token: "unaccepted-secret" }));
      }
      if (path === "/v1/comma/auth/logout") {
        expect(bearerToken(init)).toBe("unaccepted-secret");
        return jsonResponse({ signed_out: true });
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "peng@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");
    vi.spyOn(store, "setSession").mockRejectedValueOnce(
      new Error("secure custody write failed")
    );
    vi.spyOn(store, "queueRevocation").mockResolvedValueOnce(false);

    const result = await service.verifyEmailLogin({
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "123456",
    });

    expect(result).toMatchObject({
      error: {
        code: "credential_mutation_uncertain",
        recovery: "reconcile",
      },
      ok: false,
    });
    expect(service.state()).toMatchObject({
      phase: "indeterminate",
      problem: {
        code: "credential_mutation_uncertain",
        operation: "authenticate",
      },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [],
      status: "readable",
    });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
  });

  it("retains a current issued bearer after triple cleanup failure and refuses unsafe close", async () => {
    const store = await openStore();
    vi.spyOn(store, "setSession").mockRejectedValueOnce(
      new Error("injected credential write failure")
    );
    vi.spyOn(store, "queueRevocation").mockResolvedValue(false);
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-a" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        return jsonResponse(
          issuedSession({
            sessionId: "session-a",
            token: "secret-a",
            userId: "user-a",
          })
        );
      }
      if (path === "/v1/comma/auth/logout") {
        throw new Error("injected direct cleanup failure");
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "a@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");

    await expect(
      service.verifyEmailLogin({
        attempt: requested.value.attempt,
        challengeId: requested.value.challengeId,
        code: "111111",
      })
    ).resolves.toMatchObject({
      error: { code: "credential_mutation_uncertain" },
      ok: false,
    });
    expect(service.state()).toMatchObject({
      phase: "indeterminate",
      problem: {
        code: "credential_mutation_uncertain",
        operation: "authenticate",
      },
    });
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [],
      status: "readable",
    });

    await expect(service.close()).rejects.toThrow(
      "issued credential that could not be quarantined"
    );
    expect(store.queueRevocation).toHaveBeenCalledTimes(2);
    expect(
      fetchMock.mock.calls.filter(
        ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/logout"
      )
    ).toHaveLength(2);
  });

  it("manual reconcile durably adopts unresolved issued cleanup before signed-out projection", async () => {
    const store = await openStore();
    vi.spyOn(store, "setSession").mockRejectedValueOnce(
      new Error("injected credential write failure")
    );
    const queueRevocation = store.queueRevocation.bind(store);
    vi.spyOn(store, "queueRevocation")
      .mockResolvedValueOnce(false)
      .mockImplementation(queueRevocation);
    let logoutAttempts = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login") {
        return jsonResponse({ challenge_id: "challenge-a" });
      }
      if (path === "/v1/comma/auth/email/verify") {
        return jsonResponse(
          issuedSession({
            sessionId: "session-a",
            token: "secret-a",
            userId: "user-a",
          })
        );
      }
      if (path === "/v1/comma/auth/logout") {
        logoutAttempts += 1;
        throw new Error("injected direct cleanup failure");
      }
      throw new Error(`Unexpected path ${path}`);
    });
    const service = createService(store, fetchMock, audienceA);
    await service.initialize();
    const requested = await service.requestEmailLogin({
      email: "a@example.com",
      expected: sessionExpectation(service.state() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected auth attempt.");
    await service.verifyEmailLogin({
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "111111",
    });

    await expect(service.reconcile({ reason: "manual_retry" })).resolves.toMatchObject({
      ok: true,
      value: {
        cleanup: { revocation: "pending" },
        phase: "signed_out",
      },
    });
    expect(logoutAttempts).toBe(1);
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [
        {
          audience: audienceA,
          sessionId: "session-a",
          token: "secret-a",
        },
      ],
      status: "readable",
    });
    await expect(service.close()).resolves.toBeUndefined();
  });

  function openStore() {
    return SecureSessionStore.open(join(dir, "secure-session.bin"));
  }
});

function createService(
  store: SecureSessionStore,
  fetchMock: typeof fetch,
  trustedAudience: string,
  options: {
    googleAuth?: DesktopGoogleAuthProvider;
    onSnapshotChanged?: (snapshot: SessionLifecycleSnapshot) => void;
    remoteTimeoutMs?: number;
  } = {}
) {
  return new ElectronMainSessionService({
    authorityInstanceId: "authority-1",
    fetch: fetchMock,
    ...options,
    store,
    trustedAudience,
  });
}

function storedCredential() {
  return {
    audience: audienceA,
    email: "peng@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "session-1",
    token: "main_secret",
    userId: "user-1",
  };
}

function currentSession() {
  return {
    expires_at: 1_900_000_100,
    session_id: "session-1",
    user: {
      email: "peng@example.com",
      id: "user-1",
      name: "Peng",
      status: "active",
    },
  };
}

function issuedSession(
  options: {
    sessionId?: string;
    token?: string;
    userId?: string;
  } = {}
) {
  return {
    ...currentSession(),
    session_id: options.sessionId ?? "session-1",
    token: options.token ?? "issued_secret",
    user: {
      ...currentSession().user,
      id: options.userId ?? "user-1",
    },
  };
}

function presenceExpectation(generation: number) {
  return {
    authorityInstanceId: "authority-1",
    expectedAudience: audienceA,
    expectedSessionId: "session-1",
    generation,
  };
}

function bearerToken(init: RequestInit | undefined) {
  return (new Headers(init?.headers).get("authorization") ?? "").replace("Bearer ", "");
}

function requestBody(init: RequestInit | undefined) {
  return JSON.parse(String(init?.body ?? "{}")) as unknown;
}

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status,
  });
}

function hangingJsonResponse(signal: AbortSignal | null | undefined) {
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        const abort = () => {
          controller.error(new DOMException("aborted", "AbortError"));
        };
        if (signal?.aborted) {
          abort();
          return;
        }
        signal?.addEventListener("abort", abort, { once: true });
      },
    }),
    {
      headers: { "content-type": "application/json" },
      status: 200,
    }
  );
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
