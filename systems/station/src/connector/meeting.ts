// The meeting runtime: meetnative (the meeting bot) on one side, Salix on the other. Join, chat, leave and the
// live-session probe go to meetnative over HTTP; meetnative calls back on a local listener with events, which are
// authenticated, share the runtime proxy's bounded admission, and are acknowledged only once Salix accepted them.
// Artifact paths in an event become opaque, meeting-bound capabilities that live for one callback; Salix streams the
// exact bytes through meeting_artifact_read. The same listener serves /llm/chat, the bot's LLM route through Salix.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import { resolve } from "node:path";
import { Cause, Clock, Context, Duration, Effect, Exit, Layer } from "effect";
import { REQUEST_EXECUTION_TIMEOUT } from "./config.ts";
import { MAX_FILE_BYTES } from "./fs-methods.ts";
import { type Message, intParam, stringParam } from "./message.ts";
import type { RuntimeTransport } from "./runtime-transport.ts";
import type { Session } from "./session.ts";

export const MEETING_ARTIFACT_TRANSPORT = "opaque-v1";
export const MAX_MEETING_ARTIFACTS = 128;
export const MAX_ARTIFACTS_PER_EVENT = 2;
export const MAX_MEETING_ARTIFACT_SIZE = 30 * 1024 * 1024;
export const MAX_MEETING_ARTIFACT_EVENT_SIZE = 32 * 1024 * 1024;
const ARTIFACT_PROBE_TIMEOUT = Duration.seconds(5);
const ARTIFACT_TTL_MS = 2 * 60 * 60_000;
const ARTIFACT_FRAME_BYTES = 64 * 1024;
const ARTIFACT_FRAME_BUDGET_MS = 250;
const ARTIFACT_SETUP_BUDGET_MS = 30_000;
export const MEETING_EVENT_FINALIZE_BUDGET_MS = 30_000;
const EVENT_SERVER_SLOP_MS = 30_000;
const EVENT_SERVER_FLOOR_MS = 120_000;
export const MEETING_OUTER_SLOP_MS = 30_000;

/** Meetnative's HTTP API: a JSON body in, the status and the (JSON, else text) body out. */
export class MeetHttp extends Context.Service<MeetHttp, { request(method: string, url: string, body: unknown, timeout: Duration.Duration): Effect.Effect<{ status: number; body?: unknown }, Error> }>()(
  "station/MeetHttp",
) {}

export const liveMeetHttp = Layer.succeed(MeetHttp)({
  request: (method, url, body, timeout) =>
    Effect.tryPromise({
      try: async (signal) => {
        const response = await fetch(url, {
          method,
          signal,
          headers: body === undefined ? {} : { "content-type": "application/json" },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const text = await response.text();
        let parsed: unknown = text;
        try {
          parsed = text ? JSON.parse(text) : undefined;
        } catch {}
        return { status: response.status, body: parsed };
      },
      catch: (e) => (e instanceof Error ? e : new Error(String(e))),
    }).pipe(
      Effect.timeoutOption(timeout),
      Effect.flatMap((o) => (o._tag === "Some" ? Effect.succeed(o.value) : Effect.fail(new Error("context deadline exceeded")))),
    ),
});

export const meetingRuntimeConfigured = (cfg: { meetUrl?: string }) => (cfg.meetUrl ?? "").trim() !== "";

/** A meeting event's callback budget: the server's finalize budget plus each artifact stream's, with slop. */
export function meetingEventTimeoutMs(event: Record<string, unknown>): number {
  const sizes = boundedArtifactSizes(event) ?? [];
  let server = MEETING_EVENT_FINALIZE_BUDGET_MS + EVENT_SERVER_SLOP_MS;
  // The connector-side request may live one outer slop after the server has the stream: parents cover the lifetime.
  for (const size of sizes) server += artifactChildBudgetMs(size) + MEETING_OUTER_SLOP_MS;
  return Math.max(server, EVENT_SERVER_FLOOR_MS) + MEETING_OUTER_SLOP_MS;
}

/** A meeting_artifact_read's budget for its declared size; the general request timeout when undeclared. */
export function meetingArtifactRequestTimeoutMs(params: Record<string, unknown> | undefined, generalMs = Duration.toMillis(REQUEST_EXECUTION_TIMEOUT)): number {
  const size = intParam(params, "expected_size", -1);
  if (size < 0 || size > MAX_MEETING_ARTIFACT_SIZE) return generalMs;
  return artifactChildBudgetMs(size) + MEETING_OUTER_SLOP_MS;
}

function artifactChildBudgetMs(size: number): number {
  const frames = Math.ceil(size / ARTIFACT_FRAME_BYTES);
  return Math.max(ARTIFACT_SETUP_BUDGET_MS + frames * ARTIFACT_FRAME_BUDGET_MS, 90_000);
}

function boundedArtifactSizes(event: Record<string, unknown>): number[] | null {
  const values = event.artifacts;
  if (!Array.isArray(values)) return [];
  const sizes: number[] = [];
  let aggregate = 0;
  for (const value of values) {
    if (!value || typeof value !== "object") return null;
    const artifact = value as Record<string, unknown>;
    if (!text(artifact.source_ref).trim()) continue;
    if (sizes.length >= MAX_ARTIFACTS_PER_EVENT) return null;
    const size = intParam(artifact, "source_size", -1);
    if (size < 0 || size > MAX_MEETING_ARTIFACT_SIZE || aggregate > MAX_MEETING_ARTIFACT_EVENT_SIZE - size) return null;
    aggregate += size;
    sizes.push(size);
  }
  return sizes;
}

type Artifact = { meetingId: string; path: string; size: number; mtimeMs: number; hash: Buffer; registered: number };

/** An artifact that cannot be read as authorized: the event goes on with a source_error instead of being retried. */
class ArtifactTerminal extends Error {}

export type MeetingHost = {
  meetUrl: string;
  callbackHost: string;
  callbackPort: number;
  transport: RuntimeTransport;
  nowMs(): number;
  /** Runs an effect with the connector's clock and services. */
  run<A, E>(effect: Effect.Effect<A, E, MeetHttp>): Promise<Exit.Exit<A, E>>;
};

const text = (value: unknown) => (typeof value === "string" ? value : "");
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const bearer = (header: string | null) => (header?.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "");
const errorOf = (cause: Cause.Cause<unknown>) => {
  const error = Cause.squash(cause);
  return error instanceof Error ? error : new Error(String(error));
};

export function makeMeeting(host: MeetingHost) {
  const tokens = new Map<string, string>();
  const sessions = new Map<string, string>();
  const artifacts = new Map<string, Artifact>();
  let server: Server | null = null;
  let baseUrl = "";
  const base = () => host.meetUrl.trim().replace(/\/+$/, "");
  const configured = () => host.meetUrl.trim() !== "";

  const meet = (method: string, path: string, body: unknown, timeout: Duration.Duration) =>
    Effect.flatMap(Effect.service(MeetHttp), (http) => http.request(method, `${base()}${path}`, body, timeout));

  // Artifacts.

  const prune = (now: number) => {
    for (const [ref, artifact] of artifacts) if (now - artifact.registered > ARTIFACT_TTL_MS) artifacts.delete(ref);
  };

  const registerArtifact = (meetingId: string, path: string): Effect.Effect<{ ref: string; size: number }, Error> =>
    Effect.gen(function* () {
      if (!meetingId.trim()) return yield* Effect.fail(new Error("meeting_id is required"));
      const full = resolve(path);
      const read = yield* Effect.try({
        try: () => {
          const fd = openSync(full, "r");
          try {
            const info = fstatSync(fd);
            if (!info.isFile()) throw new ArtifactTerminal("source is not a regular file");
            if (info.size > MAX_MEETING_ARTIFACT_SIZE) throw new ArtifactTerminal("source exceeds the bounded upload size");
            const hash = createHash("sha256");
            const buffer = Buffer.alloc(ARTIFACT_FRAME_BYTES);
            let n: number;
            while ((n = readSync(fd, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, n));
            return { size: info.size, mtimeMs: info.mtimeMs, hash: hash.digest() };
          } finally {
            closeSync(fd);
          }
        },
        catch: (e) => e as Error,
      });
      const now = yield* Clock.currentTimeMillis;
      prune(now);
      if (artifacts.size >= MAX_MEETING_ARTIFACTS) return yield* Effect.fail(new Error("meeting artifact reference capacity exhausted"));
      const ref = `mart_${randomBytes(24).toString("hex")}`;
      artifacts.set(ref, { meetingId, path: full, ...read, registered: now });
      return { ref, size: read.size };
    });

  const releaseArtifacts = (refs: string[]) => {
    for (const ref of refs) artifacts.delete(ref);
  };

  /** Replaces an event's local audio/transcript paths with capabilities; returns the refs it made. */
  const authorizeArtifacts = (meetingId: string, event: Record<string, unknown>): Effect.Effect<string[], Error> =>
    Effect.gen(function* () {
      const values = event.artifacts;
      if (!Array.isArray(values)) return [];
      let authorized = 0;
      let aggregate = 0;
      const refs: string[] = [];
      for (const value of values) {
        if (!value || typeof value !== "object") continue;
        const artifact = value as Record<string, unknown>;
        const path = text(artifact.src_path).trim();
        const kind = text(artifact.kind).trim();
        if (!path || (kind !== "audio" && kind !== "transcript")) continue;
        delete artifact.src_path;
        if (authorized >= MAX_ARTIFACTS_PER_EVENT) {
          artifact.source_error = "artifact_count_limit";
          continue;
        }
        authorized++;
        const registered = yield* Effect.exit(registerArtifact(meetingId, path));
        if (Exit.isFailure(registered)) {
          const error = errorOf(registered.cause);
          if (error instanceof ArtifactTerminal) {
            artifact.source_error = "unavailable";
            continue;
          }
          releaseArtifacts(refs);
          return yield* Effect.fail(error);
        }
        const { ref, size } = registered.value;
        if (aggregate + size > MAX_MEETING_ARTIFACT_EVENT_SIZE) {
          releaseArtifacts([ref]);
          artifact.source_error = "artifact_event_size_limit";
          continue;
        }
        aggregate += size;
        refs.push(ref);
        artifact.source_ref = ref;
        artifact.source_size = size;
      }
      return refs;
    });

  const artifactForRead = (meetingId: string, ref: string): Artifact | null => {
    prune(host.nowMs());
    const artifact = ref ? artifacts.get(ref) : undefined;
    return artifact && artifact.meetingId === meetingId ? artifact : null;
  };

  /** meeting_artifact_read: the exact authorized bytes as read stream frames, or a failure if the file changed. */
  const readArtifact = (session: Session, id: string, params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.gen(function* () {
      const meetingId = stringParam(params, "meeting_id");
      const ref = stringParam(params, "source_ref");
      if (!meetingId || !ref) return yield* Effect.fail(new Error("meeting_id and source_ref are required"));
      prune(yield* Clock.currentTimeMillis);
      const artifact = artifacts.get(ref);
      if (!artifact) return yield* Effect.fail(new Error("unknown or expired meeting artifact reference"));
      if (artifact.meetingId !== meetingId) return yield* Effect.fail(new Error("meeting artifact reference does not belong to this meeting"));
      const expected = intParam(params, "expected_size", -1);
      const maxBytes = intParam(params, "max_bytes", -1);
      if (expected < 0 || expected !== artifact.size) return yield* Effect.fail(new Error("meeting artifact declared size mismatch"));
      if (maxBytes < 0 || artifact.size > maxBytes || maxBytes > MAX_MEETING_ARTIFACT_SIZE) return yield* Effect.fail(new Error("meeting artifact exceeds server byte budget"));
      const fd = yield* Effect.try({ try: () => openSync(artifact.path, "r"), catch: (e) => e as Error });
      return yield* Effect.gen(function* () {
        const unchanged = () => {
          const info = fstatSync(fd);
          return info.isFile() && info.size === artifact.size && info.mtimeMs === artifact.mtimeMs;
        };
        if (!unchanged()) return yield* Effect.fail(new Error("meeting artifact changed after authorization"));
        const changed = new Error("meeting artifact changed while streaming");
        const hash = createHash("sha256");
        const buffer = Buffer.alloc(ARTIFACT_FRAME_BYTES);
        let seq = 0;
        let sent = 0;
        while (sent < artifact.size) {
          const n = readSync(fd, buffer, 0, Math.min(buffer.length, artifact.size - sent), null);
          if (n === 0) return yield* Effect.fail(changed);
          seq++;
          sent += n;
          hash.update(buffer.subarray(0, n));
          const frame: Message = { id, type: "stream", stream: { channel: "data", data: buffer.subarray(0, n).toString("base64"), eof: false, seq } };
          yield* session.sendReadStreamFrame(id, seq, frame);
        }
        const extra = readSync(fd, Buffer.alloc(1), 0, 1, null);
        if (extra !== 0 || !unchanged() || !timingSafeEqual(hash.digest(), artifact.hash)) return yield* Effect.fail(changed);
        yield* session.send({ id, type: "stream", stream: { channel: "data", data: "", eof: true, seq: seq + 1 } });
        return { size: artifact.size };
      }).pipe(Effect.ensuring(Effect.sync(() => closeSync(fd))));
    });

  // Callbacks from meetnative.

  const requireArtifactTransport = (carrier: ReturnType<RuntimeTransport["active"]>): Effect.Effect<void, Error> =>
    Effect.gen(function* () {
      if (!carrier) return yield* Effect.fail(new Error("connector transport unavailable"));
      const reply = yield* host.transport.request(
        carrier,
        { id: `meetcap_${randomBytes(16).toString("hex")}`, type: "request", method: "meeting_runtime_capabilities", params: { artifact_transport: MEETING_ARTIFACT_TRANSPORT } },
        ARTIFACT_PROBE_TIMEOUT,
      );
      if (reply.type === "error" || (reply.error ?? "").trim()) return yield* Effect.fail(new Error(`server rejected meeting artifact transport: ${reply.error}`));
      const versions = (reply.result as { artifact_transport_versions?: unknown } | undefined)?.artifact_transport_versions;
      if (Array.isArray(versions) && versions.includes(MEETING_ARTIFACT_TRANSPORT)) return;
      return yield* Effect.fail(new Error("server does not advertise opaque meeting artifact transport"));
    });

  const forwardEvent = (carrier: ReturnType<RuntimeTransport["active"]>, meetingId: string, runtimeToken: string, source: Record<string, unknown>, timeoutMs: number): Effect.Effect<void, Error> =>
    Effect.gen(function* () {
      if (!carrier) return yield* Effect.fail(new Error("no active connector connection"));
      const event: Record<string, unknown> = { meeting_id: meetingId, ...source };
      if (runtimeToken) event.runtime_token = runtimeToken;
      if (!text(event.type)) event.type = "joiner_event";
      const reply = yield* host.transport.request(carrier, { id: `meeting_event_${randomBytes(12).toString("hex")}`, type: "request", method: "meeting_runtime_event", params: { event } }, Duration.millis(timeoutMs));
      if (reply.type === "error" || reply.error) return yield* Effect.fail(new Error(reply.error || "meeting runtime event rejected"));
    });

  const callback = async (request: Request): Promise<Response> => {
    let event: Record<string, unknown> | null = null;
    try {
      const body = (await request.json()) as { event?: unknown };
      if (body?.event && typeof body.event === "object" && !Array.isArray(body.event)) event = body.event as Record<string, unknown>;
    } catch {}
    if (!event) return new Response(null, { status: 400 });
    const meetingId = text(event.meeting_id);
    if (!meetingId.trim()) return new Response(null, { status: 400 });
    // The token table is a precheck cache in front of Salix's authoritative check: a hit still refuses a mismatch,
    // a miss (a restart during a live meeting) forwards the presented token for Salix to verify.
    const presented = bearer(request.headers.get("authorization"));
    if (!presented) return new Response(null, { status: 401 });
    const known = tokens.get(meetingId) ?? "";
    if (known && !constantTimeEqual(presented, known)) return new Response(null, { status: 401 });
    const admitted = await host.run(
      host.transport.withProxySlotIfAvailable(
        Effect.gen(function* () {
          ensureEventId(meetingId, event);
          const carrier = host.transport.active();
          if (hasLocalArtifacts(event)) {
            const negotiated = yield* Effect.exit(requireArtifactTransport(carrier));
            if (Exit.isFailure(negotiated)) return json(503, { accepted: false, reason: "artifact transport unavailable" });
          }
          const authorized = yield* Effect.exit(authorizeArtifacts(meetingId, event));
          if (Exit.isFailure(authorized)) return json(503, { accepted: false, reason: "artifact authorization failed" });
          const forwarded = yield* Effect.exit(forwardEvent(carrier, meetingId, presented, event, meetingEventTimeoutMs(event)).pipe(Effect.ensuring(Effect.sync(() => releaseArtifacts(authorized.value)))));
          if (Exit.isFailure(forwarded)) return json(503, { accepted: false });
          return json(202, { accepted: true });
        }),
      ),
    );
    if (Exit.isFailure(admitted)) return json(503, { accepted: false });
    return admitted.value._tag === "Some" ? admitted.value.value : json(503, { accepted: false, reason: "capacity exhausted" });
  };

  /** /llm/chat: the bot's bearer is its LLM capability token, relayed to Salix as a runtime proxy request. */
  const llmChat = async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return new Response("method not allowed\n", { status: 405 });
    const token = bearer(request.headers.get("authorization"));
    if (!token) return new Response(null, { status: 401 });
    const body = Buffer.from(await request.arrayBuffer());
    if (body.length > MAX_FILE_BYTES) return new Response("request body exceeds 10MB cap\n", { status: 413 });
    const result = await host.run(host.transport.proxy({ capability_token: token, method: "POST", route_path: "/llm/chat", body_base64: body.toString("base64") }));
    if (Exit.isFailure(result)) return new Response(`${errorOf(result.cause).message}\n`, { status: 502 });
    return proxyResponse(result.value);
  };

  const route = (request: Request): Promise<Response> => {
    const path = new URL(request.url).pathname;
    if (path === "/meeting-events") return callback(request);
    if (path === "/llm/chat") return llmChat(request);
    return Promise.resolve(new Response("404 page not found\n", { status: 404 }));
  };

  /** The callback listener: on 127.0.0.1 (all interfaces with a callback host), at the pinned port or any. */
  const ensureCallback: Effect.Effect<string, Error> = Effect.callback<string, Error>((resume) => {
    if (baseUrl) return resume(Effect.succeed(`${baseUrl}/meeting-events`));
    const callbackHost = host.callbackHost.trim();
    const listener = createServer((req, res) => void serveNode(route, req, res));
    listener.once("error", (error) => resume(Effect.fail(error)));
    listener.listen(host.callbackPort, callbackHost ? "0.0.0.0" : "127.0.0.1", () => {
      listener.removeAllListeners("error");
      // The station keeps itself up; a callback listener alone does not.
      listener.unref();
      server = listener;
      baseUrl = `http://${callbackHost || "127.0.0.1"}:${(listener.address() as AddressInfo).port}`;
      resume(Effect.succeed(`${baseUrl}/meeting-events`));
    });
  });

  /** At start: a pinned port is bound now, so a restarted connector receives callbacks for meetings it joined before. */
  const start: Effect.Effect<void, Error> = Effect.suspend(() => {
    if (!configured() || host.callbackPort <= 0) return Effect.void;
    return ensureCallback.pipe(Effect.asVoid, Effect.mapError((e) => new Error(`bind pinned meeting callback port ${host.callbackPort}: ${e.message}`)));
  });

  // Methods.

  const sessionStatus = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error, MeetHttp> =>
    Effect.gen(function* () {
      const meetingId = stringParam(params, "meeting_id");
      if (!meetingId) return yield* Effect.fail(new Error("meeting_id is required"));
      if (!configured()) return { status: "unavailable", reason: "not_configured" };
      // A configured runtime attests meetnative's idempotent join, whatever the probe answers.
      const attested = (out: Record<string, unknown>) => ({ ...out, join_idempotent: true });
      const answer = yield* Effect.exit(meet("GET", `/v1/meetings/status?${new URLSearchParams({ meeting_id: meetingId })}`, undefined, Duration.seconds(10)));
      if (Exit.isFailure(answer)) return attested({ status: "unavailable", reason: "runtime_unreachable" });
      const { status, body } = answer.value;
      if (status < 200 || status >= 300) return attested({ status: "unavailable", reason: `http_${status}` });
      const parsed = body && typeof body === "object" ? (body as { meeting_id?: unknown; active?: unknown; session?: unknown }) : null;
      if (!parsed || typeof parsed.active !== "boolean") return attested({ status: "unavailable", reason: "malformed_runtime_answer" });
      if (text(parsed.meeting_id) && parsed.meeting_id !== meetingId) return attested({ status: "unavailable", reason: "meeting_id_mismatch" });
      if (!parsed.active) return attested({ status: "none" });
      const out: Record<string, unknown> = { status: "live" };
      if (text(parsed.session)) out.session = parsed.session;
      return attested(out);
    });

  const join = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error, MeetHttp> =>
    Effect.gen(function* () {
      const meetingId = stringParam(params, "meeting_id");
      if (!meetingId) return yield* Effect.fail(new Error("meeting_id is required"));
      if (!stringParam(params, "meet_url")) return yield* Effect.fail(new Error("meet_url is required"));
      if (!configured()) return yield* Effect.fail(new Error("meeting runtime not configured"));
      // A live session for this meeting is adopted rather than joined twice; only a definite "live" short-circuits.
      const status = yield* Effect.exit(sessionStatus({ meeting_id: meetingId }));
      if (Exit.isSuccess(status) && status.value.status === "live") {
        tokens.set(meetingId, stringParam(params, "runtime_token"));
        const session = text(status.value.session);
        if (session) sessions.set(meetingId, session);
        return session ? { accepted: true, already: true, session } : { accepted: true, already: true };
      }
      tokens.set(meetingId, stringParam(params, "runtime_token"));
      const callbackUrl = yield* ensureCallback;
      const body: Record<string, unknown> = { ...params, callback_url: callbackUrl };
      if (stringParam(params, "llm_capability_token")) body.llm_url = `${baseUrl}/llm/chat`;
      const { status: code, body: answer } = yield* meet("POST", "/v1/meetings/join", body, Duration.seconds(15));
      if (code < 200 || code >= 300) return yield* Effect.fail(new Error(`meetnative join failed: HTTP ${code} ${bodyText(answer)}`));
      const out: Record<string, unknown> = answer && typeof answer === "object" && !Array.isArray(answer) ? { ...(answer as Record<string, unknown>) } : {};
      if (text(out.session)) sessions.set(meetingId, text(out.session));
      out.accepted = true;
      return out;
    });

  const sendChat = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error, MeetHttp> =>
    Effect.gen(function* () {
      const meetingId = stringParam(params, "meeting_id");
      const messageId = stringParam(params, "message_id");
      const body = stringParam(params, "text");
      if (!meetingId) return yield* Effect.fail(new Error("meeting_id is required"));
      if (!messageId) return yield* Effect.fail(new Error("message_id is required"));
      if (!body) return yield* Effect.fail(new Error("text is required"));
      if (!configured()) return yield* Effect.fail(new Error("meeting runtime not configured"));
      const session = sessions.get(meetingId);
      if (!session) return yield* Effect.fail(new Error(`no active meetnative session for meeting ${meetingId}`));
      const { status, body: answer } = yield* meet("POST", `/v1/meetings/${session}/chat`, { message_id: messageId, text: body }, Duration.seconds(15));
      if (status < 200 || status >= 300) return yield* Effect.fail(new Error(`meetnative chat failed: HTTP ${status} ${bodyText(answer)}`));
      return { sent: true };
    });

  const leave = (params: Record<string, unknown>): Effect.Effect<void, Error, MeetHttp> =>
    Effect.gen(function* () {
      const meetingId = stringParam(params, "meeting_id");
      if (!meetingId) return yield* Effect.fail(new Error("meeting_id is required"));
      if (!configured()) return yield* Effect.fail(new Error("meeting runtime not configured"));
      const session = sessions.get(meetingId);
      if (!session) return yield* Effect.fail(new Error(`no active meetnative session for meeting ${meetingId}`));
      const { status } = yield* meet("POST", `/v1/meetings/${session}/leave`, {}, Duration.seconds(15));
      if (status < 200 || status >= 300) return yield* Effect.fail(new Error(`meetnative leave failed: HTTP ${status}`));
      tokens.delete(meetingId);
      sessions.delete(meetingId);
    });

  return {
    configured,
    detectRuntime: () => (configured() ? [{ id: "meetnative", kind: "meeting", provider: "meetnative", status: "ready", ready: true, transports: ["http"] }] : null),
    join,
    sendChat,
    leave,
    sessionStatus,
    readArtifact,
    callback,
    llmChat,
    ensureCallback,
    start,
    registerArtifact: (meetingId: string, path: string) => registerArtifact(meetingId, path).pipe(Effect.map((r) => r.ref)),
    authorizeArtifacts,
    releaseArtifacts,
    artifactForRead,
    trackToken: (meetingId: string, token: string) => void tokens.set(meetingId, token),
    trackSession: (meetingId: string, session: string) => void sessions.set(meetingId, session),
    session: (meetingId: string) => sessions.get(meetingId) ?? "",
    artifactCountForTest: () => artifacts.size,
    close: Effect.callback<void>((resume) => {
      const listener = server;
      server = null;
      baseUrl = "";
      if (!listener) return resume(Effect.void);
      listener.close(() => resume(Effect.void));
      listener.closeAllConnections();
    }),
  };
}

export type Meeting = ReturnType<typeof makeMeeting>;

/** A stable event id when meetnative gave none, so a retried callback keeps one Salix source identity. */
function ensureEventId(meetingId: string, event: Record<string, unknown>) {
  if (text(event.event_id).trim()) return;
  const digest = createHash("sha256").update(JSON.stringify({ meeting_id: meetingId, event: sortKeys(event) })).digest("hex");
  event.event_id = `connector-${digest}`;
}

/** Keys in order, as Go's encoding/json writes a map: the digest does not depend on meetnative's field order. */
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys((value as Record<string, unknown>)[key])]));
  return value;
}

function hasLocalArtifacts(event: Record<string, unknown>): boolean {
  if (!Array.isArray(event.artifacts)) return false;
  return event.artifacts.some((value) => {
    const artifact = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
    const kind = text(artifact.kind).trim();
    return text(artifact.src_path).trim() !== "" && (kind === "audio" || kind === "transcript");
  });
}

function constantTimeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

function bodyText(body: unknown): string {
  if (body === undefined || body === null) return "";
  return (typeof body === "string" ? body : JSON.stringify(body)).trim();
}

function proxyResponse(result: Record<string, unknown>): Response {
  const headers = new Headers();
  const given = result.headers && typeof result.headers === "object" ? (result.headers as Record<string, unknown>) : {};
  for (const [key, value] of Object.entries(given)) if (value !== undefined && value !== null && String(value)) headers.set(key, String(value));
  let status = typeof result.status === "number" ? Math.trunc(result.status) : 200;
  if (status < 200 || status > 599) status = 200;
  const body = typeof result.body_base64 === "string" && result.body_base64 ? Buffer.from(result.body_base64, "base64") : typeof result.body === "string" && result.body ? result.body : null;
  return new Response(body, { status, headers });
}

/** Serves a Node request with a fetch-style handler. */
async function serveNode(handler: (request: Request) => Promise<Response>, req: IncomingMessage, res: ServerResponse) {
  try {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req) {
      size += (chunk as Buffer).length;
      if (size > MAX_FILE_BYTES + 1) break;
      chunks.push(chunk as Buffer);
    }
    const headers = new Headers();
    for (const [key, value] of Object.entries(req.headers)) if (value !== undefined) headers.set(key, Array.isArray(value) ? value.join(",") : value);
    const method = req.method ?? "GET";
    const request = new Request(`http://127.0.0.1${req.url ?? "/"}`, { method, headers, body: method === "GET" || method === "HEAD" ? undefined : Buffer.concat(chunks) });
    const response = await handler(request);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch {
    res.destroy();
  }
}
