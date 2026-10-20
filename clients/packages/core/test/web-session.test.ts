// The web session lifecycle in the core (session/web-lifecycle.ts): the page adapter's behavior, on a TestClock,
// against a fake API answering the auth endpoints, with Web Locks and the hint channel in memory.
import { createHash } from "node:crypto";
import {
  sessionExpectation,
  sessionOperationErrorSchemaFor,
  type SessionLifecycleSnapshot,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { Result } from "effect";
import { describe, expect, it } from "vitest";
import type { SessionValue } from "../src/contract.ts";
import type { SessionLease } from "../src/host.ts";
import { apiRequestInit, authRequestInit } from "../src/hosts/web.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  webSessionChannelName,
  webSessionLockName,
  webSessionRecordSchema,
  webSessionStorageKey,
  guestImportMarkerKey,
} from "../src/session/web-record.ts";
import {
  FakeCommaApi,
  FakeHints,
  FakeHost,
  FakeLocks,
  flush,
  inProcessOpener,
  json,
  offline,
  PRODUCT_PATH as PRODUCT,
  productCall,
  type SeenRequest,
  startTestCore,
  TestTime,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const ORIGIN = "https://api.comma.test";
const LOCK = webSessionLockName(ORIGIN);
const CHANNEL = webSessionChannelName(ORIGIN);
const MARKER = guestImportMarkerKey(ORIGIN);

type Projection = {
  expires_at: number;
  session_id: string;
  user: { email: string; id: string; name: string; status: string; kind?: string };
} & Record<string, unknown>;

const sessionA: Projection = {
  expires_at: 2_000_000_000,
  session_id: "11111111-1111-4111-8111-111111111111",
  user: { email: "a@example.com", id: "user-a", name: "A", status: "active" },
};
const sessionB: Projection = {
  expires_at: 2_000_000_100,
  session_id: "22222222-2222-4222-8222-222222222222",
  user: { email: "b@example.com", id: "user-b", name: "B", status: "active" },
};
const guestSession: Projection = {
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

const POW_DIFFICULTY = 10;

/** 10 leading zero bits: one zero byte and the top two bits of the next. */
function solvesGuestChallenge(body: unknown): boolean {
  const pow = (body as { pow?: { challenge?: unknown; nonce?: unknown } } | undefined)
    ?.pow;
  if (typeof pow?.challenge !== "string" || typeof pow.nonce !== "string") return false;
  if (!/^[0-9]{1,20}$/.test(pow.nonce)) return false;
  const digest = createHash("sha256")
    .update(`${pow.challenge}:${pow.nonce}`, "utf8")
    .digest();
  return digest[0] === 0 && ((digest[1] ?? 0xff) & 0xc0) === 0;
}

const header = (request: SeenRequest, name: string) =>
  request.headers?.find(([k]) => k.toLowerCase() === name)?.[1];

/** The server behind the Cookie: which session it holds, and what each auth endpoint answers. */
class CookieServer {
  session: Projection | undefined;
  readonly probeStatuses: number[] = [];
  defaultProbeStatus: number | undefined;
  verifySession: Projection = sessionA;
  googleStatus = 200;
  guestChallenges = 0;
  guestPowRejections = 0;
  guestClaim = false;
  productStatus: 200 | 401 | 409 = 200;

  constructor(
    readonly api: FakeCommaApi,
    initial: Projection | undefined
  ) {
    this.session = initial;
    api.on("GET", "/v1/comma/auth/session", (request: SeenRequest) => {
      const status = this.probeStatuses.shift() ?? this.defaultProbeStatus;
      if (status) return json(status, { error: "session_probe_unavailable" });
      if (!this.session) return json(401, { error: "unauthorized" });
      if (
        request.expected === "unknown" ||
        request.expected === this.session.session_id
      )
        return json(200, this.session);
      return json(409, { error: "session_changed" });
    });
    api.on("POST", "/v1/comma/auth/email/login", {
      challenge_id: "challenge-1",
      code: "123456",
    });
    api.on("POST", "/v1/comma/auth/email/verify", () => {
      this.session = this.verifySession;
      return json(200, this.verifySession);
    });
    api.on("POST", "/v1/comma/auth/google/attempt", {
      attempt_id: "google-attempt-1",
      client_id: "google-client-id",
      nonce: "google-nonce",
      platform: "web",
    });
    api.on("POST", "/v1/comma/auth/google", () => {
      if (this.googleStatus === 401)
        return json(401, { error: "invalid_google_credential" });
      this.session = this.verifySession;
      return json(200, this.verifySession);
    });
    api.on("GET", "/v1/comma/auth/guest", (request: SeenRequest) => {
      // The server refuses a web request without the signed-out Cookie transport headers before the route.
      if (
        header(request, "x-comma-session-transport") !== "cookie" ||
        header(request, "x-comma-session-lifecycle-version") !== "1" ||
        request.expected !== "none"
      )
        return json(400, { error: "invalid_session_transport" });
      this.guestChallenges += 1;
      return json(200, {
        enabled: true,
        pow: {
          challenge: `gpow1.c${this.guestChallenges}.mac`,
          difficulty: POW_DIFFICULTY,
          expires_at: 2_000_000_000,
        },
      });
    });
    api.on("POST", "/v1/comma/auth/guest", (request: SeenRequest) => {
      if (!solvesGuestChallenge(request.body) || this.guestPowRejections > 0) {
        this.guestPowRejections = Math.max(0, this.guestPowRejections - 1);
        return json(400, { error: "guest_pow_invalid" });
      }
      this.session = guestSession;
      return json(200, guestSession);
    });
    api.on("POST", "/v1/comma/auth/guest/handoff", () => {
      this.session = undefined;
      this.guestClaim = true;
      return json(200, { expires_at: 2_000_000_000 });
    });
    api.on("POST", "/v1/comma/guest-imports", () => {
      if (!this.guestClaim) return json(404, { error: "guest_claim_invalid" });
      this.guestClaim = false;
      return json(202, { import_id: "import-1", status: "pending" });
    });
    api.on("POST", "/v1/comma/auth/logout", () => {
      this.session = undefined;
      return json(200, { signed_out: true });
    });
    api.on("POST", PRODUCT, () => {
      if (this.productStatus === 401) {
        this.session = undefined;
        return json(401, { error: "unauthorized" });
      }
      if (this.productStatus === 409) return json(409, { error: "session_changed" });
      return json(200, { cleared: true });
    });
  }
}

type Shared = {
  randomFrom?: number;
  api?: FakeCommaApi;
  storage?: Map<string, Uint8Array>;
  locks?: FakeLocks;
  hints?: FakeHints;
  time?: TestTime;
};

/** A core running the web session lifecycle (`sessionSource: "core"`), and a UI (a tab) connected to it. */
function setup(
  initial: Projection | undefined,
  options: Shared & {
    before?: (t: { api: FakeCommaApi; server: CookieServer }) => void;
  } = {}
) {
  const api = options.api ?? new FakeCommaApi();
  const server = new CookieServer(api, initial);
  options.before?.({ api, server });
  return start(server, options);
}

function start(server: CookieServer, shared: Shared) {
  const host = new FakeHost({
    sessionSource: "core",
    api: server.api,
    ...(shared.time ? { time: shared.time } : {}),
    ...(shared.storage ? { storage: shared.storage } : {}),
    ...(shared.locks ? { locks: shared.locks } : {}),
    ...(shared.hints ? { hints: shared.hints } : {}),
    ...(shared.randomFrom ? { randomFrom: shared.randomFrom } : {}),
  });
  const core = startTestCore(host, { coalesceMs: 0 });
  const time = host.time!;
  const lifecycle = core.webSession!;
  /** Every phase the lifecycle published, in order. */
  const phases: string[] = [];
  core.session.onChange(() => {
    const phase = lifecycle.snapshot().phase;
    if (phases.at(-1) !== phase) phases.push(phase);
  });
  const tab = () => {
    const client = new CoreClient(inProcessOpener(core, host), {
      schedule: () => undefined,
    });
    const values = new Map<string, unknown>();
    const watch = <T>(topic: Topic) => {
      const key = topicKey(topic);
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      );
      return () => values.get(key) as T;
    };
    return { client, watch };
  };
  const first = tab();
  const shown = first.watch<SessionValue>({ topic: "session" });
  return {
    core,
    host,
    api: server.api,
    server,
    time,
    lifecycle,
    phases,
    client: first.client,
    shown,
    tab,
    snapshot: () => lifecycle.snapshot(),
    /** A call from the tab, answered once `ms` of the core's time passed. */
    async ask<T>(name: string, params: unknown = {}, ms = 50): Promise<T> {
      const answer = first.client.call(name, params);
      await time.pass(ms);
      return (await answer) as T;
    },
    expected() {
      return sessionExpectation(lifecycle.snapshot() as TerminalSessionSnapshot);
    },
    record() {
      const raw = host.storage.get(webSessionStorageKey(ORIGIN));
      if (!raw) throw new Error("no session record");
      return webSessionRecordSchema.parse(JSON.parse(new TextDecoder().decode(raw)));
    },
    rawRecord() {
      const raw = host.storage.get(webSessionStorageKey(ORIGIN));
      if (!raw) throw new Error("no session record");
      return new TextDecoder().decode(raw);
    },
    /** The auth requests made (the Cookie's), in order. */
    auth: () => server.api.requests.filter((r) => r.expected !== undefined),
    /** A product request (the tab clears a workspace's browser storage); its outcome after `ms`. */
    async product(ms = 20) {
      const { done } = await this.startProduct();
      await time.pass(ms);
      return done;
    },
    /** A product request the tab started now (it reached the core); its outcome when it has one (`done`). */
    async startProduct() {
      const done = productCall(first.client);
      await flush();
      return { done };
    },
  };
}

type Setup = ReturnType<typeof setup>;

const productCalls = (t: Setup) => t.api.seen("POST", PRODUCT);

/** The tab's own product request for `lease` was refused (`session.rejected`). */
const refusedByTab = (t: Setup, lease: SessionLease, status: 401 | 409) =>
  t.client.call("session.rejected", {
    sessionId: lease.sessionId,
    generation: lease.generation,
    status,
  });

/** The code a failed product request failed with. */
const failureCode = (outcome: Result.Result<unknown, unknown>) =>
  Result.isFailure(outcome) ? (outcome.failure as { code?: string }).code : "succeeded";

/** How many of the core's timers of `ms` fired (its log's ticks). */
const fired = (t: Setup, ms: number) =>
  t.core.recorder!.inputs.filter((i) => i.kind === "tick" && i.ms === ms).length;

/** A hint as a page on the adapter posts it after it rebound its record to `authority`. */
const adapterHint = (authority: string, generation = 1) => ({
  canonicalApiOrigin: ORIGIN,
  cookieAuthorityId: authority,
  cookieGeneration: generation,
  coordinationRevision: 3,
  kind: "session_maybe_changed",
  schemaVersion: 1,
  senderId: "adapter-tab",
});

/** Another context on the same origin (a page whose own core, on its own record, shares the Cookie and the hints). */
function peerOf(t: Setup) {
  return start(t.server, {
    locks: t.host.locks,
    hints: t.host.hints,
    time: t.time,
    randomFrom: 2_000,
  });
}

async function signedInAs(t: Setup, sessionId: string) {
  await t.time.pass(20);
  expect(t.snapshot()).toMatchObject({ phase: "signed_in", session: { sessionId } });
}

describe("the web session lifecycle", () => {
  it("renews the session from a Telegram launch, for every tab, keeping none of the launch", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const other = t.tab();
    const otherShown = other.watch<SessionValue>({ topic: "session" });
    const oldLease = t.core.session.lease();
    const renewed = { ...sessionA, session_id: "renewed-panel-session" };
    t.api.on("POST", "/v1/comma/auth/telegram-miniapp", () => {
      t.server.session = renewed;
      return json(200, renewed);
    });
    expect(
      await t.ask("session.telegram", { initData: "signed-launch", groupId: "group-1" })
    ).toBe("signed_in");
    expect(t.core.session.lease()).toMatchObject({ sessionId: renewed.session_id });
    expect(t.core.session.lease()).not.toBe(oldLease);
    expect(otherShown()).toMatchObject({
      phase: "signed_in",
      sessionId: renewed.session_id,
    });
    expect(t.shown()).toMatchObject({
      phase: "signed_in",
      sessionId: renewed.session_id,
    });
    expect(t.rawRecord()).not.toContain("signed-launch");
    expect(t.host.hints.posted.at(-1)).toMatchObject({
      kind: "session_maybe_changed",
      cookieAuthorityId: t.record().cookieAuthorityId,
    });
  });

  it("recovers a lost Telegram exchange answer without sending the launch again", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const renewed = { ...sessionA, session_id: "renewed-panel-session" };
    t.api.on("POST", "/v1/comma/auth/telegram-miniapp", () => {
      t.server.session = renewed;
      return offline("answer lost after the Cookie changed");
    });
    expect(
      await t.ask("session.telegram", { initData: "signed-launch", groupId: "group-1" })
    ).toBe("failed");
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_mutation_uncertain" },
    });
    expect(t.core.session.lease()).toBeNull();
    await t.ask("session.recover");
    expect(t.core.session.lease()).toMatchObject({ sessionId: renewed.session_id });
    expect(t.api.seen("POST", "/v1/comma/auth/telegram-miniapp")).toHaveLength(1);
    expect(t.auth().at(-1)).toMatchObject({
      path: "/v1/comma/auth/session",
      expected: "unknown",
    });
  });

  it("probes with the session it expects, under the Cookie transport, keeping no one's details", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    await t.ask("session.reconcile", { reason: "focus" });
    expect(t.auth().map((r) => [r.method, r.path, r.headers])).toEqual([
      [
        "GET",
        "/v1/comma/auth/session",
        [
          ["accept", "application/json"],
          ["x-comma-expected-auth-session-id", "unknown"],
          ["x-comma-session-lifecycle-version", "1"],
          ["x-comma-session-transport", "cookie"],
        ],
      ],
      [
        "GET",
        "/v1/comma/auth/session",
        [
          ["accept", "application/json"],
          ["x-comma-expected-auth-session-id", sessionA.session_id],
          ["x-comma-session-lifecycle-version", "1"],
          ["x-comma-session-transport", "cookie"],
        ],
      ],
    ]);
    const raw = t.rawRecord();
    expect(raw).not.toContain("a@example.com");
    expect(raw).not.toContain("user-a");
    expect(raw).not.toContain(t.lifecycle.authorityInstanceId);
    expect(t.record()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    // The worker sends it with the Cookie, the same headers, and no bearer.
    const init = authRequestInit(
      {
        method: "POST",
        path: "/v1/comma/auth/logout",
        headers: [["content-type", "application/json"]],
        body: new Uint8Array([123, 125]),
        expectedSessionId: "session-x",
      },
      new AbortController().signal
    );
    expect(init.credentials).toBe("include");
    expect(init.keepalive).toBe(false);
    expect(Object.fromEntries(new Headers(init.headers))).toEqual({
      "content-type": "application/json",
      "x-comma-expected-auth-session-id": "session-x",
      "x-comma-session-lifecycle-version": "1",
      "x-comma-session-transport": "cookie",
    });
  });
  it("keeps the same lease through a focus probe that finds the same session", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const before = t.snapshot();
    const lease = t.core.session.lease();
    expect(await t.ask("session.reconcile", { reason: "focus" })).toMatchObject({
      ok: true,
    });
    expect(t.snapshot()).toMatchObject({
      generation: before.generation,
      phase: "signed_in",
    });
    expect(t.snapshot().revision).toBeGreaterThan(before.revision);
    expect(t.core.session.lease()).toBe(lease);
  });

  it("closes the lease when signing out begins, before the lock a focus probe holds, and fails closed", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const expected = t.expected();
    const releaseBody = t.api.holdBody("GET", "/v1/comma/auth/session");
    const probe = t.client.call("session.reconcile", { reason: "focus", expected });
    await t.time.pass(10);
    expect(t.host.locks.active).toBe(1);
    let signedOutAnswer: unknown = "pending";
    const signOut = t.client.call("session.signOut", { expected });
    void signOut.then((answer) => (signedOutAnswer = answer));
    await t.time.pass(10);
    expect(t.snapshot().phase).toBe("signing_out");
    expect(t.core.session.lease()).toBeNull();
    expect(failureCode(await t.product())).toBe("signed_out");
    expect(productCalls(t)).toEqual([]);

    await t.time.pass(1_940);
    expect(signedOutAnswer).toBe("pending");
    expect(fired(t, 2_000)).toBe(0);
    await t.time.pass(40);
    expect(await signOut).toMatchObject({
      ok: false,
      error: { code: "network_unavailable", operation: "sign_out" },
    });
    expect(fired(t, 2_000)).toBe(1);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/logout")).toEqual([]);

    await t.time.pass(6_000);
    expect(await probe).toMatchObject({
      ok: false,
      error: { code: "network_unavailable", operation: "reconcile" },
    });
    expect(fired(t, 2_000)).toBe(1);
    expect(fired(t, 8_000)).toBe(1);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    expect(t.record()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    releaseBody();
  });
  it("keeps a signed-in session and its lease through a 503, and probes again after 1 s", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const peer = peerOf(t);
    await signedInAs(peer, sessionA.session_id);
    const peerLease = peer.core.session.lease();
    const peerPhases = peer.phases.length;
    const lease = t.core.session.lease();
    const before = t.snapshot();
    const phasesBefore = t.phases.length;
    t.server.probeStatuses.push(503);
    expect(
      await t.ask("session.reconcile", {
        reason: "peer_mutation",
        expected: t.expected(),
      })
    ).toMatchObject({ ok: false, error: { code: "session_probe_unavailable" } });
    expect(t.snapshot().phase).toBe("signed_in");
    expect(t.core.session.lease()).toBe(lease);
    // The other context heard nothing to act on: its view and lease stand.
    expect(peer.phases.slice(peerPhases)).toEqual([]);
    expect(peer.core.session.lease()).toBe(peerLease);

    const probes = t.auth().length;
    await t.time.pass(900);
    expect(t.auth()).toHaveLength(probes);
    await t.time.pass(100);
    expect(t.auth()).toHaveLength(probes + 1);
    expect(t.snapshot().revision).toBeGreaterThan(before.revision);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(t.core.session.lease()).toBe(lease);
    expect(t.phases.slice(phasesBefore)).toEqual([]);
    expect(peer.core.session.lease()).toBe(peerLease);
    expect(t.record()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
  });
  it("keeps view and lease while confirming a session another writer rebound", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const lease = t.core.session.lease();
    const before = t.snapshot();
    const phasesBefore = t.phases.length;
    const releaseProduct = t.api.hold("POST", PRODUCT);
    const { done: held } = await t.startProduct();
    // Another writer found nothing it could trust, rebound to the same session under a new Cookie authority, and says so.
    const record = t.record();
    const rebound = {
      ...record,
      cookieAuthorityId: "rebound-authority",
      cookieGeneration: 1,
      coordinationRevision: 2,
      writeNonce: "rebound-nonce",
    };
    t.host.storage.set(
      webSessionStorageKey(ORIGIN),
      new TextEncoder().encode(JSON.stringify(rebound))
    );
    t.host.hints.send(CHANNEL, adapterHint("rebound-authority"));
    await t.time.pass(20);
    expect(t.auth().at(-1)).toMatchObject({ expected: sessionA.session_id });
    expect(t.record()).toMatchObject({
      cookieAuthorityId: "rebound-authority",
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    expect(t.phases.slice(phasesBefore)).toEqual([]);
    expect(t.core.session.lease()).toBe(lease);
    // The request under way with the lease went on through it.
    releaseProduct();
    await t.time.pass(10);
    expect(failureCode(await held)).toBe("succeeded");
    expect(t.snapshot()).toMatchObject({
      generation: before.generation,
      phase: "signed_in",
    });
    expect(t.snapshot().revision).toBeGreaterThan(before.revision);
  });
  it("commits the Cookie's absence on a strict 401, for every tab, and other contexts sign out on its hint", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const peer = peerOf(t);
    await signedInAs(peer, sessionA.session_id);
    const other = t.tab().watch<SessionValue>({ topic: "session" });
    await t.time.pass(10);
    const generation = t.record().cookieGeneration;
    t.server.session = undefined;
    await t.ask("session.reconcile", { reason: "focus" });
    expect(t.snapshot()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
    expect(other()).toMatchObject({
      phase: "signed_out",
      lifecycle: { phase: "signed_out", reason: "unauthorized" },
    });
    expect(t.record()).toMatchObject({
      cookieGeneration: generation + 1,
      kind: "stable",
      state: { kind: "absent" },
    });
    expect(t.host.deleted).toHaveLength(1);
    // The other context heard the hint, asked the server, and signed out: its lease and requests ended.
    expect(peer.snapshot()).toMatchObject({
      phase: "signed_out",
      reason: "unauthorized",
    });
    expect(peer.core.session.lease()).toBeNull();
    expect(peer.host.deleted).toHaveLength(1);
  });
  it("settles a product 401 of the current lease under the lock", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const requests = t.host.locks.requests.length;
    t.server.productStatus = 401;
    expect(Result.isFailure(await t.product())).toBe(true);
    expect(t.snapshot().phase).toBe("signed_out");
    expect(t.host.locks.requests.length).toBeGreaterThan(requests);
    expect(t.auth().at(-1)).toMatchObject({
      path: "/v1/comma/auth/session",
      expected: sessionA.session_id,
    });
    expect(t.record()).toMatchObject({ kind: "stable", state: { kind: "absent" } });
  });

  it("gives up a probe whose body hangs 8 s, and lets the lock go", async () => {
    const t = setup(sessionA, {
      before: ({ api }) => void api.holdBody("GET", "/v1/comma/auth/session"),
    });
    await t.time.pass(10);
    // The server answered (200, the session): only the body has not all come.
    expect(t.auth()).toHaveLength(1);
    expect(t.host.locks.active).toBe(1);
    await t.time.pass(7_980);
    expect(t.snapshot().phase).toBe("initializing");
    await t.time.pass(20);
    expect(fired(t, 8_000)).toBe(1);
    expect(t.host.locks.active).toBe(0);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "reconcile" },
    });
  });
  it("closes the lease on a product 401 before waiting for the lock another context holds", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const release = t.host.locks.hold(LOCK);
    t.server.productStatus = 401;
    const refused = await t.product();
    expect(Result.isFailure(refused) && refused.failure).toMatchObject({ status: 401 });
    expect(t.core.session.lease()).toBeNull();
    expect(t.host.locks.active).toBe(1);
    expect(productCalls(t)).toHaveLength(1);
    const sent = productCalls(t)[0]!;
    expect(sent.lease.sessionId).toBe(sessionA.session_id);
    expect(sent.headers?.some(([k]) => k.toLowerCase() === "authorization")).toBe(
      false
    );
    // As the worker sends it: the Cookie, the session it expects, no bearer.
    const init = apiRequestInit(
      {
        method: sent.method,
        path: sent.path,
        headers: sent.headers ?? [],
        body: null,
        lease: sent.lease,
      },
      new AbortController().signal
    );
    expect(init.credentials).toBe("include");
    const headers = new Headers(init.headers);
    expect(headers.get("authorization")).toBeNull();
    expect(headers.get("x-comma-expected-auth-session-id")).toBe(sessionA.session_id);
    // Nothing more goes out with it.
    expect(failureCode(await t.product())).toBe("signed_out");
    expect(productCalls(t)).toHaveLength(1);
    release();
    await t.time.pass(20);
    expect(t.snapshot().phase).toBe("signed_out");
  });
  it("ignores account A's late 401 once account B signed in", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const leaseA = t.core.session.lease() as SessionLease;
    expect(await t.ask("session.signOut", { expected: t.expected() })).toMatchObject({
      ok: true,
    });
    t.server.verifySession = sessionB;
    const challenge = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string };
    }>("session.email.request", { email: sessionB.user.email, expected: t.expected() });
    expect(
      await t.ask("session.email.verify", {
        attempt: challenge.value.attempt,
        challengeId: challenge.value.challengeId,
        code: "123456",
      })
    ).toMatchObject({
      ok: true,
      value: { session: { sessionId: sessionB.session_id } },
    });
    const leaseB = t.core.session.lease();
    const requests = t.api.requests.length;
    void refusedByTab(t, leaseA, 401);
    await t.time.pass(20);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionB.session_id },
    });
    expect(t.core.session.lease()).toBe(leaseB);
    expect(t.api.requests).toHaveLength(requests);
  });

  it("fails a sign-in closed where there are no Web Locks", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    expect(t.snapshot().phase).toBe("signed_out");
    const requests = t.api.requests.length;
    t.host.locks.unsupported = true;
    expect(
      await t.ask("session.email.request", {
        email: "person@example.com",
        expected: t.expected(),
      })
    ).toMatchObject({ ok: false, error: { code: "unsupported" } });
    expect(t.api.requests).toHaveLength(requests);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
  });

  it("keeps only the attempt and its epoch in the record, and signs in with the code", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    const challenge = await t.ask<{
      ok: true;
      value: { attempt: { attemptId: string }; challengeId: string };
    }>("session.email.request", {
      email: "person@example.com",
      expected: t.expected(),
    });
    expect(challenge).toMatchObject({
      ok: true,
      value: { challengeId: "challenge-1", code: "123456" },
    });
    const authenticating = t.record();
    expect(authenticating).toMatchObject({
      activeAuthAttemptId: challenge.value.attempt.attemptId,
      kind: "authenticating",
      operationEpoch: expect.any(Number),
      state: { kind: "absent" },
    });
    const raw = t.rawRecord();
    for (const secret of ["challenge-1", "123456", "person@example.com"])
      expect(raw).not.toContain(secret);
    // Every tab sees the sign-in under way, and can continue it.
    expect(t.shown()).toMatchObject({
      lifecycle: { phase: "authenticating" },
      attempt: {
        method: "email",
        ref: challenge.value.attempt,
        challenge: {
          challengeId: "challenge-1",
          purpose: "email_login",
          email: "person@example.com",
        },
      },
    });
    expect(
      await t.ask("session.email.verify", {
        attempt: challenge.value.attempt,
        challengeId: challenge.value.challengeId,
        code: "123456",
      })
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: sessionA.session_id } },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/email/verify")[0]!.body).toEqual({
      challenge_id: "challenge-1",
      client_kind: "web",
      client_platform: "macos",
      code: "123456",
    });
    expect(
      t
        .auth()
        .slice(-2)
        .map((r) => r.expected)
    ).toEqual(["none", "none"]);
    expect(t.record()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionA.session_id },
    });
    expect(t.shown()).toMatchObject({
      phase: "signed_in",
      userId: "user-a",
      attempt: null,
    });
  });

  it("answers a typed unknown failure when cancelling waits past the lock's 2 s", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    const challenge = await t.ask<{ ok: true; value: { attempt: unknown } }>(
      "session.email.request",
      { email: "person@example.com", expected: t.expected() }
    );
    t.host.locks.hold(LOCK);
    const cancel = t.client.call("session.cancelAuth", {
      attempt: challenge.value.attempt,
    });
    await t.time.pass(1_990);
    await t.time.pass(20);
    const result = (await cancel) as { ok: false; error: unknown };
    expect(result).toMatchObject({
      ok: false,
      error: { code: "unknown", operation: "cancel_auth_attempt" },
    });
    expect(
      sessionOperationErrorSchemaFor("cancel_auth_attempt").safeParse(result.error)
        .success
    ).toBe(true);
  });

  it("maps a refused Google credential to a legal sign-in error", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    const prepared = await t.ask<{
      ok: true;
      value: {
        attempt: unknown;
        nonce: string;
        providerAttemptId: string;
        clientId: string;
      };
    }>("session.google.attempt", { expected: t.expected() });
    expect(prepared.value).toMatchObject({
      clientId: "google-client-id",
      nonce: "google-nonce",
    });
    t.server.googleStatus = 401;
    const result = await t.ask<{ ok: false; error: unknown }>(
      "session.google.complete",
      {
        attempt: prepared.value.attempt,
        credential: "rejected-google-credential",
        nonce: prepared.value.nonce,
        providerAttemptId: prepared.value.providerAttemptId,
      }
    );
    expect(result).toMatchObject({
      ok: false,
      error: { code: "unknown", retryable: false },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/google")[0]!.body).toEqual({
      attempt_id: "google-attempt-1",
      client_kind: "web",
      client_platform: "macos",
      credential: "rejected-google-credential",
      nonce: "google-nonce",
    });
    expect(
      sessionOperationErrorSchemaFor("sign_in_with_google").safeParse(result.error)
        .success
    ).toBe(true);
  });

  it("links a Google account that needs the emailed code, on the same attempt, and signs in", async () => {
    const t = setup(undefined);
    t.api.on("POST", "/v1/comma/auth/google", {
      status: "otp_required",
      challenge_id: "link-challenge",
      code: "654321",
      email: "a@example.com",
    });
    t.api.on("POST", "/v1/comma/auth/google/link/verify", () => {
      t.server.session = sessionA;
      return json(200, sessionA);
    });
    await t.time.pass(20);
    const prepared = await t.ask<{
      ok: true;
      value: { attempt: unknown; nonce: string; providerAttemptId: string };
    }>("session.google.attempt", { expected: t.expected() });
    expect(
      await t.ask("session.google.complete", {
        attempt: prepared.value.attempt,
        credential: "google-credential",
        nonce: prepared.value.nonce,
        providerAttemptId: prepared.value.providerAttemptId,
      })
    ).toMatchObject({
      ok: true,
      value: {
        attempt: prepared.value.attempt,
        challengeId: "link-challenge",
        code: "654321",
        email: "a@example.com",
        status: "otp_required",
      },
    });
    // Every tab sees the link waiting on its code.
    expect(t.shown()).toMatchObject({
      lifecycle: { phase: "authenticating" },
      attempt: {
        ref: prepared.value.attempt,
        challenge: {
          challengeId: "link-challenge",
          purpose: "google_link",
          email: "a@example.com",
        },
      },
    });
    expect(
      await t.ask("session.google.linkVerify", {
        attempt: prepared.value.attempt,
        challengeId: "link-challenge",
        code: "654321",
      })
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in", session: { sessionId: sessionA.session_id } },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/google/link/verify")[0]!.body).toEqual({
      challenge_id: "link-challenge",
      client_kind: "web",
      client_platform: "macos",
      code: "654321",
    });
  });

  it("signs out with the server, showing the sign-out under way until it answers", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const release = t.api.hold("POST", "/v1/comma/auth/logout");
    const signOut = t.client.call("session.signOut", { expected: t.expected() });
    await t.time.pass(10);
    expect(t.shown()).toMatchObject({ lifecycle: { phase: "signing_out" } });
    release();
    await t.time.pass(10);
    expect(await signOut).toMatchObject({
      ok: true,
      value: { phase: "signed_out", reason: "user_signed_out" },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/logout")).toMatchObject([
      { expected: sessionA.session_id },
    ]);
  });

  it("fails a sign-out the server could not answer (503) closed, and finds the session again on the person's retry", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    t.api.on("POST", "/v1/comma/auth/logout", json(503, { error: "unavailable" }));
    expect(await t.ask("session.signOut", { expected: t.expected() })).toMatchObject({
      ok: false,
      error: { operation: "sign_out" },
    });
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    const probes = t.api.seen("GET", "/v1/comma/auth/session").length;
    await t.ask("session.recover");
    expect(t.api.seen("GET", "/v1/comma/auth/session")).toHaveLength(probes + 1);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
  });

  it("makes no request when the record cannot be kept", async () => {
    // A core whose device storage refuses writes from the start.
    const failing = new FakeHost({ sessionSource: "core", api: new FakeCommaApi() });
    failing.storageFails.writes = true;
    const core = startTestCore(failing, { coalesceMs: 0 });
    await failing.time!.pass(20);
    expect(failing.api.requests).toHaveLength(0);
    expect(core.webSession!.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_store_unavailable", operation: "initialize" },
    });
  });

  it("closes the lease when a hint comes and the record cannot be read", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    t.host.storageFails.reads = true;
    t.host.hints.send(CHANNEL, {
      canonicalApiOrigin: ORIGIN,
      cookieAuthorityId: "external-cookie-authority",
      cookieGeneration: 9,
      coordinationRevision: 9,
      kind: "session_maybe_changed",
      schemaVersion: 1,
      senderId: "external-sender",
    });
    await t.time.pass(10);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "credential_store_unavailable" },
    });
    expect(t.core.session.lease()).toBeNull();
  });

  it("renews a used-up recovery ticket when the person retries", async () => {
    const t = setup(undefined, {
      before: ({ server }) => void (server.defaultProbeStatus = 503),
    });
    await t.time.pass(20);
    expect(t.auth()).toHaveLength(1);
    expect(t.record()).toMatchObject({
      kind: "recovering",
      ticket: { attemptsStarted: 1, progress: { phase: "backoff" } },
    });
    await t.time.pass(500);
    await t.ask("session.recover");
    expect(t.auth()).toHaveLength(2);
    expect(t.record()).toMatchObject({
      kind: "recovering",
      ticket: { attemptsStarted: 2, maxAttempts: 2, progress: { phase: "exhausted" } },
    });
    t.server.defaultProbeStatus = undefined;
    await t.time.pass(500);
    await t.ask("session.recover");
    expect(t.auth()).toHaveLength(3);
    expect(t.record()).toMatchObject({ kind: "stable", state: { kind: "absent" } });
    expect(t.snapshot()).toMatchObject({ phase: "signed_out", reason: "no_session" });
  });

  it("lets the person's retry skip the recovery backoff", async () => {
    const t = setup(undefined, {
      before: ({ server }) => void (server.defaultProbeStatus = 503),
    });
    await t.time.pass(20);
    expect(t.auth()).toHaveLength(1);
    t.server.defaultProbeStatus = undefined;
    await t.ask("session.recover");
    expect(t.auth()).toHaveLength(2);
    expect(t.snapshot()).toMatchObject({ phase: "signed_out", reason: "no_session" });
  });

  it("accepts a session answer with fields a newer server added", async () => {
    const t = setup({
      ...sessionA,
      user: { ...sessionA.user, avatar_id: "avt_new" } as Projection["user"],
      workspace_hint: "wsp_new",
    });
    await signedInAs(t, sessionA.session_id);
  });

  it("refuses a session answer that hands a bearer to the Cookie transport", async () => {
    const t = setup({ ...sessionA, token: "reflected" });
    await t.time.pass(20);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "protocol_mismatch" },
    });
    expect(t.core.session.lease()).toBeNull();
  });

  it("refuses a late Google credential once a guest sign-in replaced its attempt", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    const prepared = await t.ask<{
      ok: true;
      value: { attempt: unknown; nonce: string; providerAttemptId: string };
    }>("session.google.attempt", { expected: t.expected() });
    const authenticating = t.snapshot();
    expect(
      await t.ask("session.guest.start", {
        expected: {
          authorityInstanceId: authenticating.authority.authorityInstanceId,
          expectedSessionId: null,
          generation: authenticating.generation,
        },
      })
    ).toMatchObject({ ok: true, value: { principal: { kind: "guest" } } });
    const requests = t.api.requests.length;
    expect(
      await t.ask("session.google.complete", {
        attempt: prepared.value.attempt,
        credential: "late-google-credential",
        nonce: prepared.value.nonce,
        providerAttemptId: prepared.value.providerAttemptId,
      })
    ).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(t.api.requests).toHaveLength(requests);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      principal: { kind: "guest" },
      session: { sessionId: guestSession.session_id },
    });
  });

  it("hands a guest session off and imports its chat after the next sign-in", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    expect(await t.ask("session.guest.availability")).toBe(true);
    expect(t.api.seen("GET", "/v1/comma/auth/guest")[0]).toMatchObject({
      expected: "none",
    });
    expect(
      await t.ask("session.guest.start", { expected: t.expected() })
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in", principal: { kind: "guest" } },
    });
    const guestStart = t.api.seen("POST", "/v1/comma/auth/guest")[0]!;
    expect(guestStart.body).toMatchObject({
      client_kind: "web",
      pow: { challenge: "gpow1.c2.mac" },
    });
    expect(solvesGuestChallenge(guestStart.body)).toBe(true);

    expect(
      await t.ask("session.guest.signUp", { expected: t.expected() })
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_out", reason: "guest_handoff" },
    });
    expect(new TextDecoder().decode(t.host.storage.get(MARKER))).toBe(
      JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
    );
    expect(t.api.seen("POST", "/v1/comma/auth/logout")).toEqual([]);

    const requested = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string };
    }>("session.email.request", { email: "a@example.com", expected: t.expected() });
    await t.ask("session.email.verify", {
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code: "123456",
    });
    expect(t.shown()).toMatchObject({ phase: "signed_in", guestImports: 1 });
    expect(t.api.seen("POST", "/v1/comma/guest-imports")[0]).toMatchObject({
      body: {},
      expected: sessionA.session_id,
    });
    expect(t.server.guestClaim).toBe(false);
    expect(t.host.storage.has(MARKER)).toBe(false);
  });

  it("retries a refused guest proof of work once, with a fresh challenge", async () => {
    const t = setup(undefined, {
      before: ({ server }) => void (server.guestPowRejections = 1),
    });
    await t.time.pass(20);
    expect(
      await t.ask("session.guest.start", { expected: t.expected() }, 200)
    ).toMatchObject({
      ok: true,
      value: { phase: "signed_in", principal: { kind: "guest" } },
    });
    expect(t.api.seen("POST", "/v1/comma/auth/guest").map((r) => r.body)).toMatchObject(
      [{ pow: { challenge: "gpow1.c1.mac" } }, { pow: { challenge: "gpow1.c2.mac" } }]
    );

    const refused = setup(undefined, {
      before: ({ server }) => void (server.guestPowRejections = 2),
    });
    await refused.time.pass(20);
    expect(
      await refused.ask("session.guest.start", { expected: refused.expected() }, 200)
    ).toMatchObject({ ok: false, error: { code: "unknown" } });
    expect(refused.server.guestChallenges).toBe(2);
    expect(refused.api.seen("POST", "/v1/comma/auth/guest")).toHaveLength(2);
    expect(refused.snapshot()).toMatchObject({
      phase: "signed_out",
      reason: "no_session",
    });
  });

  it("drops a waiting guest import the server no longer knows", async () => {
    const storage = new Map([
      [
        MARKER,
        new TextEncoder().encode(
          JSON.stringify({ expiresAtEpochSeconds: 2_000_000_000 })
        ),
      ],
    ]);
    const t = setup(sessionA, { storage });
    await signedInAs(t, sessionA.session_id);
    await t.time.pass(20);
    expect(t.api.seen("POST", "/v1/comma/guest-imports")).toHaveLength(1);
    expect(t.host.storage.has(MARKER)).toBe(false);
    expect(t.shown()).toMatchObject({ guestImports: 0 });
  });

  it("rebinds to the Cookie's session after a product 409, with no error between", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const phasesBefore = t.phases.length;
    // Another context signed in as B: the shared Cookie names B's session now.
    t.server.session = sessionB;
    t.server.productStatus = 409;
    expect(Result.isFailure(await t.product(40))).toBe(true);
    expect(t.phases.slice(phasesBefore)).not.toContain("indeterminate");
    expect(
      t
        .auth()
        .slice(-2)
        .map((r) => r.expected)
    ).toEqual([sessionA.session_id, "unknown"]);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      principal: { userId: "user-b" },
      session: { sessionId: sessionB.session_id },
    });
    expect(t.shown()).toMatchObject({ phase: "signed_in", userId: "user-b" });
    expect(t.record()).toMatchObject({
      kind: "stable",
      state: { kind: "present", sessionId: sessionB.session_id },
    });
    // Account A's data is gone from the device.
    expect(t.host.deleted).toHaveLength(1);
  });

  it("hears the page's own product refusals for the lease given now, and no other", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const { generation } = t.snapshot();
    // A refusal made for an older generation, or another session, says nothing of this lease.
    await t.ask("session.rejected", {
      sessionId: sessionA.session_id,
      generation: generation - 1,
      status: 401,
    });
    await t.ask("session.rejected", {
      sessionId: sessionB.session_id,
      generation,
      status: 401,
    });
    expect(t.snapshot().phase).toBe("signed_in");
    expect(t.core.session.lease()).not.toBeNull();
    // Another context signed in as B: the page's request for A was refused with 409.
    t.server.session = sessionB;
    await t.ask("session.rejected", {
      sessionId: sessionA.session_id,
      generation,
      status: 409,
    });
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionB.session_id },
    });
    // The Cookie is gone: the page's request for B was refused with 401.
    t.server.session = undefined;
    const now = t.snapshot().generation;
    const answer = t.client.call("session.rejected", {
      sessionId: sessionB.session_id,
      generation: now,
      status: 401,
    });
    // The lease closes at once, before the check of the Cookie.
    expect(await answer).toBeNull();
    expect(t.core.session.lease()).toBeNull();
    await t.time.pass(50);
    expect(t.snapshot()).toMatchObject({ phase: "signed_out", reason: "unauthorized" });
  });

  it("runs one rebind for a burst of product 409s", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const lease = t.core.session.lease()!;
    t.server.session = sessionB;
    t.api.hold("GET", "/v1/comma/auth/session");
    for (let i = 0; i < 5; i++) void refusedByTab(t, lease, 409);
    await flush();
    for (let i = 0; i < 5; i++) t.host.hints.send(CHANNEL, adapterHint(`adapter-${i}`));
    await t.time.pass(20);
    expect(t.auth().filter((r) => r.path === "/v1/comma/auth/session")).toHaveLength(2);
    // The probe is given up after 8 s, the session kept; the background re-probe 1 s later rebinds.
    await t.time.pass(8_000);
    expect(t.snapshot().phase).toBe("signed_in");
    await t.time.pass(1_100);
    expect(t.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionB.session_id },
    });
    expect(
      t
        .auth()
        .map((r) => r.expected)
        .slice(1)
    ).toEqual([sessionA.session_id, sessionA.session_id, "unknown"]);
  });

  it("stops the product requests under way when the lease closes", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    let aborted = false;
    t.api.on(
      "POST",
      PRODUCT,
      (_request: SeenRequest, signal: AbortSignal) =>
        new Promise((resolve) => {
          signal.addEventListener("abort", () => {
            aborted = true;
            resolve(json(200, { cleared: true }));
          });
        })
    );
    const { done: held } = await t.startProduct();
    await t.time.pass(10);
    expect(productCalls(t)).toHaveLength(1);
    void t.client.call("session.signOut", { expected: t.expected() });
    await t.time.pass(10);
    expect(failureCode(await held)).toBe("signed_out");
    expect(aborted).toBe(true);
  });

  it("keeps no refusal of a lease that was replaced", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const old = t.core.session.lease()!;
    // The same session, a new lease (another gate): an invalidation that found the session still current.
    t.server.productStatus = 401;
    t.api.on("GET", "/v1/comma/auth/session", json(200, sessionA));
    await t.product();
    expect(t.snapshot().phase).toBe("signed_in");
    const current = t.core.session.lease();
    expect(current).not.toBe(old);
    expect(t.shown()).toMatchObject({ rejected: { status: 401 } });
    const requests = t.api.requests.length;
    t.server.productStatus = 200;
    // A clean product answer later, then a late 401 of the old lease: nothing changes, nothing is asked.
    await t.time.pass(10);
    const rejectedBefore = t.core.session.value().rejected;
    void refusedByTab(t, old, 401);
    await t.time.pass(10);
    expect(t.core.session.value().rejected).toBe(rejectedBefore);
    expect(t.core.session.lease()).toBe(current);
    expect(t.api.requests).toHaveLength(requests);
  });

  it("settles the snapshot when a host port throws during startup or a sign-out", async () => {
    const broken = setup(sessionA, {
      before: ({ api }) =>
        void api.on("GET", "/v1/comma/auth/session", () => {
          throw new Error("the port broke");
        }),
    });
    await broken.time.pass(20);
    expect(broken.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "initialize" },
    });
    expect(broken.host.locks.active).toBe(0);

    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    t.api.on("POST", "/v1/comma/auth/logout", () => {
      throw new Error("the port broke");
    });
    const answer = await t.ask<{ ok: false; error: unknown }>("session.signOut", {
      expected: t.expected(),
    });
    expect(answer).toMatchObject({
      ok: false,
      error: { code: "unknown", operation: "sign_out" },
    });
    expect(
      sessionOperationErrorSchemaFor("sign_out").safeParse(answer.error).success
    ).toBe(true);
    expect(t.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable", operation: "sign_out" },
    });
    expect(t.host.locks.active).toBe(0);
    // It recovers from there.
    await t.ask("session.recover");
    expect(t.snapshot()).toMatchObject({ phase: "signed_in" });
  });

  it("takes over a guest import the page adapter noted, and redeems it once signed in", async () => {
    const t = setup(sessionA, {
      before: ({ server }) => void (server.guestClaim = true),
    });
    await signedInAs(t, sessionA.session_id);
    expect(t.api.seen("POST", "/v1/comma/guest-imports")).toHaveLength(0);
    expect(
      await t.ask("session.guest.handOverImport", { expiresAtEpochSeconds: 1_000 })
    ).toBe(false);
    expect(
      await t.ask("session.guest.handOverImport", {
        expiresAtEpochSeconds: 2_000_000_000,
      })
    ).toBe(true);
    expect(t.api.seen("POST", "/v1/comma/guest-imports")).toHaveLength(1);
    expect(t.shown()).toMatchObject({ guestImports: 1 });
    expect(t.host.storage.has(MARKER)).toBe(false);
  });
});

describe("the web session across a leader handoff", () => {
  /** A second core on the first one's storage, locks, hints, server and clock: the next tab's worker took over. */
  function takeOver(first: Setup) {
    first.core.close();
    return start(first.server, {
      storage: first.host.storage,
      locks: first.host.locks,
      hints: first.host.hints,
      time: first.time,
      randomFrom: 1_000,
    });
  }

  it("goes on as the same authority and lease when the next core finds the same session", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const before = t.snapshot();
    const next = takeOver(t);
    await signedInAs(next, sessionA.session_id);
    // The pages keep their view: the same authority, generation and session; only the revision moves on.
    expect(next.snapshot()).toMatchObject({
      authority: before.authority,
      generation: before.generation,
      session: { sessionId: sessionA.session_id },
    });
    expect(next.snapshot().revision).toBeGreaterThan(before.revision);
    expect(next.core.session.lease()).not.toBeNull();
    // Another session found by the core after it: a new lease, a new generation.
    next.server.session = sessionB;
    const third = takeOver(next);
    await third.time.pass(40);
    expect(third.snapshot()).toMatchObject({
      authority: before.authority,
      phase: "signed_in",
      session: { sessionId: sessionB.session_id },
    });
    expect(third.snapshot().generation).toBeGreaterThan(before.generation);
  });

  it("recovers a sign-out whose core went before its answer came", async () => {
    const t = setup(sessionA);
    await signedInAs(t, sessionA.session_id);
    const release = t.api.hold("POST", "/v1/comma/auth/logout");
    void t.client
      .call("session.signOut", { expected: t.expected() })
      .catch(() => undefined);
    await t.time.pass(10);
    const inFlight = t.record();
    expect(inFlight).toMatchObject({
      kind: "in_flight",
      operation: { kind: "sign_out", expectedSessionId: sessionA.session_id },
      owner: { deadlineAtEpochMs: t.time.now() - 10 + 8_000 },
    });
    // The server signed out; the tab closed before the answer reached its worker.
    t.server.session = undefined;
    const next = takeOver(t);
    release();
    await next.time.pass(20);
    expect(next.snapshot()).toMatchObject({
      phase: "signed_out",
      reason: "no_session",
    });
    expect(next.auth().at(-1)).toMatchObject({
      path: "/v1/comma/auth/session",
      expected: "unknown",
    });
    expect(next.record()).toMatchObject({ kind: "stable", state: { kind: "absent" } });
    expect(next.record().cookieAuthorityId).not.toBe(inFlight.cookieAuthorityId);
    expect(t.api.seen("POST", "/v1/comma/auth/logout")).toHaveLength(1);
    expect(next.host.locks.active).toBe(0);
  });

  it("resumes a recovery ticket whose attempt was in flight, within its window and after it", async () => {
    const t = setup(sessionA, {
      before: ({ api }) => void api.hold("GET", "/v1/comma/auth/session"),
    });
    await t.time.pass(10);
    expect(t.record()).toMatchObject({
      kind: "recovering",
      ticket: { attemptsStarted: 1, progress: { phase: "in_flight" } },
    });
    // Within the 20 s window: the ticket is ready again, and its second attempt signs in.
    const next = takeOver(t);
    await next.time.pass(20);
    expect(next.snapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: sessionA.session_id },
    });
    expect(next.auth()).toHaveLength(2);

    // After the window: the ticket is used up; the person's retry renews it.
    const late = setup(sessionA, {
      before: ({ api }) => void api.hold("GET", "/v1/comma/auth/session"),
    });
    await late.time.pass(10);
    late.core.close();
    await late.time.pass(25_000);
    const after = start(late.server, {
      storage: late.host.storage,
      locks: late.host.locks,
      hints: late.host.hints,
      time: late.time,
      randomFrom: 1_000,
    });
    await after.time.pass(20);
    expect(after.snapshot()).toMatchObject({
      phase: "indeterminate",
      problem: { code: "session_probe_unavailable" },
    });
    expect(after.record()).toMatchObject({
      kind: "recovering",
      ticket: { progress: { phase: "exhausted" } },
    });
    expect(after.auth()).toHaveLength(1);
    await after.ask("session.recover");
    expect(after.snapshot()).toMatchObject({ phase: "signed_in" });
  });
});

describe("a web sign-in, recorded", () => {
  it("plays again to the same outputs, and differently when the server's answer is changed", async () => {
    const t = setup(undefined);
    await t.time.pass(20);
    const challenge = await t.ask<{
      ok: true;
      value: { attempt: unknown; challengeId: string };
    }>("session.email.request", { email: "a@example.com", expected: t.expected() });
    await t.ask("session.email.verify", {
      attempt: challenge.value.attempt,
      challengeId: challenge.value.challengeId,
      code: "123456",
    });
    await t.time.pass(1_000);
    expect(t.snapshot().phase).toBe("signed_in");

    const recorded = t.core.recorder!;
    const options = {
      sessionSource: "core" as const,
      coalesceMs: 0,
      until: t.time.now(),
    };
    const again = await replay(recorded, options);
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
    expect((again.core.webSession!.snapshot() as SessionLifecycleSnapshot).phase).toBe(
      "signed_in"
    );

    // The server said another person signed in: the replay shows them, not the recorded one.
    const told = structuredClone(recorded.inputs);
    const verified = told.find(
      (input) =>
        input.kind === "response" &&
        input.request.path === "/v1/comma/auth/email/verify"
    )!;
    if (verified.kind !== "response") throw new Error("no verify answer");
    verified.body = base64(
      new TextEncoder().encode(
        new TextDecoder()
          .decode(fromBase64(verified.body))
          .replaceAll("user-a", "user-z")
      )
    );
    const changed = await replay({ inputs: told, outputs: recorded.outputs }, options);
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
    expect(changed.core.webSession!.snapshot()).toMatchObject({
      principal: { userId: "user-z" },
    });
  });
});
