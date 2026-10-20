// The presence socket to the control plane (the Rust station's main.rs `presence`, `connect`, `apply_state`): open while
// the station answers is the station online; the cloud pushes on it where the station is, its relays and roster, and
// what it takes back. Signed at connect like enrollment. Reconnects with backoff; once removed from its workspace, asks
// again only now and then, or at once when enrolled anew meanwhile. Which control plane, and how it is spoken to, is
// the provider's (provider.ts), read anew at every connect.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Clock, Effect, Stream, SubscriptionRef } from "effect";
import WebSocket from "ws";
import { log } from "../ops/log.ts";
import { nowSecs } from "../ops/files.ts";
import { version } from "../ops/version.ts";
import type { Cloud as CloudState, Revocation } from "./state.ts";
import type { StationKey } from "./key.ts";
import { type ProviderSpec, signedHeaders } from "./provider.ts";
import { wall } from "../ops/fibers.ts";

/// The cloud expects a "ping" this often and drops a station silent for three of them.
const PING_MS = 30_000;
/// How the cloud closes the socket of a station removed from its workspace.
const CLOSE_REMOVED = 4004;
const REMOVED_RETRY_MS = 600_000;
const CONNECT_TIMEOUT_MS = 20_000;

/// REMOVED_RETRY, or STILLFAIL_REMOVED_RETRY_SECS (tests against a dev cloud).
function removedRetry(): number {
  const secs = Number(process.env.STILLFAIL_REMOVED_RETRY_SECS?.trim());
  return Number.isFinite(secs) && secs > 0 ? secs * 1000 : REMOVED_RETRY_MS;
}

/// Whether the station is online at still.fail cloud, and since when or why not: <data>/run/presence.json, for
/// `stillfail status`.
function writePresence(data: string, online: boolean, error: string | null) {
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run", "presence.json"), JSON.stringify({ online, at: nowSecs(), error }) + "\n");
}

/// What the presence socket is given: cloud.json and its changes, the key, whether the station answers, and the
/// provider it is enrolled with.
export type PresenceParts = {
  cloud: { state: CloudState; changes: Stream.Stream<void> };
  key: StationKey;
  up: SubscriptionRef.SubscriptionRef<boolean>;
  spec: () => ProviderSpec;
};

/// Keeps the socket for good (until interrupted): open while the station is up.
export const presence = ({ cloud, key, up, spec }: PresenceParts) => Effect.gen(function* () {
  const until = (wanted: boolean) => SubscriptionRef.changes(up).pipe(Stream.filter((now) => now === wanted), Stream.runHead);
  let backoff = 1000;
  for (;;) {
    if (!(yield* SubscriptionRef.get(up))) {
      yield* until(true);
      backoff = 1000;
    }
    const s = cloud.state;
    s.reload();
    if (s.removed()) {
      const retry = removedRetry();
      const every = retry === REMOVED_RETRY_MS ? "every 10 minutes" : `every ${retry / 1000} s`;
      writePresence(s.data, false, `removed from its workspace; the cloud is asked again ${every}`);
      // Enrolled again meanwhile (the file changes): ask at once.
      yield* Effect.raceFirst(Effect.sleep(retry), cloud.changes.pipe(Stream.filter(() => !s.removed()), Stream.runHead));
    }
    const started = yield* Clock.currentTimeMillis;
    s.peersCurrent = false;
    const plane = spec();
    // The socket, until it ends or the station stops answering (then it is closed: offline at the cloud).
    const ended = yield* Effect.result(Effect.raceFirst(connect(s, key, plane), Effect.as(until(false), `station not answering; went offline at ${plane.name}`)));
    s.peersCurrent = false;
    const why = ended._tag === "Success" ? ended.success : ended.failure.message;
    writePresence(s.data, false, why);
    if (ended._tag === "Success") log.info("presence", why);
    else log.warn("presence", `no presence socket to ${plane.name}`, { error: why });
    // A socket that held a while starts over quickly; failing again and again backs off to a minute.
    if ((yield* Clock.currentTimeMillis) - started > 60_000) backoff = 1000;
    yield* Effect.sleep(backoff);
    backoff = Math.min(backoff * 2, 60_000);
  }
});

/// One socket, signed at connect like enrollment: succeeds with why it ended when the cloud closes it, fails when it
/// can't be had or breaks; closed when interrupted.
const connect = (s: CloudState, key: StationKey, plane: ProviderSpec) =>
  Effect.callback<string, Error>((resume) => {
    const state = s.state!;
    const ts = nowSecs();
    // New clouds read the canonical proof; old clouds their original one.
    const headers = signedHeaders(plane.connectPrefixes, state.station, ts, (prefix) => key.sign(`${prefix}-station-connect-v1:${state.origin}:${state.station}:${ts}`), { version: version() });
    const socket = new WebSocket(`${state.origin.replace("http", "ws")}${plane.connectPath}`, { headers, handshakeTimeout: CONNECT_TIMEOUT_MS });
    let ping: (() => void) | undefined;
    let unreach: (() => void) | undefined;
    let answered = true;
    let failed: Error | null = null;
    socket.on("unexpected-response", (_, response) => {
      if (response.statusCode === 404) {
        removed(s, 404);
        failed = new Error("station removed");
      } else {
        failed = new Error(`${plane.name} answered ${response.statusCode}`);
      }
      socket.terminate();
    });
    socket.on("error", (error) => (failed ??= error));
    socket.on("open", () => {
      takenBack(s, plane);
      writePresence(s.data, true, null);
      log.info("presence", `online at ${plane.name}`);
      // The cloud's answering is in the machine's time.
      ping = wall.every(PING_MS, () => {
        // No pong since the last ping: gone even if the socket has not noticed.
        if (!answered) {
          failed = new Error(`${plane.name} stopped answering`);
          socket.terminate();
          return;
        }
        answered = false;
        socket.send("ping");
      });
      // Where the mesh endpoint may be reached: now, and again whenever that changes (hints for its peers and members).
      if (plane.reach) {
        const reach = () => {
          const r = s.reach;
          if (r !== null && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "reach", home_relay: r.homeRelay, addrs: r.addrs }));
        };
        reach();
        unreach = s.onReach(reach);
      }
    });
    socket.on("message", (data, binary) => {
      if (binary) return;
      const text = data.toString();
      if (text === "pong") answered = true;
      else if (!tool(s, plane, socket, text)) applyState(s, text);
    });
    socket.on("close", (code) => {
      ping?.();
      unreach?.();
      if (code === CLOSE_REMOVED) removed(s, CLOSE_REMOVED);
      resume(failed ? Effect.fail(failed) : Effect.succeed(`${plane.name} closed the presence socket`));
    });
    return Effect.sync(() => {
      ping?.();
      unreach?.();
      socket.close();
    });
  });

/// A device tool request pushed on the socket (`{type: "tool", id, request}`, contract §8 presence transport): run
/// by the mesh's tools and answered `{type: "tool_result", id, response}`. Only a provider with device tools pushes
/// them; anything else is not a tool frame.
function tool(s: CloudState, plane: ProviderSpec, socket: WebSocket, text: string): boolean {
  if (!text.startsWith('{"type":"tool"')) return false;
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    return false;
  }
  if (body?.type !== "tool" || typeof body.id !== "string") return false;
  const run = plane.tools ? s.toolCalls : null;
  const reply = (response: unknown) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "tool_result", id: body.id, response }));
  };
  if (run === null) reply({ ok: false, error: { code: "unavailable", message: "this station takes no device tools now" } });
  else run(body.request).then(reply, (e) => reply({ ok: false, error: { code: "invalid_request", message: (e as Error).message } }));
  return true;
}

/// The cloud says the station is out of its workspace: marked in cloud.json, kept through restarts.
function removed(s: CloudState, code: number) {
  if (s.removed()) return;
  log.warn("presence", "this station was removed from its workspace; it stops its work and refuses connections", { code });
  s.update((st) => {
    st.removed_at = nowSecs();
    st.removed_code = code;
  });
}

/// The cloud took the socket: a station it had removed is in its workspace again.
function takenBack(s: CloudState, plane: ProviderSpec) {
  if (!s.removed()) return;
  log.info("presence", `${plane.name} takes this station again; back to work`);
  s.update((st) => {
    delete st.removed_at;
    delete st.removed_code;
  });
}

/// What the cloud pushes: where the station is and what it is called, its relays, roster and grant keys, what it
/// takes back.
export function applyState(s: CloudState, text: string) {
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    return;
  }
  if (body?.type === "state") {
    // Current before it is told, so whoever hears of the new roster reads it as current.
    s.peersCurrent = Array.isArray(body.peers);
    s.update((st) => {
      for (const k of ["workspace", "workspace_name", "name", "origin", "relay_url"] as const) {
        if (typeof body[k] === "string") st[k] = body[k];
      }
      // The ids the workspace had before go with the id it has now: a frame that names a workspace and none before it
      // says there were none (state.ts `workspaceKey`: a rename, or another workspace).
      if (typeof body.workspace === "string") {
        const was = Array.isArray(body.workspace_was) ? body.workspace_was.filter((w: unknown): w is string => typeof w === "string" && w !== "") : [];
        if (was.length > 0) st.workspace_was = was;
        else delete st.workspace_was;
      }
      // Missing roster means an old cloud: never keep peers from another binding.
      st.peers = Array.isArray(body.peers) ? body.peers : [];
      if (Array.isArray(body.relay_urls)) st.relay_urls = body.relay_urls.filter((u: unknown) => typeof u === "string");
      if (body.grant_keys && typeof body.grant_keys === "object" && !Array.isArray(body.grant_keys)) st.grant_keys = body.grant_keys;
      if (Array.isArray(body.revocations) && body.revocations.every(isRevocation)) st.revocations = body.revocations;
      // Who may call the device tools (Comma's gateways): only from a control plane that names them.
      if (Array.isArray(body.gateway_keys)) st.gateway_keys = body.gateway_keys.filter((k: unknown): k is string => typeof k === "string");
    });
  } else if (body?.type === "revoke" && isRevocation(body)) {
    s.update((st) => {
      st.revocations = st.revocations.filter((r) => !(r.kind === body.kind && r.id === body.id));
      st.revocations.push({ kind: body.kind, id: body.id, at: body.at });
    });
  }
}

const isRevocation = (r: any): r is Revocation => typeof r?.kind === "string" && typeof r?.id === "string" && Number.isInteger(r?.at) && r.at >= 0;
