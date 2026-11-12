// Comma's direct connections (`comma/mesh/1`, the @comma/mesh package): a Comma client core reaches this station on
// the station's own iroh endpoint. The member credential is the one the Comma protocol takes (credential.ts), and
// each request goes to the admin API as that member; its path is the admin API's (`/sessions`, `/threads/7/messages`).
// A desktop's own station serves its owner alone (serveDeviceComma): its screens (mesh/screens.ts) and its overview.
// The package adapts the native endpoint's connections (`@comma/mesh/station-native`); this file says what is served.
import { MESH_ALPN, MeshError, type Headers, type MeshReply, type MeshServerOptions, serveMeshConnection } from "@comma/mesh";
import { nativeConnection } from "@comma/mesh/station-native";
import { langOfCore, queryPairs } from "../api/request.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { workspaceIds } from "../cloud/state.ts";
import { type Admitted, revoked, verifyMember } from "./credential.ts";
import type { DeviceMeshAdmissions } from "./device-mesh.ts";
import { watchQuiet } from "./gone.ts";
import type { ScreenViews } from "./screens.ts";
import type { LinkStats } from "./screen-timing.ts";
import type { Connection } from "./native.ts";
import type { Members } from "./serve.ts";

export const COMMA_ALPN = Buffer.from(MESH_ALPN);
/// Headers of one hop, not of what is relayed.
const HOP = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "host", "content-length"];
const MAX_BODY = 64 * 1024 * 1024;

/// One Comma client's connection, served until it closes.
export async function serveComma(m: Members, native: Connection): Promise<void> {
  if (m.cloud.removed()) {
    native.close(2, "station_removed");
    return;
  }
  const state = () => m.cloud.state!;
  await serveMeshConnection<Admitted>(nativeConnection(native), {
    verify: async (credential, peer) => {
      try {
        const admitted = verifyMember(credential, state().grant_keys, workspaceIds(state()), peer, state().revocations, m.accepted?.());
        log.info("mesh", "comma client connected", { email: admitted.viewer.email, device: peer.slice(0, 12) });
        return { principal: admitted, expiresAtMs: admitted.exp * 1000 };
      } catch (e) {
        throw new MeshError("unauthorized", (e as Error).message);
      }
    },
    handle: (request) => {
      // Checked at each request: the station left its workspace, or the member's credential was revoked since.
      if (m.cloud.removed()) return Promise.resolve(json(410, { error: "station removed" }));
      if (revoked(request.principal, m.cloud.state!.revocations)) return Promise.resolve(json(401, { error: "credential revoked" }));
      return answer(m, request.principal, request.method, request.path, request.headers, request.body, request.signal);
    },
    // A credential's expiry is the cloud's word, in the machine's time.
    now: () => wall.now(),
    onError: (error) => log.info("mesh", "comma request failed", { error: (error as Error)?.message ?? String(error) }),
  });
}

/// What a desktop's station serves its owner on the mesh, until each further route is decided for a computer. The
/// admin API is one for the whole machine, across every Workspace the app is signed in to.
const servedToOwner = (method: string, path: string) => method.toUpperCase() === "GET" && path.split("?")[0] === "/overview";

/// What a client's connection to a desktop's own station is served by (device-mesh.ts): its owner, and no one else.
/// `via`: how that connection runs now (a screen's view goes by it); `link`: what the native mesh says of it (a view's
/// frames' times, screen-timing.ts); `open`: counts the streamed answers under way on it (a screen's views), for
/// gone.ts `watchQuiet`.
export function deviceServing(m: Pick<Members, "admin" | "up"> & { screens?: ScreenViews }, admissions: DeviceMeshAdmissions, admitted: (member: Admitted) => void = () => {}, via: () => string | null = () => null, link: () => LinkStats | null = () => null, open: { streams: number } = { streams: 0 }): Omit<MeshServerOptions<Admitted>, "endpoint"> {
  return {
    verify: async (credential, peer) => {
      try {
        const member = admissions.admit(credential, peer);
        admitted(member);
        log.info("mesh", "this computer's owner connected", { device: peer.slice(0, 12) });
        return { principal: member, expiresAtMs: member.exp * 1000 };
      } catch (e) {
        throw new MeshError("unauthorized", (e as Error).message);
      }
    },
    handle: async (request) => {
      if (!admissions.holds(request.principal)) return json(401, { error: "credential revoked" });
      // A screen's view is its own: both sides send for as long as it lasts, where `answer` reads a request's body first.
      const screen = m.screens?.handle(request.principal, request, via, link);
      if (screen) return counted(await screen, open);
      if (!servedToOwner(request.method, request.path)) return json(403, { error: "not served to this computer over the mesh" });
      return answer(m, request.principal, request.method, request.path, request.headers, request.body, request.signal);
    },
    now: () => wall.now(),
    onError: (error) => log.info("mesh", "comma request failed", { error: (error as Error)?.message ?? String(error) }),
  };
}

/// What the native mesh says of a connection now, only what its addon has: its chosen path's, and the connection's.
export function linkOf(native: Pick<Connection, "paths" | "stats">): LinkStats | null {
  try {
    const path = native.paths?.().find((p) => p.selected);
    const stats = native.stats?.();
    if (!path && !stats) return null;
    return {
      ...(path ? { rttMs: Math.round(path.rttMs * 10) / 10, ...(path.cwnd !== undefined ? { cwnd: path.cwnd, congestionEvents: path.congestionEvents, sentDatagrams: path.sentDatagrams, lostPackets: path.lostPackets } : {}) } : {}),
      ...(stats ? { txBytes: stats.txBytes, rxBytes: stats.rxBytes, lost: stats.lostPackets } : {}),
    };
  } catch {
    // It went.
    return null;
  }
}

/// Says in the station's log how a connection runs, each time that changes: direct, relay or salix.
async function logPath(native: Connection): Promise<void> {
  if (!native.nextVia) return;
  let via: string | null = null;
  try {
    for (;;) {
      const next = await native.nextVia(via);
      if (next.closed) return;
      if (next.via !== via) log.info("mesh", "a client's path", { via: next.via, device: native.remoteId().slice(0, 12) });
      via = next.via;
    }
  } catch {
    // It went.
  }
}

/// `reply`, its body counted in `open` while it streams.
function counted(reply: MeshReply, open: { streams: number }): MeshReply {
  const body = reply.body;
  if (body === undefined || body === null || body instanceof Uint8Array) return reply;
  return {
    ...reply,
    body: (async function* () {
      open.streams += 1;
      try {
        yield* body;
      } finally {
        open.streams -= 1;
      }
    })(),
  };
}

/// One client's connection, until it closes, or as soon as what its run says no longer admits it. One gone with a view
/// open on it is closed (gone.ts `watchQuiet`).
export async function serveDeviceComma(m: Pick<Members, "admin" | "up"> & { screens?: ScreenViews }, admissions: DeviceMeshAdmissions, native: Connection): Promise<void> {
  let current: Admitted | null = null;
  const stop = admissions.listen(() => {
    if (current && !admissions.holds(current)) native.close(3, "credential_revoked");
  });
  const open = { streams: 0 };
  const unwatch = watchQuiet(native, () => open.streams > 0, (ms, f) => wall.every(ms, f));
  void logPath(native);
  try {
    await serveMeshConnection<Admitted>(nativeConnection(native), deviceServing(m, admissions, (member) => (current = member), () => native.via(), () => linkOf(native), open));
  } finally {
    unwatch();
    stop();
  }
}

const json = (status: number, body: unknown): MeshReply => ({ status, headers: [["content-type", "application/json"]], body: Buffer.from(JSON.stringify(body)) });

async function answer(m: Pick<Members, "admin" | "up">, admitted: Admitted, method: string, path: string, given: Headers, body: AsyncIterable<Uint8Array>, signal: AbortSignal): Promise<MeshReply> {
  if (!path.startsWith("/") || path.includes("..")) return json(404, { error: "no such path" });
  if (!m.up()) return json(502, { error: "station unreachable: not started" });
  const parts: Buffer[] = [];
  let size = 0;
  for await (const chunk of body) {
    size += chunk.length;
    if (size > MAX_BODY) return json(413, { error: "request body too large" });
    parts.push(Buffer.from(chunk));
  }
  // The caller's headers go on, but not those of the hop, nor any of the station's own: who is asking is only what
  // the credential says.
  const headers: Record<string, string> = {};
  for (const [name, value] of given) {
    const lower = name.toLowerCase();
    if (HOP.includes(lower) || lower.startsWith("x-comma-station-") || lower.startsWith("x-ember-")) continue;
    headers[name] = value;
  }
  const at = path.indexOf("?");
  const response = await m.admin.handle({
    method: method.toUpperCase(),
    path: at < 0 ? path : path.slice(0, at),
    query: at < 0 ? [] : queryPairs(path.slice(at + 1)),
    search: at < 0 ? "" : path.slice(at),
    headers,
    body: Buffer.concat(parts, size),
    viewer: admitted.viewer,
    lang: langOfCore(headers),
  });
  const replyHeaders: Headers = Object.entries(response.headers).map(([k, v]) => [k, String(v)]);
  if (Buffer.isBuffer(response.body)) return { status: response.status, headers: replyHeaders, body: response.body };
  // A stream (GET /events) ends when the client gives the request up, even while nothing is being written to it.
  const chunks = response.body[Symbol.asyncIterator]();
  const end = () => void chunks.return?.();
  signal.addEventListener("abort", end, { once: true });
  return {
    status: response.status,
    headers: replyHeaders,
    body: (async function* () {
      try {
        for (;;) {
          const next = await chunks.next();
          if (next.done) return;
          yield next.value as Uint8Array;
        }
      } finally {
        end();
      }
    })(),
  };
}
