// Ported from systems/connector/salix-connect/meeting_test.go (same test names).
// The meeting runtime bridges meetnative and Salix: join, chat and leave go to meetnative; meetnative's callbacks are
// authenticated, follow the live Salix connection, share bounded admission, wait for Salix's result, keep a stable
// event identity on retry, and turn artifact paths into immutable, meeting-bound, callback-scoped capabilities.
// Meetnative is the MeetHttp fake and callbacks call the handler in process, except where the real TCP listener
// itself is under test (pinned port).
import assert from "node:assert/strict";
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit, Layer } from "effect";
import { type Connector, MAX_CONCURRENT_REQUESTS, type Message, makeConnector } from "../../src/connector/connector.ts";
import {
  MAX_ARTIFACTS_PER_EVENT,
  MAX_MEETING_ARTIFACT_SIZE,
  MEETING_ARTIFACT_TRANSPORT,
  MEETING_EVENT_FINALIZE_BUDGET_MS,
  MEETING_OUTER_SLOP_MS,
  MeetHttp,
  meetingArtifactRequestTimeoutMs,
  meetingEventTimeoutMs,
  meetingRuntimeConfigured,
} from "../../src/connector/meeting.ts";
import { eventually } from "./support/eventually.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
const joinParams = () => ({ meeting_id: "m1", meet_url: "https://meet.google.com/abc-defg-hij", runtime_token: "tok" });

/** Meetnative as a function of (method, path, body). */
function meetnative(answer: (method: string, path: string, body: unknown, url: URL) => { status: number; body?: unknown }) {
  return Layer.succeed(MeetHttp)({
    request: (method, url, body) => Effect.sync(() => {
      const parsed = new URL(url);
      return answer(method, parsed.pathname, body, parsed);
    }),
  });
}

/** A Salix transport that answers capability negotiation and acknowledges meeting events, collecting them. */
function acknowledgingSalix(c: Connector) {
  const events: Array<Record<string, any>> = [];
  const deactivate = c.activateRuntimeTransportForTest((m: Message) =>
    Effect.sync(() => {
      if (m.method === "meeting_runtime_capabilities") {
        queueMicrotask(() => c.completeRuntimeProxy({ id: m.id, type: "response", result: { artifact_transport_versions: [MEETING_ARTIFACT_TRANSPORT] } }));
        return;
      }
      if (m.method === "meeting_runtime_event") events.push(m.params?.event as Record<string, any>);
      queueMicrotask(() => c.completeRuntimeProxy({ id: m.id, type: "response", result: { ok: true } }));
    }),
  );
  return { events, deactivate };
}

const callback = (c: Connector, token: string, event: Record<string, unknown>) =>
  c.meeting.callback(new Request("http://127.0.0.1/meeting-events", { method: "POST", headers: token ? { authorization: `Bearer ${token}` } : {}, body: JSON.stringify({ event }) }));

function expectEvents(events: Array<Record<string, any>>, want: string[]) {
  return eventually(() => events.length >= want.length, `events ${want.join(", ")}`).then(() => {
    want.forEach((type, i) => {
      assert.equal(events[i].type, type, `event ${i}`);
      assert.equal(events[i].meeting_id, "m1", "meeting_id not stamped");
      assert.equal(events[i].runtime_token, "tok", "runtime_token not stamped");
    });
  });
}

test("TestMeetingJoinHTTPForwardsCallbacks", async () => {
  let joined: Record<string, any> = {};
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, _p, body) => ((joined = body as Record<string, any>), { status: 200, body: { accepted: true, session: (body as any).meeting_id } })));
  const salix = acknowledgingSalix(c);
  const out = await run(c.meetingJoin(joinParams()));
  assert.equal(out.accepted, true);
  // Meetnative calls back on the URL the join gave it, with the join's token.
  assert.ok(String(joined.callback_url).endsWith("/meeting-events"));
  for (const event of [{ meeting_id: "m1", type: "caption", text: "hi" }, { meeting_id: "m1", type: "meeting_ended" }]) {
    assert.equal((await callback(c, "tok", event)).status, 202);
  }
  await expectEvents(salix.events, ["caption", "meeting_ended"]);
  salix.deactivate();
  await run(c.close());
});

test("TestMeetingRuntimeNotConfigured", () => {
  const c = makeConnector({});
  assert.equal(c.meeting.detectRuntime(), null, "a meeting runtime without a transport");
  assert.equal(meetingRuntimeConfigured({}), false);
});

test("TestMeetingSendChatForwardsStableMessageID", async () => {
  const received: unknown[] = [];
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, _p, body) => (received.push(body), { status: 200, body: { sent: true } })));
  c.meeting.trackSession("m1", "session-1");
  await run(c.meetingSendChat({ meeting_id: "m1", message_id: "chat-message-1", text: "hello" }));
  assert.equal(received.length, 1);
  assert.deepEqual([(received[0] as any).message_id, (received[0] as any).text], ["chat-message-1", "hello"], "the forwarded body lost the stable message id");
});

test("TestMeetingLeaveRequiresAndClearsActiveSession", async () => {
  const paths: string[] = [];
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, path) => (paths.push(path), { status: 204 })));
  c.meeting.trackToken("m1", "tok");
  c.meeting.trackSession("m1", "session-1");
  await run(c.meetingLeave({ meeting_id: "m1" }));
  assert.deepEqual(paths, ["/v1/meetings/session-1/leave"]);
  assert.equal(c.meeting.session("m1"), "", "the session mapping survived the leave");
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(c.meetingLeave({ meeting_id: "m1" }))), "a leave without an active session succeeded");
});

const MiB = 1024 * 1024;
for (const [name, artifacts, want] of [
  ["no artifacts", undefined, 150],
  ["small artifact", [{ source_ref: "mart_small", source_size: 64 * 1024 }], 210],
  ["maximum single artifact", [{ source_ref: "mart_audio", source_size: 30 * MiB }], 270],
  ["maximum aggregate", [{ source_ref: "mart_audio", source_size: 30 * MiB }, { source_ref: "mart_transcript", source_size: 2 * MiB }], 390],
  ["non-stream artifact does not collapse two-stream budget", [{ source_ref: "mart_audio", source_size: 30 * MiB }, { source_ref: "mart_transcript", source_size: 2 * MiB }, { kind: "audio", source_error: "artifact_count_limit" }], 390],
  ["malformed size fails to bounded floor", [{ source_ref: "mart_bad", source_size: "huge" }], 150],
  ["oversize fails to bounded floor", [{ source_ref: "mart_bad", source_size: 2 ** 62 }], 150],
] as const) {
  test(`TestMeetingEventTimeoutCoversNestedStopAndWaitArtifactFrames/${name}`, () => {
    assert.equal(meetingEventTimeoutMs(artifacts ? { artifacts } : {}), want * 1000);
  });
}

test("TestMeetingEventTimeoutCoversNestedStopAndWaitArtifactFrames/two-artifact deadlines are strictly nested", () => {
  const event = { artifacts: [{ source_ref: "mart_audio", source_size: 30 * MiB }, { source_ref: "mart_transcript", source_size: 2 * MiB }] };
  const children = meetingArtifactRequestTimeoutMs({ expected_size: 30 * MiB }) + meetingArtifactRequestTimeoutMs({ expected_size: 2 * MiB });
  const parent = meetingEventTimeoutMs(event) - MEETING_OUTER_SLOP_MS;
  assert.ok(children + MEETING_EVENT_FINALIZE_BUDGET_MS < parent, "the child budgets must fit below the server parent");
  assert.ok(parent < meetingEventTimeoutMs(event), "the server parent must fit below the callback");
});

test("TestMeetingCallbackAuth", async () => {
  const c = makeConnector({ meetUrl: "http://unused" });
  const salix = acknowledgingSalix(c);
  c.meeting.trackToken("m1", "tok");
  const event = { meeting_id: "m1", type: "caption" };
  assert.equal((await callback(c, "", event)).status, 401, "missing token");
  assert.equal((await callback(c, "wrong", event)).status, 401, "wrong token");
  assert.equal((await callback(c, "tok", event)).status, 202, "valid token");
  salix.deactivate();
});

/** Streams an artifact through meeting_artifact_read on a session that acknowledges every chunk. */
async function readArtifact(c: Connector, params: Record<string, unknown>, onChunk: () => void = () => {}) {
  const chunks: Buffer[] = [];
  let sawEof = false;
  const session = c.claimConnection((frame) =>
    Effect.sync(() => {
      if (!frame.stream) return;
      if (frame.stream.eof) sawEof = true;
      if (frame.stream.data) {
        chunks.push(Buffer.from(frame.stream.data, "base64"));
        onChunk();
        queueMicrotask(() => session.completePendingAck(frame.id!, frame.stream!.seq ?? 0, ""));
      }
    }),
  );
  const exit = await Effect.runPromiseExit(c.dispatchSession(session, "artifact", "meeting_artifact_read", params));
  session.close("canceled");
  return { exit, bytes: Buffer.concat(chunks), sawEof };
}

test("TestMeetingCallbackStreamsOnlyAuthorizedImmutableArtifact", async () => {
  const path = join(tempDir(), "audio.ogg");
  const want = Buffer.from("OggS\u0000bounded meeting audio");
  writeFileSync(path, want, { mode: 0o600 });
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  const salix = acknowledgingSalix(c);
  const response = await callback(c, "tok", { meeting_id: "m1", type: "meeting_ended", artifacts: [{ kind: "audio", filename: "audio.ogg", src_path: path }] });
  assert.equal(response.status, 202);
  await eventually(() => salix.events.length === 1, "the forwarded meeting event");
  const artifacts = salix.events[0].artifacts as Array<Record<string, unknown>>;
  assert.equal(artifacts.length, 1);
  assert.ok(!("src_path" in artifacts[0]), "the runtime path escaped the authenticated callback");
  const ref = String(artifacts[0].source_ref);
  assert.match(ref, /^mart_/);
  assert.equal(c.meeting.artifactForRead("m1", ref), null, "a callback-scoped capability survived the acknowledged forward");
  const directRef = await run(c.meeting.registerArtifact("m1", path));
  const read = await readArtifact(c, { meeting_id: "m1", source_ref: directRef, expected_size: want.length, max_bytes: MAX_MEETING_ARTIFACT_SIZE });
  assert.ok(Exit.isSuccess(read.exit), String(read.exit));
  assert.equal((read.exit.value as Record<string, unknown>).size, want.length);
  assert.ok(read.bytes.equals(want), "the streamed bytes differ");
  assert.equal(c.meeting.artifactForRead("another-meeting", directRef), null, "the capability is not bound to its meeting");
  writeFileSync(path, Buffer.alloc(want.length, "x"));
  const changed = await readArtifact(c, { meeting_id: "m1", source_ref: directRef, expected_size: want.length, max_bytes: MAX_MEETING_ARTIFACT_SIZE });
  assert.ok(Exit.isFailure(changed.exit) && String(changed.exit.cause).includes("meeting artifact changed"), "a changed artifact was streamed");
  c.meeting.releaseArtifacts([directRef]);
  salix.deactivate();
});

// The callback forwards over the current connection: 503 while it is down (meetnative retries), and after a
// reconnect the events go to the new connection, never the stale one.
test("TestMeetingCallbackFollowsLiveSend", async () => {
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  const event = { meeting_id: "m1", type: "caption" };
  assert.equal((await callback(c, "tok", event)).status, 503, "a disconnected callback did not ask for a retry");
  const first = acknowledgingSalix(c);
  assert.equal((await callback(c, "tok", event)).status, 202);
  await expectEvents(first.events, ["caption"]);
  const second = acknowledgingSalix(c);
  assert.equal((await callback(c, "tok", event)).status, 202);
  await expectEvents(second.events, ["caption"]);
  assert.equal(first.events.length, 1, "the stale connection received an event after the reconnect");
  first.deactivate();
  second.deactivate();
});

test("TestMeetingCallbacksShareBoundedRuntimeAdmissionAndRecover", async () => {
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  const held: Message[] = [];
  c.activateRuntimeTransportForTest((m) => Effect.sync(() => void held.push(m)));
  const post = (eventId: string) => callback(c, "tok", { meeting_id: "m1", event_id: eventId, type: "caption", text: eventId });
  const statuses = Array.from({ length: MAX_CONCURRENT_REQUESTS }, (_, i) => post(`held-${i}`));
  await eventually(() => held.length === MAX_CONCURRENT_REQUESTS, "every held callback reaching the runtime");
  // Saturated: refused at once, not queued.
  assert.equal((await post("saturated")).status, 503);
  for (const request of held.splice(0)) c.completeRuntimeProxy({ id: request.id, type: "response", result: { ok: true } });
  for (const status of statuses) assert.equal((await status).status, 202);
  const recovered = post("recovered");
  await eventually(() => held.length === 1, "admission recovering after the slots were released");
  c.completeRuntimeProxy({ id: held[0].id, type: "response", result: { ok: true } });
  assert.equal((await recovered).status, 202);
});

test("TestMeetingCallbackWaitsForSalixResultBeforeAcknowledging", async () => {
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  let attempt = 0;
  c.activateRuntimeTransportForTest((m) =>
    Effect.sync(() => {
      attempt++;
      queueMicrotask(() => c.completeRuntimeProxy(attempt === 1 ? { id: m.id, type: "error", error: "status outbox unavailable" } : { id: m.id, type: "response", result: { ok: true } }));
    }),
  );
  assert.equal((await callback(c, "tok", { meeting_id: "m1", type: "joiner_event" })).status, 503, "a Salix rejection was acknowledged");
  assert.equal((await callback(c, "tok", { meeting_id: "m1", type: "joiner_event" })).status, 202);
  assert.equal(attempt, 2);
});

test("TestMeetingCallbackRetryWithoutProducerEventIDKeepsStableIdentity", async () => {
  const path = join(tempDir(), "transcript.txt");
  writeFileSync(path, "stable retry body", { mode: 0o600 });
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  const eventIds: string[] = [];
  const refs: string[] = [];
  c.activateRuntimeTransportForTest((m) =>
    Effect.sync(() => {
      if (m.method === "meeting_runtime_capabilities") {
        queueMicrotask(() => c.completeRuntimeProxy({ id: m.id, type: "response", result: { artifact_transport_versions: [MEETING_ARTIFACT_TRANSPORT] } }));
        return;
      }
      const event = m.params?.event as Record<string, any>;
      eventIds.push(event.event_id);
      refs.push(event.artifacts[0].source_ref);
      queueMicrotask(() => c.completeRuntimeProxy(eventIds.length === 1 ? { id: m.id, type: "error", error: "retry me" } : { id: m.id, type: "response", result: { ok: true } }));
    }),
  );
  const event = { meeting_id: "m1", type: "meeting_runtime_update", status: "done", artifacts: [{ kind: "transcript", src_path: path }] };
  assert.equal((await callback(c, "tok", event)).status, 503);
  assert.equal((await callback(c, "tok", event)).status, 202);
  assert.ok(eventIds.length === 2 && eventIds[0] && eventIds[0] === eventIds[1], "the retry did not keep one stable fallback event id");
  assert.ok(refs.length === 2 && refs[0] && refs[0] !== refs[1], "the retry did not get fresh callback-scoped refs");
  assert.equal(c.meeting.artifactCountForTest(), 0, "callback refs leaked after the attempts");
});

test("TestMeetingCallbackRejectsArtifactBeforeRegistrationWhenAdmissionIsFull", async () => {
  const path = join(tempDir(), "audio.ogg");
  writeFileSync(path, "must not be hashed or registered", { mode: 0o600 });
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  const release = c.saturateRuntimeProxySlotsForTest();
  assert.equal((await callback(c, "tok", { meeting_id: "m1", type: "meeting_ended", artifacts: [{ kind: "audio", src_path: path }] })).status, 503);
  assert.equal(c.meeting.artifactCountForTest(), 0, "a rejected callback changed the artifact table");
  release();
});

test("TestMeetingCallbackFailsClosedWhenServerDoesNotNegotiateArtifactTransport", async () => {
  const path = join(tempDir(), "audio.ogg");
  writeFileSync(path, "audio", { mode: 0o600 });
  const c = makeConnector({ meetUrl: "http://unused" });
  c.meeting.trackToken("m1", "tok");
  c.activateRuntimeTransportForTest((m) => Effect.sync(() => queueMicrotask(() => c.completeRuntimeProxy({ id: m.id, type: "error", error: "unknown method" }))));
  assert.equal((await callback(c, "tok", { meeting_id: "m1", type: "meeting_ended", artifacts: [{ kind: "audio", src_path: path }] })).status, 503, "a version mismatch was not retryable");
  assert.equal(c.meeting.artifactCountForTest(), 0, "a version mismatch registered capabilities");
});

for (const [name, mutate] of [
  ["same-size rewrite", (path: string, original: Buffer) => writeFileSync(path, Buffer.alloc(original.length, "z"))],
  ["append", (path: string) => appendFileSync(path, "growth")],
] as const) {
  test(`TestMeetingArtifactStreamRejectsSameSizeMutationAndGrowthBeforeEOF/${name}`, async () => {
    const path = join(tempDir(), "audio.ogg");
    const original = Buffer.alloc(256 * 1024, "a");
    writeFileSync(path, original, { mode: 0o600 });
    const c = makeConnector({});
    const ref = await run(c.meeting.registerArtifact("m1", path));
    let mutated = false;
    const read = await readArtifact(c, { meeting_id: "m1", source_ref: ref, expected_size: original.length, max_bytes: MAX_MEETING_ARTIFACT_SIZE }, () => {
      if (!mutated) {
        mutated = true;
        mutate(path, original);
      }
    });
    assert.ok(Exit.isFailure(read.exit) && String(read.exit.cause).includes("changed while streaming"), `want an immutable-stream rejection: ${String(read.exit)}`);
    assert.ok(!read.sawEof, "an immutable-source failure emitted a success EOF");
    c.meeting.releaseArtifacts([ref]);
  });
}

test("TestMeetingArtifactEventBoundsAreTerminalAndDoNotEvictAdmittedRefs", async () => {
  const root = tempDir();
  const paths = ["one.txt", "two.ogg", "three.ogg"].map((name) => join(root, name));
  for (const path of paths) writeFileSync(path, "bounded", { mode: 0o600 });
  const event = { artifacts: [{ kind: "transcript", src_path: paths[0] }, { kind: "audio", src_path: paths[1] }, { kind: "audio", src_path: paths[2] }] as Array<Record<string, unknown>> };
  const c = makeConnector({});
  const refs = await run(c.meeting.authorizeArtifacts("m1", event));
  assert.equal(refs.length, MAX_ARTIFACTS_PER_EVENT);
  assert.equal(c.meeting.artifactCountForTest(), MAX_ARTIFACTS_PER_EVENT);
  assert.deepEqual([event.artifacts[2].source_error, event.artifacts[2].source_ref], ["artifact_count_limit", undefined]);
  c.meeting.releaseArtifacts(refs);
});

// A restarted connector has an empty token table while meetnative still holds the join-time token: the callback
// forwards the presented token for the server's authoritative check instead of refusing it.
test("TestMeetingCallbackForwardsPresentedTokenOnCacheMiss", async () => {
  const c = makeConnector({ meetUrl: "http://127.0.0.1:1" });
  const salix = acknowledgingSalix(c);
  const response = await callback(c, "join-time-token", { meeting_id: "m1", type: "caption", text: "late" });
  assert.equal(response.status, 202);
  await eventually(() => salix.events.length === 1, "the forwarded event");
  assert.equal(salix.events[0].runtime_token, "join-time-token");
  salix.deactivate();
});

test("TestMeetingCallbackStillRejectsLocally", async () => {
  const c = makeConnector({ meetUrl: "http://127.0.0.1:1" });
  c.meeting.trackToken("m1", "tok");
  assert.equal((await callback(c, "wrong", { meeting_id: "m1", type: "caption" })).status, 401, "a cache-hit mismatch was accepted");
  assert.equal((await callback(c, "", { meeting_id: "m1", type: "caption" })).status, 401, "a missing credential was accepted");
  assert.equal((await callback(c, "tok", { type: "caption" })).status, 400, "a missing meeting_id was accepted");
});

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const { port } = server.address() as AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

test("TestMeetingCallbackPinnedPort", async () => {
  const port = await freePort();
  const c = makeConnector({ meetUrl: "http://127.0.0.1:1", meetCallbackPort: port });
  assert.equal(await run(c.meeting.ensureCallback), `http://127.0.0.1:${port}/meeting-events`);
  await run(c.close());
});

test("TestMeetingSessionStatusThreeValued", async () => {
  let respond: () => { status: number; body?: unknown } = () => ({ status: 404 });
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, path, _b, url) => {
    assert.ok(path === "/v1/meetings/status" && url.searchParams.get("meeting_id") === "m1", `unexpected probe ${url}`);
    return respond();
  }));
  const ask = () => run(c.meetingSessionStatus({ meeting_id: "m1" }));
  respond = () => ({ status: 200, body: { meeting_id: "m1", active: true, session: "sess-1" } });
  assert.deepEqual(await ask(), { status: "live", session: "sess-1", join_idempotent: true });
  respond = () => ({ status: 200, body: { meeting_id: "m1", active: false } });
  assert.deepEqual([(await ask()).status, (await ask()).join_idempotent], ["none", true]);
  // An unknown route (an older meetnative), a malformed body and a mismatched echo all stay unavailable.
  for (const answer of [{ status: 404 }, { status: 200, body: { session: "x" } }, { status: 200, body: { meeting_id: "other", active: true } }]) {
    respond = () => answer;
    assert.equal((await ask()).status, "unavailable", JSON.stringify(answer));
  }
  assert.equal((await run(makeConnector({}).meetingSessionStatus({ meeting_id: "m1" }))).status, "unavailable", "an unconfigured runtime gave an answer");
  const unreachable = makeConnector({ meetUrl: "http://meetnative.test" }, Layer.succeed(MeetHttp)({ request: () => Effect.fail(new Error("connect ECONNREFUSED")) }));
  assert.equal((await run(unreachable.meetingSessionStatus({ meeting_id: "m1" }))).status, "unavailable");
});

// With a pinned port the listener exists from process start, not from the next join: the terminal callback of a
// meeting from before a restart is accepted over TCP and forwarded with the presented token.
test("TestPinnedCallbackPortReceivesCacheMissCallbackBeforeAnyJoin", async () => {
  const port = await freePort();
  const c = makeConnector({ name: "test", root: tempDir(), meetUrl: "http://127.0.0.1:1", meetCallbackPort: port, env: { HOME: tempDir() } });
  await run(c.meeting.start);
  const salix = acknowledgingSalix(c);
  const response = await fetch(`http://127.0.0.1:${port}/meeting-events`, {
    method: "POST",
    headers: { authorization: "Bearer join-time-token" },
    body: JSON.stringify({ event: { meeting_id: "m1", type: "meeting_runtime_update", status: "done" } }),
  });
  assert.equal(response.status, 202, "a callback before any join was refused");
  await eventually(() => salix.events.length === 1, "the forwarded terminal event");
  assert.deepEqual([salix.events[0].runtime_token, salix.events[0].status], ["join-time-token", "done"]);
  salix.deactivate();
  await run(c.close());
});

test("TestPinnedCallbackPortBindFailureIsFatalAtStartup", async () => {
  const holder = createServer();
  await new Promise<void>((resolve) => holder.listen(0, "127.0.0.1", () => resolve()));
  const { port } = holder.address() as AddressInfo;
  try {
    const c = makeConnector({ name: "test", root: tempDir(), meetUrl: "http://127.0.0.1:1", meetCallbackPort: port, env: { HOME: tempDir() } });
    const started = await Effect.runPromiseExit(c.meeting.start);
    assert.ok(Exit.isFailure(started) && /pinned meeting callback port/.test(String(started.cause)), "a busy pinned port did not stop the start");
  } finally {
    holder.close();
  }
});

test("TestMeetingJoinAdoptsLiveRuntimeSession", async () => {
  let joins = 0;
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, path) => {
    if (path === "/v1/meetings/status") return { status: 200, body: { meeting_id: "m1", active: true, session: "sess-live" } };
    if (path === "/v1/meetings/join") return (joins++, { status: 200, body: { accepted: true, session: "sess-new" } });
    return { status: 404 };
  }));
  const out = await run(c.meetingJoin(joinParams()));
  assert.deepEqual([out.accepted, out.already, out.session], [true, true, "sess-live"], "the live session was not adopted");
  assert.equal(joins, 0, "a join for a live session raised a second bot");
  assert.equal(c.meeting.session("m1"), "sess-live", "the adopted session is not tracked for chat and leave");
});

test("TestMeetingJoinProceedsOnDefinitelyNoneAnswer", async () => {
  let joins = 0;
  const c = makeConnector({ meetUrl: "http://meetnative.test" }, meetnative((_m, path) => {
    if (path === "/v1/meetings/status") return { status: 200, body: { meeting_id: "m1", active: false } };
    if (path === "/v1/meetings/join") return (joins++, { status: 200, body: { accepted: true, session: "sess-new" } });
    return { status: 404 };
  }));
  const out = await run(c.meetingJoin(joinParams()));
  assert.ok(out.accepted === true && out.already !== true, "no fresh dispatch");
  assert.equal(joins, 1);
  await run(c.close());
});

test("TestMeetingSessionStatusAttestsIdempotentJoinOnlyWithRuntime", async () => {
  // Unconfigured: no runtime, no attestation.
  const out = await run(makeConnector({}).meetingSessionStatus({ meeting_id: "m1" }));
  assert.deepEqual([out.status, out.join_idempotent], ["unavailable", undefined]);
  // Configured but unreachable (a pinned meetnative without /status): unavailable, with idempotency attested.
  const unreachable = makeConnector({ meetUrl: "http://meetnative.test" }, Layer.succeed(MeetHttp)({ request: () => Effect.fail(new Error("connect ECONNREFUSED")) }));
  const answer = await run(unreachable.meetingSessionStatus({ meeting_id: "m1" }));
  assert.deepEqual([answer.status, answer.join_idempotent], ["unavailable", true]);
});

