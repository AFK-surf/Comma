// Main's part of the Electron session (MainSessionHost): the bearer stays in SecureStore and in Main's custody, the
// core names it by reference, Main's gate follows the core, and Main keeps its lease while the core is away.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  sessionProductLease,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

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

vi.mock("electron-log/main", () => ({ default: { warn: vi.fn() } }));

import { MainSessionHost } from "../modules/session";
import { SecureSessionStore } from "../secure-store";
import { startInProcessCore } from "../../test-support/in-process-core";

// The file's timers run on the test's clock: a test moves it.
beforeEach(() => {
  vi.useFakeTimers();
});

const audience = "https://api-a.comma.example";

describe("MainSessionHost", () => {
  let dir: string;

  beforeEach(async () => {
    electronMocks.encryptionAvailable = true;
    dir = await mkdtemp(join(tmpdir(), "comma-main-session-host-"));
  });

  afterEach(async () => {
    await rm(dir, { force: true, recursive: true });
  });

  const openStore = () => SecureSessionStore.open(join(dir, "secure-session.bin"));

  it.each([true, false])(
    "takes a sign-in's bearer out of the answer and commits it by reference, with OS encryption %s",
    async (available) => {
      electronMocks.encryptionAvailable = available;
      const store = await openStore();
      const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        expect(new URL(String(input)).pathname).toBe("/v1/comma/auth/email/verify");
        expect(new Headers(init?.headers).get("x-comma-session-transport")).toBe(
          "bearer"
        );
        expect(new Headers(init?.headers).get("authorization")).toBeNull();
        return jsonResponse(issuedSession());
      });
      const host = createHost(store, fetchMock);
      const answer = await host.authFetch(
        authRequest("POST", "/v1/comma/auth/email/verify")
      );
      const body = JSON.parse(new TextDecoder().decode(answer.body)) as Record<
        string,
        unknown
      >;
      expect(body).not.toHaveProperty("token");
      expect(JSON.stringify(body)).not.toContain("issued_secret");
      expect(body.credential).toEqual(expect.any(String));
      expect(body.credential).not.toContain("issued_secret");

      const vault = await host.change({
        issued: body.credential as string,
        kind: "commit",
        supersede: [],
      });
      expect(JSON.stringify(vault)).not.toContain("issued_secret");
      expect(vault).toMatchObject({
        active: { ref: body.credential, sessionId: "session-1", userId: "user-1" },
        status: "readable",
      });
      expect(store.getVaultSnapshot()).toMatchObject({
        active: { audience, sessionId: "session-1", token: "issued_secret" },
      });
    }
  );

  it("attaches only the credential a request names, and only to the auth endpoints", async () => {
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
    const host = createHost(store, fetchMock);
    const vault = await host.vault();
    if (vault.status !== "readable" || !vault.active)
      throw new Error("Expected a stored session.");
    expect(JSON.stringify(vault)).not.toContain("main_secret");

    await host.authFetch({
      ...authRequest("GET", "/v1/comma/auth/session"),
      credential: vault.active.ref,
    });
    expect(fetchMock).toHaveBeenCalledOnce();
    await expect(
      host.authFetch({
        ...authRequest("GET", "/v1/comma/workspaces"),
        credential: vault.active.ref,
      })
    ).rejects.toThrow("auth endpoints");
    await expect(
      host.authFetch({
        ...authRequest("GET", "/v1/comma/auth/session"),
        credential: "made-up",
      })
    ).rejects.toThrow("not kept");
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("names a bearer the store already keeps instead of taking it into custody again", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const host = createHost(
      store,
      vi.fn(async () => jsonResponse({ ...currentSession(), token: "main_secret" }))
    );
    const vault = await host.vault();
    const answer = await host.authFetch({
      ...authRequest("GET", "/v1/comma/auth/session"),
      credential: vault.status === "readable" ? vault.active!.ref : "",
    });
    const body = JSON.parse(new TextDecoder().decode(answer.body)) as {
      credential?: string;
    };
    expect(JSON.stringify(body)).not.toContain("main_secret");
    // Letting it go leaves the stored session as it is.
    expect(await host.change({ issued: body.credential!, kind: "quarantine" })).toBe(
      true
    );
    expect(store.getVaultSnapshot()).toMatchObject({
      active: { token: "main_secret" },
      pendingRevocations: [],
    });
  });

  it("opens its gate for the core's snapshot, keeps it while the core is away, and shuts it on a 401", async () => {
    const store = await openStore();
    await store.setSession(storedCredential());
    const host = createHost(store, vi.fn());
    const rejected = vi.fn();
    host.onRejected(rejected);
    const resumed = host.resume();
    expect(resumed).toMatchObject({ generation: 0, revision: 0, sessionId: null });

    const snapshot = signedInSnapshot(resumed.authorityInstanceId);
    host.gate(snapshot, sessionProductLease(snapshot)!);
    const expectation = {
      authorityInstanceId: resumed.authorityInstanceId,
      expectedAudience: audience,
      expectedSessionId: "session-1",
      generation: 1,
    };
    const lease = host.acquireProductCredential(expectation);
    expect(lease).toMatchObject({ token: "main_secret" });

    // The core's process went: the confirmed lease still serves, and the next core continues from it.
    await host.coreExited();
    expect(host.acquireProductCredential(expectation)).not.toBeNull();
    expect(host.resume()).toMatchObject({
      generation: 1,
      revision: 1,
      sessionId: "session-1",
    });

    // A 401 while the core is away shuts the gate at once; the next core opens a new generation.
    await host.reportUnauthorized(lease!);
    expect(host.acquireProductCredential(expectation)).toBeNull();
    expect(rejected).toHaveBeenCalledWith({
      audience,
      authorityInstanceId: resumed.authorityInstanceId,
      generation: 1,
      sessionId: "session-1",
    });
    expect(host.resume()).toMatchObject({ generation: 1, sessionId: null });
  });

  it("refuses a lease for a session its store does not hold", async () => {
    const store = await openStore();
    const host = createHost(store, vi.fn());
    const snapshot = signedInSnapshot(host.resume().authorityInstanceId);
    host.gate(snapshot, sessionProductLease(snapshot)!);
    expect(
      host.acquireProductCredential({
        authorityInstanceId: snapshot.authority.authorityInstanceId,
        expectedAudience: audience,
        expectedSessionId: "session-1",
        generation: 1,
      })
    ).toBeNull();
  });

  it("queues the bearers a core left unsettled when it goes", async () => {
    const store = await openStore();
    const host = createHost(
      store,
      vi.fn(async () => jsonResponse(issuedSession()))
    );
    await host.authFetch(authRequest("POST", "/v1/comma/auth/email/verify"));
    await host.coreExited();
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [
        { audience, sessionId: "session-1", token: "issued_secret" },
      ],
    });
    await expect(host.close()).resolves.toBeUndefined();
  });

  it("queues what an answer the core gave up carried", async () => {
    const store = await openStore();
    const host = createHost(
      store,
      vi.fn(async () => jsonResponse(issuedSession()))
    );
    await host.authFetch(authRequest("POST", "/v1/comma/auth/email/verify"), {
      requestId: 7,
    });
    await host.dropped(6);
    expect(store.getVaultSnapshot()).toMatchObject({ pendingRevocations: [] });
    await host.dropped(7);
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [{ token: "issued_secret" }],
    });
  });

  it("refuses to close while an issued bearer can be neither queued nor revoked", async () => {
    const store = await openStore();
    const logouts: string[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (new URL(String(input)).pathname === "/v1/comma/auth/logout") {
        logouts.push(new Headers(init?.headers).get("authorization") ?? "");
        throw new Error("injected direct cleanup failure");
      }
      return jsonResponse(issuedSession({ token: "secret-a" }));
    });
    const host = createHost(store, fetchMock);
    await host.authFetch(authRequest("POST", "/v1/comma/auth/email/verify"));
    const queueRevocation = vi.spyOn(store, "queueRevocation").mockResolvedValue(false);

    await expect(host.close()).rejects.toThrow(
      "issued credential that could not be quarantined"
    );
    expect(logouts).toEqual(["Bearer secret-a"]);
    queueRevocation.mockRestore();
    await expect(host.close()).resolves.toBeUndefined();
    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [{ sessionId: "session-1", token: "secret-a" }],
    });
  });

  it("runs a real core's sign-in, the bearer never reaching the core", async () => {
    const store = await openStore();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/email/login")
        return jsonResponse({ challenge_id: "challenge-1" });
      if (path === "/v1/comma/auth/email/verify") return jsonResponse(issuedSession());
      return jsonResponse({ error: "not_found" }, 404);
    });
    // The core publishes signed_out once it has read the empty vault.
    const published = Promise.withResolvers<SessionLifecycleSnapshot>();
    const host = createHost(store, fetchMock, (snapshot) => {
      if (snapshot.phase === "signed_out") published.resolve(snapshot);
    });
    const core = startInProcessCore(host);
    try {
      const signedOut = await published.promise;
      const requested = (await core.client.call("session.email.request", {
        email: "peng@example.com",
        expected: {
          authorityInstanceId: signedOut.authority.authorityInstanceId,
          expectedSessionId: null,
          generation: signedOut.generation,
        },
      })) as { ok: true; value: { attempt: unknown; challengeId: string } };
      const verified = await core.client.call("session.email.verify", {
        attempt: requested.value.attempt,
        challengeId: requested.value.challengeId,
        code: "123456",
      });
      expect(verified).toMatchObject({ ok: true, value: { phase: "signed_in" } });
      expect(host.state()).toMatchObject({ phase: "signed_in" });
      const lease = sessionProductLease(host.state())!;
      expect(
        host.acquireProductCredential({
          authorityInstanceId: lease.authorityInstanceId,
          expectedAudience: lease.audience,
          expectedSessionId: lease.sessionId,
          generation: lease.generation,
        })
      ).toMatchObject({ token: "issued_secret" });
      expect(store.getVaultSnapshot()).toMatchObject({
        active: { token: "issued_secret" },
      });
      expect(core.log()).not.toContain("issued_secret");
      expect(JSON.stringify(verified)).not.toContain("issued_secret");
    } finally {
      core.close();
      await host.close();
    }
  });
});

function createHost(
  store: SecureSessionStore,
  fetchMock: typeof fetch,
  onSnapshotChanged?: (snapshot: SessionLifecycleSnapshot) => void
) {
  return new MainSessionHost({
    fetch: fetchMock,
    onSnapshotChanged,
    store,
    trustedAudience: audience,
  });
}

function authRequest(method: "GET" | "POST", path: string) {
  return {
    body: method === "POST" ? new TextEncoder().encode("{}") : null,
    headers: [["accept", "application/json"]] as [string, string][],
    method,
    path,
  };
}

function storedCredential() {
  return {
    audience,
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
    user: { email: "peng@example.com", id: "user-1", name: "Peng", status: "active" },
  };
}

function issuedSession(options: { token?: string } = {}) {
  return { ...currentSession(), token: options.token ?? "issued_secret" };
}

function signedInSnapshot(authorityInstanceId: string) {
  return {
    authority: { authorityInstanceId, kind: "electron_main" as const },
    cleanup: { revocation: "idle" as const },
    contractVersion: 1 as const,
    generation: 1,
    phase: "signed_in" as const,
    principal: { email: "peng@example.com", userId: "user-1" },
    revision: 1,
    session: { audience, expiresAtEpochSeconds: 1_900_000_000, sessionId: "session-1" },
  };
}

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status,
  });
}
