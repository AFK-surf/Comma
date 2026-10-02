import { createHash } from "node:crypto";
import {
  sessionExpectation,
  sessionOperationErrorSchemaFor,
} from "@comma/session-contract";
import { describe, expect, it } from "vitest";
import { createCommaApi } from "../../../api";
import type {
  WebSessionBroadcastChannel,
  WebSessionCoordinationHint,
  WebSessionHostPorts,
} from "../coordination-ports";
import { webSessionCoordinationRecordSchema } from "../coordination-record";
import { WebCookieSessionAdapter } from "../web-cookie-session-adapter";
import {
  createWebSessionHostController,
  createWebSessionHostControllerFromAdapter,
} from "../web-session-host-controller";

const sessionA = {
  expires_at: 2_000_000_000,
  session_id: "11111111-1111-4111-8111-111111111111",
  user: {
    email: "a@example.com",
    id: "user-a",
    name: "A",
    status: "active",
  },
};

const guestSession = {
  expires_at: 2_000_000_050,
  session_id: "33333333-3333-4333-8333-333333333333",
  user: {
    email: "g-0123abcd@guest.comma.invalid",
    id: "guest-user",
    kind: "guest",
    name: "Guest",
    status: "active",
  },
};

const guestImportMarkerKey = "comma.guestImportPending.v1:https://api.example";

const sessionB = {
  expires_at: 2_000_000_100,
  session_id: "22222222-2222-4222-8222-222222222222",
  user: {
    email: "b@example.com",
    id: "user-b",
    name: "B",
    status: "active",
  },
};

describe("WebCookieSessionAdapter", () => {
  it("coordinates a Telegram renewal with the other tab's Cookie projection", async () => {
    const harness = createHarness(sessionA);
    const peer = harness.createAdapter();
    await peer.reconcile({ reason: "startup" });
    const oldLease = peer.getProductLease();
    const renewed = { ...sessionA, session_id: "renewed-panel-session" };
    harness.ports.fetch = async (url, init) => {
      if (String(url).endsWith("/v1/comma/auth/telegram-miniapp")) {
        harness.server.session = renewed;
        return jsonResponse(renewed);
      }
      return harness.server.fetch(url, init);
    };
    const panel = harness.createAdapter();
    await expect(
      panel.exchangeTelegramLaunch({ initData: "signed-launch", groupId: "group-1" })
    ).resolves.toBe("signed_in");
    await expect.poll(() => peer.getProductLease()?.sessionId).toBe(renewed.session_id);
    expect(panel.getProductLease()?.sessionId).toBe(renewed.session_id);
    expect(oldLease?.signal.aborted).toBe(true);
    expect(harness.onlyStoredValue()).not.toContain("signed-launch");
    peer.dispose();
    panel.dispose();
  });

  it("recovers a lost Telegram exchange response without replaying launch credentials", async () => {
    const harness = createHarness(sessionA);
    const panel = harness.createAdapter();
    await panel.reconcile({ reason: "startup" });
    const renewed = { ...sessionA, session_id: "renewed-panel-session" };
    let exchanges = 0;
    harness.ports.fetch = async (url, init) => {
      if (String(url).endsWith("/v1/comma/auth/telegram-miniapp")) {
        exchanges += 1;
        harness.server.session = renewed;
        throw new TypeError("Response lost after Cookie mutation");
      }
      return harness.server.fetch(url, init);
    };
    await expect(
      panel.exchangeTelegramLaunch({ initData: "signed-launch", groupId: "group-1" })
    ).resolves.toBe("failed");
    expect(panel.getProductLease()).toBeUndefined();
    await panel.recover();
    expect(panel.getProductLease()?.sessionId).toBe(renewed.session_id);
    expect(exchanges).toBe(1);
    panel.dispose();
  });

  it("separates the global Cookie authority from each tab projection", async () => {
    const harness = createHarness(sessionA);
    const first = harness.createAdapter();
    const second = harness.createAdapter();

    await expect(first.reconcile({ reason: "startup" })).resolves.toMatchObject({
      ok: true,
    });
    await expect(second.reconcile({ reason: "startup" })).resolves.toMatchObject({
      ok: true,
    });

    expect(first.getSnapshotSync()).toMatchObject({
      authority: { kind: "web_cookie" },
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(second.getSnapshotSync()).toMatchObject({
      authority: { kind: "web_cookie" },
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(first.authorityInstanceId).not.toBe(second.authorityInstanceId);

    expect(harness.server.calls[0]?.expectedSessionId).toBe("unknown");
    expect(harness.server.calls[1]?.expectedSessionId).toBe(sessionA.session_id);
    for (const call of harness.server.calls) {
      expect(call.lifecycleVersion).toBe("1");
      expect(call.transport).toBe("cookie");
      expect(call.credentials).toBe("include");
    }

    const rawRecord = harness.onlyStoredValue();
    expect(rawRecord).not.toContain("a@example.com");
    expect(rawRecord).not.toContain("user-a");

    const record = webSessionCoordinationRecordSchema.parse(JSON.parse(rawRecord));
    const persistedStrings = collectStrings(record);
    expect(persistedStrings).not.toContain(first.authorityInstanceId);
    expect(persistedStrings).not.toContain(second.authorityInstanceId);
    expect(record).toMatchObject({
      cookieAuthorityId: first.getProductLease()?.cookieAuthorityId,
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    expect(first.getProductLease()?.cookieAuthorityId).toBe(
      second.getProductLease()?.cookieAuthorityId
    );
  });

  it("keeps one product transport identity while a focus probe preserves the exact lease", async () => {
    const harness = createHarness(sessionA);
    const controller = createWebSessionHostController({
      apiBaseUrl: "https://api.example",
      ports: harness.ports,
    });
    await controller.initialize();
    const before = controller.lifecycle.getSnapshotSync();
    const firstTransport = controller.getProductTransport();
    if (before.phase !== "signed_in" || !firstTransport) {
      throw new Error("Expected a signed-in product transport.");
    }

    await expect(
      controller.lifecycle.reconcile({
        expected: sessionExpectation(before),
        reason: "focus",
      })
    ).resolves.toMatchObject({ ok: true });

    const after = controller.lifecycle.getSnapshotSync();
    expect(after).toMatchObject({
      generation: before.generation,
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(after.revision).toBeGreaterThan(before.revision);
    expect(controller.getProductTransport()).toBe(firstTransport);
    controller.dispose?.();
  });

  it("fences sign-out before a focus probe lock and rejects stale readmission", async () => {
    const harness = createHarness(sessionA);
    const controller = createWebSessionHostController({
      apiBaseUrl: "https://api.example",
      ports: harness.ports,
    });
    await controller.initialize();
    const signedIn = controller.lifecycle.getSnapshotSync();
    const transport = controller.getProductTransport();
    if (signedIn.phase !== "signed_in" || !transport) {
      throw new Error("Expected a signed-in product transport.");
    }

    const api = createCommaApi({
      baseUrl: "https://api.example",
      fetch: harness.server.fetch,
      sessionTransport: transport,
      token: "",
    });
    const probeStarted = harness.server.hangNextProbeBody();
    const focusProbe = controller.lifecycle.reconcile({
      expected: sessionExpectation(signedIn),
      reason: "focus",
    });
    await probeStarted;

    const signOut = controller.lifecycle.signOut({
      expected: sessionExpectation(signedIn),
    });

    expect(controller.lifecycle.getSnapshotSync().phase).toBe("signing_out");
    expect(transport.signal.aborted).toBe(true);
    expect(controller.getProductTransport()).toBeUndefined();
    await expect(api.listWorkspaces()).rejects.toMatchObject({
      name: "AbortError",
    });
    expect(harness.server.productCalls).toEqual([]);

    expect(harness.runScheduled(2_000)).toBe(1);
    await expect(signOut).resolves.toMatchObject({
      error: { code: "network_unavailable", operation: "sign_out" },
      ok: false,
    });
    expect(controller.lifecycle.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    expect(
      harness.server.calls.filter((call) => call.url.endsWith("/v1/comma/auth/logout"))
    ).toEqual([]);

    expect(harness.runScheduled(8_000)).toBe(1);
    await expect(focusProbe).resolves.toMatchObject({
      error: { code: "network_unavailable", operation: "reconcile" },
      ok: false,
    });
    expect(controller.lifecycle.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    controller.dispose?.();
  });

  it("keeps a signed-in tab and its lease through a 503 and re-probes in the background", async () => {
    const harness = createHarness(sessionA);
    const probingTab = harness.createAdapter();
    const peerTab = harness.createAdapter();
    await probingTab.reconcile({ reason: "startup" });
    await peerTab.reconcile({ reason: "startup" });

    const probingLease = probingTab.getProductLease();
    const peerLease = peerTab.getProductLease();
    expect(probingLease).toBeDefined();
    expect(peerLease).toBeDefined();
    const phases: string[] = [];
    probingTab.subscribe((snapshot) => phases.push(snapshot.phase));

    harness.server.enqueueProbeStatus(503);
    const snapshot = probingTab.getSnapshotSync();
    if (snapshot.phase !== "signed_in") {
      throw new Error("Expected a signed-in probing tab.");
    }
    const result = await probingTab.reconcile({
      expected: sessionExpectation(snapshot),
      reason: "peer_mutation",
    });

    expect(result).toMatchObject({
      error: { code: "session_probe_unavailable" },
      ok: false,
    });
    expect(probingTab.getSnapshotSync().phase).toBe("signed_in");
    expect(probingTab.getProductLease()?.signal).toBe(probingLease?.signal);
    expect(probingLease?.signal.aborted).toBe(false);
    expect(peerTab.getSnapshotSync().phase).toBe("signed_in");
    expect(peerLease?.signal.aborted).toBe(false);

    const probesBefore = harness.server.calls.length;
    expect(harness.runScheduled(1_000)).toBe(1);
    await eventually(() => harness.server.calls.length === probesBefore + 1);
    await eventually(() => probingTab.getSnapshotSync().revision > snapshot.revision);

    expect(probingTab.getSnapshotSync()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(probingLease?.signal.aborted).toBe(false);
    expect(phases.filter((phase) => phase !== "signed_in")).toEqual([]);
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
  });

  it("keeps the view and lease while confirming a peer's Cookie rebind", async () => {
    const harness = createHarness(sessionA);
    const tab = harness.createAdapter();
    await tab.reconcile({ reason: "startup" });
    const lease = tab.getProductLease();
    const before = tab.getSnapshotSync();
    const phases: string[] = [];
    tab.subscribe((snapshot) => phases.push(snapshot.phase));

    // A peer that finds no coordination record rebinds and announces it.
    harness.storage.values.clear();
    const peer = harness.createAdapter();
    await peer.reconcile({ reason: "startup" });
    await eventually(() => tab.getSnapshotSync().revision > before.revision);

    expect(phases.filter((phase) => phase !== "signed_in")).toEqual([]);
    expect(lease?.signal.aborted).toBe(false);
    expect(tab.getProductLease()?.signal).toBe(lease?.signal);
    expect(tab.getSnapshotSync()).toMatchObject({
      generation: before.generation,
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
  });

  it("commits global absence on a strict current 401 and revokes peers", async () => {
    const harness = createHarness(sessionA);
    const probingTab = harness.createAdapter();
    const peerTab = harness.createAdapter();
    await probingTab.reconcile({ reason: "startup" });
    await peerTab.reconcile({ reason: "startup" });
    const peerLease = peerTab.getProductLease();
    const generationBefore = harness.currentRecord().cookieGeneration;

    harness.server.session = undefined;
    const snapshot = probingTab.getSnapshotSync();
    if (snapshot.phase !== "signed_in") {
      throw new Error("Expected a signed-in probing tab.");
    }
    await probingTab.reconcile({
      expected: sessionExpectation(snapshot),
      reason: "focus",
    });
    await eventually(() => peerTab.getSnapshotSync().phase === "signed_out");

    expect(probingTab.getSnapshotSync()).toMatchObject({
      phase: "signed_out",
      reason: "unauthorized",
    });
    expect(peerTab.getSnapshotSync()).toMatchObject({
      phase: "signed_out",
      reason: "unauthorized",
    });
    expect(peerLease?.signal.aborted).toBe(true);
    expect(harness.currentRecord()).toMatchObject({
      cookieGeneration: generationBefore + 1,
      kind: "stable",
      state: { kind: "absent" },
    });
  });

  it("settles an exact current product 401 under the coordination lock", async () => {
    const harness = createHarness(sessionA);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const lease = adapter.getProductLease();
    if (!lease) {
      throw new Error("Expected a product lease.");
    }

    harness.server.session = undefined;
    adapter.reportProductUnauthorized(lease);
    await eventually(() => adapter.getSnapshotSync().phase === "signed_out");

    expect(lease.signal.aborted).toBe(true);
    expect(harness.server.calls.at(-1)).toMatchObject({
      expectedSessionId: sessionA.session_id,
      lifecycleVersion: "1",
    });
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "absent" },
    });
  });

  it("keeps the HTTP deadline through a hanging 200 body and releases initialization lock", async () => {
    const harness = createHarness(sessionA);
    const adapter = harness.createAdapter();
    const responseHeadersReceived = harness.server.hangNextProbeBody();

    const initialization = adapter.reconcile({ reason: "startup" });
    await responseHeadersReceived;
    expect(harness.locks.activeCount).toBe(1);
    expect(harness.runScheduled(8_000)).toBe(1);

    await expect(initialization).resolves.toMatchObject({
      error: { code: "network_unavailable" },
      ok: false,
    });
    expect(harness.locks.activeCount).toBe(0);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable" },
    });
  });

  it("closes this tab's product gate before a product 401 waits for the global lock", async () => {
    const harness = createHarness(sessionA);
    const controller = createWebSessionHostController({
      apiBaseUrl: "https://api.example",
      ports: harness.ports,
    });
    await controller.initialize();
    const transport = controller.getProductTransport();
    if (!transport) {
      throw new Error("Expected a product transport.");
    }

    const lockName = harness.locks.requests.at(-1)?.name;
    if (!lockName) {
      throw new Error("Expected the Web Session coordination lock name.");
    }
    const lockAcquired = deferred<void>();
    const releaseLock = deferred<void>();
    const heldLock = harness.locks.request(
      lockName,
      new AbortController().signal,
      async () => {
        lockAcquired.resolve();
        await releaseLock.promise;
      }
    );
    await lockAcquired.promise;

    harness.server.productStatus = 401;
    const api = createCommaApi({
      baseUrl: "https://api.example",
      fetch: harness.server.fetch,
      sessionTransport: transport,
      token: "",
    });

    await expect(api.listWorkspaces()).rejects.toMatchObject({ status: 401 });
    expect(transport.signal.aborted).toBe(true);
    expect(controller.getProductTransport()).toBeUndefined();
    expect(harness.locks.activeCount).toBe(1);
    expect(harness.server.productCalls).toEqual([
      {
        authorization: null,
        credentials: "include",
        expectedSessionId: sessionA.session_id,
      },
    ]);

    await expect(api.listWorkspaces()).rejects.toMatchObject({
      name: "AbortError",
    });
    expect(harness.server.productCalls).toHaveLength(1);

    releaseLock.resolve();
    await heldLock;
    await eventually(
      () => controller.lifecycle.getSnapshotSync().phase === "signed_out"
    );
    controller.dispose?.();
  });

  it("ignores an account A product 401 after account B becomes current", async () => {
    const harness = createHarness(sessionA);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const leaseA = adapter.getProductLease();
    const signedInA = adapter.getSnapshotSync();
    if (!leaseA || signedInA.phase !== "signed_in") {
      throw new Error("Expected account A to be signed in.");
    }

    await expect(
      adapter.signOut({ expected: sessionExpectation(signedInA) })
    ).resolves.toMatchObject({ ok: true });
    const signedOut = adapter.getSnapshotSync();
    if (signedOut.phase !== "signed_out") {
      throw new Error("Expected account A to be signed out.");
    }

    harness.server.emailVerificationSession = sessionB;
    const challenge = await adapter.requestEmailLogin({
      email: sessionB.user.email,
      expected: sessionExpectation(signedOut),
    });
    if (!challenge.ok) {
      throw new Error("Expected account B's email challenge.");
    }
    await expect(
      adapter.verifyEmailLogin({
        attempt: challenge.value.attempt,
        challengeId: challenge.value.challengeId,
        code: "123456",
      })
    ).resolves.toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        session: { sessionId: sessionB.session_id },
      },
    });

    const leaseB = adapter.getProductLease();
    const callsBefore = harness.server.calls.length;
    adapter.reportProductUnauthorized(leaseA);

    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionB.session_id },
    });
    expect(leaseB?.signal.aborted).toBe(false);
    expect(harness.server.calls).toHaveLength(callsBefore);
  });

  it("fails auth mutation closed when Web Locks disappears", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const snapshot = adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") {
      throw new Error("Expected proven absence.");
    }
    const callsBefore = harness.server.calls.length;
    harness.ports.locks = undefined;

    const result = await adapter.requestEmailLogin({
      email: "person@example.com",
      expected: sessionExpectation(snapshot),
    });

    expect(result).toMatchObject({
      error: { code: "unsupported" },
      ok: false,
    });
    expect(harness.server.calls).toHaveLength(callsBefore);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
  });

  it("persists only the active lifecycle attempt and operation epoch", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const snapshot = adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") {
      throw new Error("Expected proven absence.");
    }

    const challenge = await adapter.requestEmailLogin({
      email: "person@example.com",
      expected: sessionExpectation(snapshot),
    });
    if (!challenge.ok) {
      throw new Error("Expected an email challenge.");
    }

    const authenticating = harness.currentRecord();
    expect(authenticating).toMatchObject({
      activeAuthAttemptId: challenge.value.attempt.attemptId,
      kind: "authenticating",
      operationEpoch: expect.any(Number),
      state: { kind: "absent" },
    });
    const persistedStrings = collectStrings(authenticating);
    expect(persistedStrings).not.toContain("challenge-1");
    expect(persistedStrings).not.toContain("123456");
    expect(persistedStrings).not.toContain("person@example.com");

    const verified = await adapter.verifyEmailLogin({
      attempt: challenge.value.attempt,
      challengeId: challenge.value.challengeId,
      code: "123456",
    });

    expect(verified).toMatchObject({
      ok: true,
      value: {
        phase: "signed_in",
        session: { sessionId: sessionA.session_id },
      },
    });
    const verifyCall = harness.server.calls.find((call) =>
      call.url.endsWith("/v1/comma/auth/email/verify")
    );
    expect(verifyCall?.body).toEqual({
      challenge_id: "challenge-1",
      client_kind: "web",
      client_platform: expect.stringMatching(
        /^(android|ios|linux|macos|unknown|windows)$/
      ),
      code: "123456",
    });
    expect(harness.server.calls.slice(-2)).toEqual([
      expect.objectContaining({ expectedSessionId: "none" }),
      expect.objectContaining({ expectedSessionId: "none" }),
    ]);
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
  });

  it("returns a typed unknown failure when cancelling waits past the Web lock deadline", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const snapshot = adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") {
      throw new Error("Expected proven absence.");
    }

    const challenge = await adapter.requestEmailLogin({
      email: "person@example.com",
      expected: sessionExpectation(snapshot),
    });
    if (!challenge.ok) {
      throw new Error("Expected an email challenge.");
    }

    harness.ports.locks = {
      request(_name, signal) {
        return new Promise((_resolve, reject) => {
          signal.addEventListener(
            "abort",
            () => reject(new DOMException("Lock request aborted.", "AbortError")),
            { once: true }
          );
        });
      },
    };
    harness.ports.schedule = (callback) => {
      queueMicrotask(callback);
      return 1;
    };
    harness.ports.unschedule = () => {};

    const result = await adapter.cancelAuthAttempt({
      attempt: challenge.value.attempt,
    });

    expect(result).toMatchObject({
      error: { code: "unknown", operation: "cancel_auth_attempt" },
      ok: false,
    });
    if (result.ok) {
      throw new Error("Expected cancellation to fail closed.");
    }
    expect(
      sessionOperationErrorSchemaFor("cancel_auth_attempt").safeParse(result.error)
        .success
    ).toBe(true);
  });

  it("maps a rejected Google credential to a legal terminal sign-in error", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const snapshot = adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") {
      throw new Error("Expected proven absence.");
    }

    const preparation = await adapter.beginGoogleLogin({
      expected: sessionExpectation(snapshot),
    });
    if (!preparation.ok) {
      throw new Error("Expected a Google sign-in attempt.");
    }
    harness.server.googleCompletionStatus = 401;

    const result = await adapter.completeGoogleLogin({
      attempt: preparation.value.attempt,
      credential: "rejected-google-credential",
      nonce: preparation.value.nonce,
      providerAttemptId: preparation.value.providerAttemptId,
    });

    expect(result).toMatchObject({
      error: { code: "unknown", retryable: false },
      ok: false,
    });
    expect(harness.server.calls.at(-1)?.body).toEqual({
      attempt_id: "google-attempt-1",
      client_kind: "web",
      client_platform: expect.stringMatching(
        /^(android|ios|linux|macos|unknown|windows)$/
      ),
      credential: "rejected-google-credential",
      nonce: "google-nonce",
    });
    if (result.ok) {
      throw new Error("Expected Google sign-in to fail.");
    }
    expect(
      sessionOperationErrorSchemaFor("sign_in_with_google").safeParse(result.error)
        .success
    ).toBe(true);
  });

  it("starts zero Cookie requests when strict record persistence fails", async () => {
    const harness = createHarness(undefined);
    harness.storage.failWrites = true;
    const adapter = harness.createAdapter();

    const result = await adapter.reconcile({ reason: "startup" });

    expect(result).toMatchObject({
      error: { code: "credential_store_unavailable" },
      ok: false,
    });
    expect(harness.server.calls).toHaveLength(0);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_store_unavailable" },
    });
  });

  it("revokes the tab lease when a peer hint cannot read coordination storage", async () => {
    const harness = createHarness(sessionA);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const lease = adapter.getProductLease();
    expect(lease).toBeDefined();
    harness.storage.failReads = true;

    harness.broadcast.emitAll({
      canonicalApiOrigin: adapter.canonicalApiOrigin,
      cookieAuthorityId: "external-cookie-authority",
      cookieGeneration: 9,
      coordinationRevision: 9,
      kind: "session_maybe_changed",
      schemaVersion: 1,
      senderId: "external-sender",
    });

    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_store_unavailable" },
    });
    expect(lease?.signal.aborted).toBe(true);
  });

  it("renews an exhausted recovery ticket after an explicit retry", async () => {
    const harness = createHarness(undefined);
    harness.server.defaultProbeStatus = 503;
    const adapter = harness.createAdapter();

    await adapter.reconcile({ reason: "startup" });
    expect(harness.server.calls).toHaveLength(1);

    harness.advance(500);
    await adapter.recover();
    expect(harness.server.calls).toHaveLength(2);

    expect(harness.currentRecord()).toMatchObject({
      kind: "recovering",
      ticket: {
        attemptsStarted: 2,
        maxAttempts: 2,
        progress: { phase: "exhausted" },
      },
    });

    harness.server.defaultProbeStatus = undefined;
    harness.advance(500);
    await adapter.recover();
    expect(harness.server.calls).toHaveLength(3);
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "absent" },
    });
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_out",
      reason: "no_session",
    });
    expect(harness.locks.requests.every((request) => !request.steal)).toBe(true);
  });

  it("lets an explicit retry bypass the automatic recovery backoff", async () => {
    const harness = createHarness(undefined);
    harness.server.defaultProbeStatus = 503;
    const adapter = harness.createAdapter();

    await adapter.reconcile({ reason: "startup" });
    expect(harness.server.calls).toHaveLength(1);

    harness.server.defaultProbeStatus = undefined;
    await adapter.recover();

    expect(harness.server.calls).toHaveLength(2);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_out",
      reason: "no_session",
    });
  });

  it("accepts a session response with fields added by a newer backend", async () => {
    const harness = createHarness({
      ...sessionA,
      user: { ...sessionA.user, avatar_id: "avt_new" },
      workspace_hint: "wsp_new",
    } as typeof sessionA);
    const adapter = harness.createAdapter();

    await adapter.reconcile({ reason: "startup" });

    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
  });

  it("rejects a session response that reflects a bearer to the Cookie transport", async () => {
    const harness = createHarness({
      ...sessionA,
      token: "reflected",
    } as typeof sessionA);
    const adapter = harness.createAdapter();

    await adapter.reconcile({ reason: "startup" });

    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
    expect(adapter.getProductLease()).toBeUndefined();
  });

  it("rejects a late Google credential after guest sign-in replaces its attempt", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    const host = createWebSessionHostControllerFromAdapter(adapter);
    await host.initialize();
    const snapshot = adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") throw new Error("Expected signed out.");
    const preparation = await adapter.beginGoogleLogin({
      expected: sessionExpectation(snapshot),
    });
    if (!preparation.ok) throw new Error("Expected Google preparation.");

    await host.guest!.start();
    const callCount = harness.server.calls.length;
    await expect(
      adapter.completeGoogleLogin({
        attempt: preparation.value.attempt,
        credential: "late-google-credential",
        nonce: preparation.value.nonce,
        providerAttemptId: preparation.value.providerAttemptId,
      })
    ).resolves.toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(harness.server.calls).toHaveLength(callCount);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_in",
      principal: { kind: "guest" },
      session: { sessionId: guestSession.session_id },
    });
    host.dispose?.();
  });

  it("hands a guest Cookie session off and imports its chat after the next sign-in", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    await expect(adapter.guestAvailability()).resolves.toBe(true);
    expect(
      harness.server.calls.find(
        (call) => call.method === "GET" && call.url.endsWith("/v1/comma/auth/guest")
      )
    ).toMatchObject({
      expectedSessionId: "none",
      lifecycleVersion: "1",
      transport: "cookie",
    });

    const started = await adapter.startGuestSession({
      expected: sessionExpectation(adapter.getSnapshotSync() as never) as never,
    });
    expect(started).toMatchObject({
      ok: true,
      value: { phase: "signed_in", principal: { kind: "guest" } },
    });
    const guestStart = harness.server.calls.find(
      (call) => call.method === "POST" && call.url.endsWith("/v1/comma/auth/guest")
    );
    expect(guestStart?.body).toMatchObject({
      client_kind: "web",
      pow: { challenge: "gpow1.c2.mac" },
    });
    expect(solvesGuestChallenge(guestStart?.body)).toBe(true);

    const handoff = await adapter.beginGuestSignUp({
      expected: sessionExpectation(adapter.getSnapshotSync() as never),
    });
    expect(handoff).toMatchObject({
      ok: true,
      value: { phase: "signed_out", reason: "guest_handoff" },
    });
    expect(harness.storage.values.get(guestImportMarkerKey)).toBe(
      JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
    );
    expect(harness.server.calls.some((call) => call.url.endsWith("/auth/logout"))).toBe(
      false
    );

    let imported = 0;
    adapter.subscribeGuestImported(() => {
      imported += 1;
    });
    const requested = await adapter.requestEmailLogin({
      email: "a@example.com",
      expected: sessionExpectation(adapter.getSnapshotSync() as never) as never,
    });
    if (!requested.ok) throw new Error("Expected an email challenge.");
    await adapter.verifyEmailLogin({
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "123456",
    });

    await eventually(() => imported === 1);
    const importCall = harness.server.calls.find((call) =>
      call.url.endsWith("/v1/comma/guest-imports")
    );
    expect(importCall).toMatchObject({
      body: {},
      credentials: "include",
      expectedSessionId: sessionA.session_id,
      method: "POST",
    });
    expect(harness.server.guestClaimCookie).toBe(false);
    expect(harness.storage.values.get(guestImportMarkerKey)).toBe("");
    adapter.dispose();
  });

  it("retries a rejected guest proof of work once with a fresh challenge", async () => {
    const harness = createHarness(undefined);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const guestPosts = () =>
      harness.server.calls.filter(
        (call) => call.method === "POST" && call.url.endsWith("/v1/comma/auth/guest")
      );

    harness.server.guestPowRejections = 1;
    await expect(
      adapter.startGuestSession({
        expected: sessionExpectation(adapter.getSnapshotSync() as never) as never,
      })
    ).resolves.toMatchObject({
      ok: true,
      value: { phase: "signed_in", principal: { kind: "guest" } },
    });
    expect(guestPosts().map((call) => call.body)).toMatchObject([
      { pow: { challenge: "gpow1.c1.mac" } },
      { pow: { challenge: "gpow1.c2.mac" } },
    ]);
    adapter.dispose();

    const rejected = createHarness(undefined);
    const second = rejected.createAdapter();
    await second.reconcile({ reason: "startup" });
    rejected.server.guestPowRejections = 2;
    await expect(
      second.startGuestSession({
        expected: sessionExpectation(second.getSnapshotSync() as never) as never,
      })
    ).resolves.toMatchObject({ error: { code: "unknown" }, ok: false });
    expect(rejected.server.guestChallenges).toBe(2);
    expect(
      rejected.server.calls.filter(
        (call) => call.method === "POST" && call.url.endsWith("/v1/comma/auth/guest")
      )
    ).toHaveLength(2);
    expect(second.getSnapshotSync()).toMatchObject({
      phase: "signed_out",
      reason: "no_session",
    });
    second.dispose();
  });

  it("drops a pending guest import the server no longer recognizes", async () => {
    const harness = createHarness(sessionA);
    harness.storage.values.set(
      guestImportMarkerKey,
      JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
    );
    const adapter = harness.createAdapter();
    let imported = 0;
    adapter.subscribeGuestImported(() => {
      imported += 1;
    });

    await adapter.reconcile({ reason: "startup" });

    await eventually(() => harness.storage.values.get(guestImportMarkerKey) === "");
    expect(imported).toBe(0);
    adapter.dispose();
  });

  it("rebinds to the Cookie's current session after a 409 without an error state", async () => {
    const harness = createHarness(sessionA);
    const adapter = harness.createAdapter();
    await adapter.reconcile({ reason: "startup" });
    const signedIn = adapter.getSnapshotSync();
    const leaseA = adapter.getProductLease();
    if (signedIn.phase !== "signed_in" || !leaseA) {
      throw new Error("Expected the initial Cookie Session.");
    }
    const phases: string[] = [];
    adapter.subscribe((snapshot) => phases.push(snapshot.phase));

    // Another tab signed in as B: the shared Cookie now names B's session.
    harness.server.session = sessionB;
    adapter.reportProductSessionChanged(leaseA);
    await eventually(
      () =>
        adapter.getSnapshotSync().phase === "signed_in" &&
        adapter.getProductLease()?.sessionId === sessionB.session_id
    );

    expect(phases).not.toContain("indeterminate");
    expect(
      harness.server.calls.map((call) => call.expectedSessionId).slice(-2)
    ).toEqual([sessionA.session_id, "unknown"]);
    expect(leaseA.signal.aborted).toBe(true);
    expect(adapter.getSnapshotSync()).toMatchObject({
      phase: "signed_in",
      principal: { userId: sessionB.user.id },
      session: { sessionId: sessionB.session_id },
    });
    expect(harness.currentRecord()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionB.session_id },
    });
  });
});

function createHarness(initialSession: typeof sessionA | undefined) {
  const storage = new FakeStorage();
  const locks = new FakeLocks();
  const broadcast = new FakeBroadcastHub();
  const server = new FakeCookieServer(initialSession);
  let now = 10_000;
  let nextId = 0;
  let nextTimer = 0;
  const timers = new Map<
    number,
    {
      callback: () => void;
      delayMs: number;
      timer: ReturnType<typeof setTimeout>;
    }
  >();

  const ports: WebSessionHostPorts = {
    broadcast,
    documentOrigin: "https://app.example",
    fetch: server.fetch,
    locks,
    now: () => now,
    randomId: () => `test-id-${++nextId}`,
    schedule(callback, delayMs) {
      const handle = ++nextTimer;
      const timer = setTimeout(() => {
        timers.delete(handle);
        callback();
      }, delayMs);
      timers.set(handle, { callback, delayMs, timer });
      return handle;
    },
    storage,
    unschedule(handle) {
      const scheduled = timers.get(handle);
      if (scheduled) {
        clearTimeout(scheduled.timer);
        timers.delete(handle);
      }
    },
  };

  return {
    advance(deltaMs: number) {
      now += deltaMs;
    },
    broadcast,
    createAdapter() {
      return new WebCookieSessionAdapter({
        baseUrl: "https://api.example",
        ports,
      });
    },
    currentRecord() {
      return webSessionCoordinationRecordSchema.parse(
        JSON.parse(this.onlyStoredValue())
      );
    },
    locks,
    onlyStoredValue() {
      const values = [...storage.values.values()];
      if (values.length !== 1 || !values[0]) {
        throw new Error(`Expected one stored record, received ${values.length}.`);
      }
      return values[0];
    },
    ports,
    runScheduled(delayMs: number) {
      const scheduled = [...timers.entries()].filter(
        ([, timer]) => timer.delayMs === delayMs
      );
      for (const [handle, timer] of scheduled) {
        clearTimeout(timer.timer);
        timers.delete(handle);
        timer.callback();
      }
      return scheduled.length;
    },
    server,
    storage,
  };
}

class FakeStorage {
  readonly values = new Map<string, string>();
  failReads = false;
  failWrites = false;

  read(key: string) {
    if (this.failReads) {
      throw new Error("injected storage read failure");
    }
    return this.values.get(key) ?? null;
  }

  write(key: string, value: string) {
    if (this.failWrites) {
      throw new Error("injected storage failure");
    }
    this.values.set(key, value);
  }
}

class FakeLocks {
  readonly requests: Array<{ name: string; steal: false }> = [];
  activeCount = 0;
  private tails = new Map<string, Promise<void>>();

  async request<T>(
    name: string,
    signal: AbortSignal,
    work: () => Promise<T>
  ): Promise<T> {
    this.requests.push({ name, steal: false });
    const previous = this.tails.get(name) ?? Promise.resolve();
    let release!: () => void;
    const next = new Promise<void>((resolve) => {
      release = resolve;
    });
    this.tails.set(
      name,
      previous.then(() => next)
    );
    try {
      await waitForLockTurn(previous, signal);
    } catch (error) {
      release();
      throw error;
    }
    if (signal.aborted) {
      release();
      throw new DOMException("Lock request aborted.", "AbortError");
    }
    this.activeCount += 1;
    try {
      return await work();
    } finally {
      this.activeCount -= 1;
      release();
    }
  }
}

function waitForLockTurn(previous: Promise<void>, signal: AbortSignal) {
  if (signal.aborted) {
    return Promise.reject(
      signal.reason ?? new DOMException("Lock request aborted.", "AbortError")
    );
  }
  return new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      signal.removeEventListener("abort", onAbort);
    };
    const onAbort = () => {
      cleanup();
      reject(signal.reason ?? new DOMException("Lock request aborted.", "AbortError"));
    };
    signal.addEventListener("abort", onAbort, { once: true });
    void previous.then(
      () => {
        cleanup();
        resolve();
      },
      (error: unknown) => {
        cleanup();
        reject(error);
      }
    );
  });
}

class FakeBroadcastHub {
  private readonly listeners = new Map<string, Set<(hint: unknown) => void>>();

  emitAll(hint: unknown) {
    for (const listeners of this.listeners.values()) {
      for (const listener of listeners) {
        listener(structuredClone(hint));
      }
    }
  }

  open(name: string): WebSessionBroadcastChannel {
    const listeners = this.listeners.get(name) ?? new Set();
    this.listeners.set(name, listeners);
    return {
      close() {},
      publish: (hint: WebSessionCoordinationHint) => {
        for (const listener of listeners) {
          listener(structuredClone(hint));
        }
      },
      subscribe(listener) {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    };
  }
}

class FakeCookieServer {
  readonly calls: Array<{
    body: unknown;
    credentials: RequestCredentials | undefined;
    expectedSessionId: string | null;
    lifecycleVersion: string | null;
    method: string | undefined;
    transport: string | null;
    url: string;
  }> = [];
  defaultProbeStatus: number | undefined;
  emailVerificationSession: typeof sessionA = sessionA;
  googleCompletionStatus = 200;
  guestChallenges = 0;
  guestClaimCookie = false;
  guestPowRejections = 0;
  readonly productCalls: Array<{
    authorization: string | null;
    credentials: RequestCredentials | undefined;
    expectedSessionId: string | null;
  }> = [];
  productStatus: number | undefined;
  session: typeof sessionA | undefined;
  private hangingProbeStarted: ReturnType<typeof deferred<void>> | undefined;
  private readonly queuedProbeStatuses: number[] = [];

  constructor(initialSession: typeof sessionA | undefined) {
    this.session = initialSession;
  }

  enqueueProbeStatus(status: number) {
    this.queuedProbeStatuses.push(status);
  }

  hangNextProbeBody() {
    this.hangingProbeStarted = deferred<void>();
    return this.hangingProbeStarted.promise;
  }

  fetch: typeof fetch = async (input, init) => {
    if (init?.signal?.aborted) {
      throw init.signal.reason ?? new DOMException("aborted", "AbortError");
    }
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    const headers = new Headers(init?.headers);
    const expectedSessionId = headers.get("x-comma-expected-auth-session-id");
    this.calls.push({
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
      credentials: init?.credentials,
      expectedSessionId,
      lifecycleVersion: headers.get("x-comma-session-lifecycle-version"),
      method: init?.method,
      transport: headers.get("x-comma-session-transport"),
      url,
    });

    if (url.endsWith("/v1/comma/auth/session")) {
      if (this.hangingProbeStarted) {
        const started = this.hangingProbeStarted;
        this.hangingProbeStarted = undefined;
        started.resolve();
        return hangingJsonResponse(init?.signal);
      }
      const override = this.queuedProbeStatuses.shift() ?? this.defaultProbeStatus;
      if (override) {
        return jsonResponse({ error: "session_probe_unavailable" }, override);
      }
      if (!this.session) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }
      if (
        expectedSessionId === "unknown" ||
        expectedSessionId === this.session.session_id
      ) {
        return jsonResponse(this.session);
      }
      return jsonResponse({ error: "session_changed" }, 409);
    }

    if (url.endsWith("/v1/comma/auth/email/login")) {
      return jsonResponse({ challenge_id: "challenge-1", code: "123456" });
    }

    if (url.endsWith("/v1/comma/auth/email/verify")) {
      this.session = this.emailVerificationSession;
      return jsonResponse(this.emailVerificationSession);
    }

    if (url.endsWith("/v1/comma/auth/google/attempt")) {
      return jsonResponse({
        attempt_id: "google-attempt-1",
        client_id: "google-client-id",
        nonce: "google-nonce",
        platform: "web",
      });
    }

    if (url.endsWith("/v1/comma/auth/google")) {
      if (this.googleCompletionStatus === 401) {
        return jsonResponse({ error: "invalid_google_credential" }, 401);
      }
      this.session = this.emailVerificationSession;
      return jsonResponse(this.emailVerificationSession);
    }

    if (url.endsWith("/v1/comma/auth/guest") && init?.method === "GET") {
      // The server's lifecycle protocol rejects a web request without the
      // signed-out Cookie transport headers before it reaches the route.
      if (
        headers.get("x-comma-session-transport") !== "cookie" ||
        headers.get("x-comma-session-lifecycle-version") !== "1" ||
        expectedSessionId !== "none"
      ) {
        return jsonResponse({ error: "invalid_session_transport" }, 400);
      }
      this.guestChallenges += 1;
      return jsonResponse({
        enabled: true,
        pow: {
          challenge: `gpow1.c${this.guestChallenges}.mac`,
          difficulty: guestPowDifficulty,
          expires_at: 2_000_000_000,
        },
      });
    }

    if (url.endsWith("/v1/comma/auth/guest")) {
      if (
        !solvesGuestChallenge(this.calls.at(-1)?.body) ||
        this.guestPowRejections > 0
      ) {
        this.guestPowRejections = Math.max(0, this.guestPowRejections - 1);
        return jsonResponse({ error: "guest_pow_invalid" }, 400);
      }
      this.session = guestSession;
      return jsonResponse(guestSession);
    }

    if (url.endsWith("/v1/comma/auth/guest/handoff")) {
      this.session = undefined;
      this.guestClaimCookie = true;
      return jsonResponse({ expires_at: 2_000_000_000 });
    }

    if (url.endsWith("/v1/comma/guest-imports")) {
      if (!this.guestClaimCookie) {
        return jsonResponse({ error: "guest_claim_invalid" }, 404);
      }
      this.guestClaimCookie = false;
      return jsonResponse({ import_id: "import-1", status: "pending" }, 202);
    }

    if (url.endsWith("/v1/comma/auth/logout")) {
      this.session = undefined;
      return jsonResponse({ signed_out: true });
    }

    if (url.endsWith("/v1/comma/workspaces")) {
      this.productCalls.push({
        authorization: headers.get("authorization"),
        credentials: init?.credentials,
        expectedSessionId,
      });
      if (this.productStatus === 401) {
        this.session = undefined;
        return jsonResponse({ error: "unauthorized" }, 401);
      }
      return jsonResponse({ data: [] });
    }

    return jsonResponse({ error: "not_found" }, 404);
  };
}

const guestPowDifficulty = 10;

function solvesGuestChallenge(body: unknown) {
  const pow = (body as { pow?: { challenge?: unknown; nonce?: unknown } } | undefined)
    ?.pow;
  if (typeof pow?.challenge !== "string" || typeof pow.nonce !== "string") {
    return false;
  }
  if (!/^[0-9]{1,20}$/.test(pow.nonce)) return false;
  const digest = createHash("sha256")
    .update(`${pow.challenge}:${pow.nonce}`, "utf8")
    .digest();
  // 10 leading zero bits: one zero byte and the top two bits of the next.
  return digest[0] === 0 && ((digest[1] ?? 0xff) & 0xc0) === 0;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
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

async function eventually(predicate: () => boolean) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("Condition did not become true.");
}

function collectStrings(value: unknown): string[] {
  if (typeof value === "string") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.flatMap(collectStrings);
  }
  if (typeof value === "object" && value !== null) {
    return Object.values(value).flatMap(collectStrings);
  }
  return [];
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
