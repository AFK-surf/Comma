// Members' connections over the mesh (the Rust station's main.rs `serve`, `relay_request`). Wire format, on ALPN
// `stillfail/admin/1` (and `ember/admin/1`, as clients from before the rename ask): the first bidirectional stream
// carries credentials, one JSON line each, answered with one JSON line (a later line renews); every other stream is
// one request: a JSON head line `{method, path, headers}`, then the body until the stream finishes, answered by a
// JSON head line `{status, headers}` and the response body.
import type { Admin } from "../api/admin.ts";
import { langOfCore, queryPairs } from "../api/request.ts";
import { type Cloud, workspaceIds } from "../cloud/state.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { nowSecs } from "../ops/files.ts";
import type { Accepted } from "../cloud/provider.ts";
import { type Admitted, readOnly, revoked, verifyMember } from "./credential.ts";
import type { Connection, Stream } from "./native.ts";
import { answerAdb, type Shares } from "./adb.ts";
import { Traces, parseParent, route } from "./traces.ts";
import { FrameReader, SocketRefused, openSocket, previewTarget, pumpSocket } from "../jobs/preview.ts";

export const ALPN = Buffer.from("stillfail/admin/1");
export const FORMER_ALPN = Buffer.from("ember/admin/1");
// Keep old clients admitted until protocol-2 clients have reached the stable channel.
const MIN_CLIENT_PROTOCOL = 1;
const MAX_HEAD = 16 * 1024;
// Files sent to a session go through here: in parts of 16 MB at most, or whole up to 50 MB (clients before parts).
const MAX_BODY = 64 * 1024 * 1024;
/// Headers of one hop, not of what is relayed.
const HOP = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "host", "content-length"];

/// One JSON line at a time from a stream, then the rest of it.
export class Reader {
  carry: Buffer = Buffer.alloc(0);
  stream: Stream;
  /// How long a line may be: the admin API's heads are small; the device tools' carry their bodies in it.
  private maxLine: number;
  constructor(stream: Stream, maxLine = MAX_HEAD) {
    this.stream = stream;
    this.maxLine = maxLine;
  }

  async line(): Promise<any | null> {
    // A long line (the device tools') comes in many pieces: kept as they come, each looked through once.
    let at = this.carry.indexOf(10);
    if (at < 0) {
      const parts = [this.carry];
      let size = this.carry.length;
      while (at < 0) {
        if (size > this.maxLine) throw new Error("head too large");
        const more = await this.stream.read();
        if (more === null) {
          if (size === 0) return null;
          throw new Error("stream ended mid-line");
        }
        const found = more.indexOf(10);
        if (found >= 0) at = size + found;
        parts.push(more);
        size += more.length;
      }
      this.carry = Buffer.concat(parts, size);
    }
    if (at > this.maxLine) throw new Error("head too large");
    const line = this.carry.subarray(0, at);
    this.carry = this.carry.subarray(at + 1);
    return JSON.parse(line.toString());
  }

  async rest(): Promise<Buffer> {
    const parts = [this.carry];
    let size = this.carry.length;
    for (let more = await this.stream.read(); more; more = await this.stream.read()) {
      parts.push(more);
      size += more.length;
      if (size > MAX_BODY) throw new Error("request body too large");
    }
    return Buffer.concat(parts);
  }
}

export const writeLine = (stream: Stream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

export type Members = {
  cloud: Cloud;
  admin: Admin;
  /// Whether the station answers now (its parts started; not handing over).
  up(): boolean;
  /// Phones lent to the agents.
  shares: Shares;
  /// The mesh's spans, when traces are on.
  traces?: Traces;
  /// Which member credentials the control plane signs (still.fail cloud's when not said).
  accepted?: () => Accepted;
};

/// One member's connection: the credential first, nothing served before it checks out; then a request a stream.
export async function serve(m: Members, conn: Connection) {
  if (m.cloud.removed()) {
    conn.close(2, "station_removed");
    throw new Error("station removed");
  }
  const device = conn.remoteId();
  const first = await conn.acceptBi();
  if (!first) return;
  const credentials = new Reader(first);
  const state = () => m.cloud.state!;
  const check = (line: any) => verifyMember(typeof line?.credential === "string" ? line.credential : "", state().grant_keys, workspaceIds(state()), device, state().revocations, m.accepted?.());
  const hello = await credentials.line();
  if (hello === null) throw new Error("no credential");
  let current: Admitted;
  try {
    current = check(hello);
  } catch (e) {
    await writeLine(first, { error: (e as Error).message }).catch(() => {});
    await first.finish().catch(() => {});
    wall.after(200, () => conn.close(1, "credential_refused"));
    throw e;
  }
  const protocol = Number.isInteger(hello.protocol) && hello.protocol >= 0 ? hello.protocol : 1;
  if (protocol < MIN_CLIENT_PROTOCOL) {
    await writeLine(first, {
      code: "client_upgrade_required",
      error: "Please update still.fail to the latest version, or reload the web page, before connecting to this station.",
      required_protocol: MIN_CLIENT_PROTOCOL,
      update_url: "https://still.fail",
    });
    await first.finish().catch(() => {});
    wall.after(200, () => conn.close(4, "client_upgrade_required"));
    throw new Error("client upgrade required");
  }
  await writeLine(first, { ok: true, station: state().name, expires_at: current.exp });
  log.info("mesh", "client connected", { email: current.viewer.email, device: device.slice(0, 12) });

  // The connection ends when its credential runs out or is revoked, or the station leaves its workspace: checked on
  // every change of the cloud's state, and when the credential runs out.
  const gone = () => {
    if (m.cloud.removed()) conn.close(2, "station_removed");
    else if (revoked(current, state().revocations)) conn.close(3, "credential_revoked");
    else if (current.exp <= nowSecs()) conn.close(3, "credential_expired");
    else return false;
    return true;
  };
  // A credential's expiry is the cloud's word, in the machine's time.
  let expiry: (() => void) | undefined;
  const watchExpiry = () => {
    expiry?.();
    expiry = wall.after(Math.max(0, current.exp * 1000 - wall.now()) + 50, () => void (gone() || watchExpiry()));
  };
  watchExpiry();
  const unlisten = m.cloud.listen(gone);
  // Renewals on the credential stream.
  (async () => {
    for (let line = await credentials.line().catch(() => null); line !== null; line = await credentials.line().catch(() => null)) {
      let reply;
      try {
        current = check(line);
        watchExpiry();
        reply = { ok: true, expires_at: current.exp };
      } catch (e) {
        reply = { error: (e as Error).message };
      }
      await writeLine(first, reply).catch(() => {});
    }
  })();

  try {
    for (let stream = await conn.acceptBi(); stream; stream = await conn.acceptBi()) {
      if (gone()) return;
      const viewer = current.viewer;
      request(m, stream, viewer, conn).catch((e) => log.info("mesh", "request failed", { error: (e as Error).message }));
    }
  } finally {
    expiry?.();
    unlisten();
  }
}

/// One request: to the admin API in this process.
async function request(m: Members, raw: Stream, viewer: Admitted["viewer"], conn: Connection) {
  const accepted = { wall: wall.now(), at: process.hrtime.bigint() };
  const firstReader = new Reader(raw);
  const head = await firstReader.line();
  if (head === null) return;
  const method: string = typeof head.method === "string" ? head.method.toUpperCase() : "GET";
  const path: string = typeof head.path === "string" ? head.path : "";
  // A span of the caller's trace when it records one: from the stream's acceptance to its answer's last byte (an
  // event stream's, a socket's or a phone's offer: to its head). The admin API's goes under ours.
  const traced = tracing(m.traces, head, method, path, conn.via(), accepted, raw, firstReader.carry.length);
  const stream = traced.stream;
  const reader = firstReader;
  reader.stream = stream;
  try {
    await answerRequest(m, stream, reader, head, method, path, viewer, conn);
    traced.end(null);
  } catch (error) {
    traced.end(error as Error);
    throw error;
  }
}

/// A request's span while it runs, and the stream it is answered on, counted: what the head line said (status, a
/// stream or not), how much came and went.
function tracing(traces: Traces | undefined, head: any, method: string, path: string, via: string | null, accepted: { wall: number; at: bigint }, stream: Stream, carried: number) {
  const theirs = typeof head.headers?.traceparent === "string" ? head.headers.traceparent : undefined;
  let span = traces?.start(parseParent(theirs)) ?? null;
  if (span === null || traces === undefined) return { stream, end: (_: Error | null) => {} };
  // Started when the stream was accepted, not when its head was read.
  span = { ...span, wallNs: BigInt(accepted.wall) * 1_000_000n, started: accepted.at };
  head.headers = { ...(head.headers ?? {}), traceparent: Traces.traceparent(span) };
  const outcome = { status: 0, received: carried, sent: 0, headSeen: false };
  const end = (streamed: boolean, error: Error | null) => {
    if (span === null) return;
    const attributes: [string, unknown][] = [
      ["http.request.method", method],
      ["url.path", route(path)],
      ["http.response.status_code", outcome.status],
      ["http.request.body.size", outcome.received],
    ];
    attributes.push(streamed ? ["stillfail.stream", true] : ["http.response.body.size", outcome.sent]);
    if (via !== null) attributes.push(["stillfail.path", via]);
    if (error !== null) attributes.push(["error.type", error.message]);
    traces.end(span, `${method} ${route(path)}`, attributes, error !== null || outcome.status >= 500);
    span = null;
  };
  const counted: Stream = {
    read: async () => {
      const more = await stream.read();
      if (more) outcome.received += more.length;
      return more;
    },
    write: async (bytes) => {
      await stream.write(bytes);
      if (!outcome.headSeen) {
        outcome.headSeen = true;
        const line = bytes.subarray(0, bytes.indexOf(10) < 0 ? bytes.length : bytes.indexOf(10));
        try {
          const said = JSON.parse(line.toString());
          outcome.status = Number(said.status) || 0;
          const type = String(said.headers?.["content-type"] ?? "");
          if (outcome.status === 101 || type.startsWith("text/event-stream") || type.startsWith("application/x-ndjson")) end(true, null);
        } catch {}
        outcome.sent += bytes.length - line.length - 1;
      } else outcome.sent += bytes.length;
    },
    finish: () => stream.finish(),
    stopped: () => stream.stopped(),
    reset: (code) => stream.reset(code),
  };
  return { stream: counted, end: (error: Error | null) => end(false, error) };
}

async function answerRequest(m: Members, stream: Stream, reader: Reader, head: any, method: string, path: string, viewer: Admitted["viewer"], conn: Connection) {
  const answer = async (status: number, body: unknown) => {
    await writeLine(stream, { status, headers: { "content-type": "application/json" } });
    await stream.write(Buffer.from(typeof body === "string" ? body : JSON.stringify(body)));
    await stream.finish();
  };
  if (!path.startsWith("/admin/api/") || path.includes("..")) {
    return answer(404, '{"error":"only the admin API is reachable over the mesh"}');
  }
  // A phone lent to the agents, or asked about (adb.ts): its send side came finished, what it hears goes down the stream.
  if (head.adb !== null && typeof head.adb === "object" && !Array.isArray(head.adb)) {
    // Lending a phone is a change a read-only member does not make.
    if (readOnly(viewer)) return answer(403, { error: "read-only members cannot lend or use phones" });
    return answerAdb(m.shares, conn, viewer, head, stream, reader);
  }
  // A preview page's WebSocket (`"socket": true`): no body to wait for, the stream carries its messages both ways.
  if (head.socket === true) {
    // A preview's socket carries whatever its page sends: no viewer's.
    if (readOnly(viewer)) return answer(403, { error: "read-only members cannot change this station" });
    return socket(m, stream, reader, head, path);
  }
  const body = await reader.rest();
  // The caller's headers go on, but not those of the hop, nor any of the station's own: who is asking is only what
  // the credential says.
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(head.headers ?? {})) {
    const lower = name.toLowerCase();
    if (HOP.includes(lower) || lower.startsWith("x-stillfail-") || lower.startsWith("x-ember-") || lower === "traceparent" || lower === "tracestate") continue;
    if (typeof value === "string") headers[name] = value;
  }
  if (!m.up()) return answer(502, { error: "station unreachable: not started" });
  const rest = path.slice("/admin/api".length);
  const at = rest.indexOf("?");
  const response = await m.admin.handle({
    method,
    path: at < 0 ? rest : rest.slice(0, at),
    query: at < 0 ? [] : queryPairs(rest.slice(at + 1)),
    search: at < 0 ? "" : rest.slice(at),
    headers,
    body,
    viewer,
    lang: langOfCore(headers),
  });
  await writeLine(stream, { status: response.status, headers: response.headers });
  if (Buffer.isBuffer(response.body)) await stream.write(response.body);
  else {
    // A stream (GET /events) ends when the caller stops reading or goes, even while nothing is being written to it.
    const chunks = response.body[Symbol.asyncIterator]();
    const end = () => void chunks.return?.();
    stream.stopped().then(end, end);
    try {
      for (;;) {
        const next = await chunks.next();
        if (next.done) break;
        await stream.write(next.value);
      }
    } finally {
      end();
    }
  }
  await stream.finish();
}

/// A WebSocket of a web service on this machine, for a preview's page (preview.ts `openSocket`): answered 101 once the
/// service took it, then its messages framed both ways until either side closes. Only a preview's path is opened.
async function socket(m: Members, stream: Stream, reader: Reader, head: any, path: string) {
  const refuse = async (status: number, error: string) => {
    await writeLine(stream, { status, headers: { "content-type": "application/json" } });
    await stream.write(Buffer.from(JSON.stringify({ error })));
    await stream.finish();
  };
  const rest = path.slice("/admin/api".length);
  const at = rest.indexOf("?");
  const target = previewTarget(at < 0 ? rest : rest.slice(0, at));
  if (target === null) return refuse(404, "only a preview's WebSocket is opened over the mesh");
  if (!m.up()) return refuse(502, "station unreachable: not started");
  const headers = Object.entries(head.headers ?? {}).flatMap(([k, v]): [string, string][] => (typeof v === "string" ? [[k.toLowerCase(), v]] : []));
  const lang = langOfCore(Object.fromEntries(headers));
  let service;
  try {
    service = await openSocket(headers, target[0], target[1] + (at < 0 ? "" : rest.slice(at)), lang);
  } catch (error) {
    return refuse(error instanceof SocketRefused ? error.status : 502, (error as Error).message);
  }
  await writeLine(stream, { status: 101, headers: service.protocol === null ? {} : { "sec-websocket-protocol": service.protocol } });
  // What came with the head line is the first of the client's frames.
  await pumpSocket(service, new FrameReader(stream, reader.carry), stream);
}
