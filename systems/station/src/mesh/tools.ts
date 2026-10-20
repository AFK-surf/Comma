// The device tools (contract v1 §8), over the presence socket (`presenceTools`) or on the mesh: ALPN `comma/tools/1`, admitted only from the iroh ids the control
// plane names as its gateways (`gateway_keys`, cloud.json, as the presence socket said last). One request a stream,
// framed as `stillfail/admin/1` is: a JSON head line `{op, id, context, args}` (any body after it is read and left), answered
// by one JSON line `{ok: true, result}` or `{ok: false, error: {code, message}}`. What an op may do is the station's
// `tools.access` (src/device/tools.ts), read at each request. The chats it starts and drives are the pages' own: made and
// said through the admin API, as the person it names.
import { Effect } from "effect";
import type { Admin } from "../api/admin.ts";
import { type Cloud, workspaceIds } from "../cloud/state.ts";
import { type Access, type DeviceTools, type Sessions, ToolError } from "../device/tools.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import type { Store } from "../store/store.ts";
import type { Viewer } from "./credential.ts";
import type { Connection } from "./native.ts";
import { Reader, writeLine } from "./serve.ts";

export const TOOLS_ALPN = Buffer.from("comma/tools/1");
/// A request's line holds its arguments (an fs.write's content, a long prompt): up to 12 MiB (contract §8).
export const MAX_TOOLS_LINE = 12 * 1024 * 1024;

export type ToolsDeps = {
  cloud: Cloud;
  tools: DeviceTools;
  access(): Access;
  /// Whether the station's provider has gateways at all (cloud/provider.ts `tools`).
  enabled(): boolean;
};

/// Why `peer` may not call the tools now, or null when it may.
export function refusal(d: ToolsDeps, peer: string): string | null {
  const s = d.cloud.state;
  if (!d.enabled() || s === null) return "this station takes no device tools";
  if (d.cloud.removed()) return "station removed";
  if (!(s.gateway_keys ?? []).includes(peer)) return "not a gateway of this station's control plane";
  return null;
}

/// One request (`{op, id, context, args}`) answered as `{ok: true, result}` or `{ok: false, error: {code, message}}`.
/// `refused` says why the caller may not call now, or null; read at each request.
async function answer(d: ToolsDeps, head: any, refused: () => string | null): Promise<unknown> {
  try {
    const still = refused();
    if (still !== null) throw new ToolError({ code: "forbidden", message: still });
    if (head === null || typeof head !== "object" || typeof head.op !== "string") throw new ToolError({ code: "invalid_request", message: "a request names its op" });
    const args = head.args !== null && typeof head.args === "object" && !Array.isArray(head.args) ? head.args : {};
    const context = head.context !== null && typeof head.context === "object" ? head.context : {};
    // For this station's workspace only (contract §8), by any id it goes or went by: another's, or none said, is refused.
    if (d.cloud.state === null || !workspaceIds(d.cloud.state).includes(context.workspace)) throw new ToolError({ code: "forbidden", message: "the request is for another workspace than this station's" });
    const result = await Effect.runPromise(Effect.result(d.tools.run(head.op, args, context, d.access())));
    log.info("tools", "device tool", { op: head.op, id: typeof head.id === "string" ? head.id : null, ok: result._tag === "Success", agent: context.agent ?? null });
    return result._tag === "Success" ? { ok: true, result: result.success } : { ok: false, error: { code: result.failure.code, message: result.failure.message } };
  } catch (e) {
    const code = e instanceof ToolError ? e.code : "invalid_request";
    return { ok: false, error: { code, message: (e as Error).message } };
  }
}

/// A gateway's connection: each of its streams one op, while it is a gateway.
export async function serveTools(d: ToolsDeps, conn: Connection) {
  const peer = conn.remoteId();
  const refused = refusal(d, peer);
  if (refused !== null) {
    conn.close(1, "not_a_gateway");
    throw new Error(refused);
  }
  for (let stream = await conn.acceptBi(); stream; stream = await conn.acceptBi()) {
    void (async () => {
      const reader = new Reader(stream, MAX_TOOLS_LINE);
      let reply: unknown;
      try {
        const head = await wall.within(120_000, reader.line(), "tools request timed out");
        reply = await answer(d, head, () => refusal(d, peer));
      } catch (e) {
        reply = { ok: false, error: { code: "invalid_request", message: (e as Error).message } };
      }
      await writeLine(stream, reply);
      await stream.finish();
    })().catch((e) => log.info("tools", "tools stream ended", { error: (e as Error).message }));
  }
}

/// The same requests over the presence socket (contract §8, presence transport): Comma pushes them on the socket the
/// station signed into, so being on it is the admission; the station's access setting and workspace still decide.
export function presenceTools(d: ToolsDeps): (request: unknown) => Promise<unknown> {
  return (request) =>
    answer(d, request, () => {
      if (!d.enabled() || d.cloud.state === null) return "this station takes no device tools";
      if (d.cloud.removed()) return "station removed";
      return null;
    });
}

/// The station's chats for the tools, made and said through the admin API as the pages make them.
export function adminSessions(admin: () => Admin, store: () => Store | null, runtimes: () => string[], workspace: () => string, gateway: string): Sessions {
  const as = (email: string): Viewer => ({ sub: "", email, name: "", role: "member", workspace: workspace(), device: gateway });
  const ask = async (viewer: Viewer, method: string, path: string, body: unknown) => {
    const answer = await admin().handle({ method, path, query: [], search: "", headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(body)), viewer, lang: "en" });
    const parts: Buffer[] = [];
    if (Buffer.isBuffer(answer.body)) parts.push(answer.body);
    else for await (const chunk of answer.body) parts.push(Buffer.from(chunk));
    const text = Buffer.concat(parts).toString("utf8");
    let value: any = null;
    try {
      value = JSON.parse(text);
    } catch {}
    if (answer.status >= 300) throw Object.assign(new Error(typeof value?.error === "string" ? value.error : `the station answered ${answer.status}`), { code: answer.status === 404 ? "not_found" : answer.status === 403 ? "forbidden" : "failed" });
    return value;
  };
  return {
    start: async ({ prompt, title, runtime, model, effort, requester }) => {
      const viewer = as(requester);
      const which = runtime ?? (runtimes().includes("claude") ? "claude" : "codex");
      const made = await ask(viewer, "POST", "/sessions", { runtime: which, ...(title !== null ? { title } : {}), ...(model ? { model } : {}), ...(effort ? { effort } : {}) });
      const thread = String(made?.thread?.id ?? made?.thread?.thread ?? "");
      if (thread === "") throw new Error("the chat was made without a thread");
      await ask(viewer, "POST", `/threads/${thread}/messages`, { text: prompt, client: "comma tools" });
      return { session: String(made.key), thread };
    },
    say: async ({ thread, text, requester }) => {
      await ask(as(requester), "POST", `/threads/${encodeURIComponent(thread)}/messages`, { text, client: "comma tools" });
    },
    status: (thread) => {
      const s = store();
      const id = Number(thread);
      if (s === null || !Number.isInteger(id) || s.getThread(id) === null) return null;
      const keys = s.threadSessions(id).map((m) => m.session);
      const turns = keys.map((k) => s.lastTurn(k)).filter((t) => t !== null);
      if (turns.some((t) => t.endedAt === null)) return { state: "running" };
      const last = turns.sort((a, b) => b.startedAt - a.startedAt)[0];
      if (last === undefined) return { state: "idle" };
      const said = last.declared ?? last.ending ?? "";
      const summary = last.detail ?? last.need ?? undefined;
      const state = said === "all_done" || said === "final" ? "all_done" : ["need_help", "need_human", "block", "need_decision"].includes(said) ? "need_human" : said === "waiting" ? "waiting" : "idle";
      return summary === undefined ? { state } : { state, summary };
    },
  };
}
