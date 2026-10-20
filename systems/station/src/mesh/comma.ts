// Comma's direct connections (`comma/mesh/1`, the @comma/mesh package): a Comma client core reaches this station on
// the station's own iroh endpoint. The member credential is the one the still.fail protocol takes (credential.ts), and
// each request goes to the admin API as that member; its path is the admin API's (`/sessions`, `/threads/7/messages`).
// The package adapts the native endpoint's connections (`@comma/mesh/station-native`); this file says what is served.
import { MESH_ALPN, MeshError, type Headers, type MeshReply, serveMeshConnection } from "@comma/mesh";
import { nativeConnection } from "@comma/mesh/station-native";
import { langOfCore, queryPairs } from "../api/request.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { workspaceIds } from "../cloud/state.ts";
import { type Admitted, revoked, verifyMember } from "./credential.ts";
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
    handle: (request) => answer(m, request.principal, request.method, request.path, request.headers, request.body, request.signal),
    // A credential's expiry is the cloud's word, in the machine's time.
    now: () => wall.now(),
    onError: (error) => log.info("mesh", "comma request failed", { error: (error as Error)?.message ?? String(error) }),
  });
}

const json = (status: number, body: unknown): MeshReply => ({ status, headers: [["content-type", "application/json"]], body: Buffer.from(JSON.stringify(body)) });

async function answer(m: Members, admitted: Admitted, method: string, path: string, given: Headers, body: AsyncIterable<Uint8Array>, signal: AbortSignal): Promise<MeshReply> {
  // Checked at each request: the station left its workspace, or the member's credential was revoked since.
  if (m.cloud.removed()) return json(410, { error: "station removed" });
  if (revoked(admitted, m.cloud.state!.revocations)) return json(401, { error: "credential revoked" });
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
    if (HOP.includes(lower) || lower.startsWith("x-stillfail-") || lower.startsWith("x-ember-")) continue;
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
