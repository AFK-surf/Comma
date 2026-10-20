// Other conversations and sessions of the station, for an agent to read (the Rust station's hub/others.rs: chat_list,
// chat_read, session_history): people refer to another chat by its link, and the agent reads what was said there and
// what its agents did.
import { parseThreadAddress, threadAddress } from "../agents/instructions.ts";
import { iso, type TimelineEntry } from "../read/transcript.ts";
import { STILLFAIL_SURFACE, type SessionRow, type SessionThread, type ThreadRow } from "../store/store.ts";
import { type Args, jsNumber, jsString } from "./args.ts";
import { threadHistory } from "./conversations.ts";
import type { Hub } from "./hub.ts";
import { Refused } from "./neighbours.ts";
import { TASK_SURFACE } from "../tasks/names.ts";

type Json = any;

/// The method another station's agent reads a chat of this one by (chat_read and session_history with its link).
export const READ = "session.read";

/// What an agent named: a conversation, or a session (maybe one entry of its execution history).
export type Named = { type: "thread"; thread: ThreadRow } | { type: "session"; key: string; entry: number | null };

/// admin/mod.rs `percent_decode`: %XX a byte, `+` a space, the rest as it is (UTF-8, lossy).
export function percentDecode(s: string): string {
  const bytes = Buffer.from(s, "utf8");
  const out: number[] = [];
  for (let i = 0; i < bytes.length; ) {
    const hex = bytes.subarray(i + 1, i + 3).toString("latin1");
    if (bytes[i] === 0x25 && /^[0-9A-Fa-f]{2}$/.test(hex)) {
      out.push(parseInt(hex, 16));
      i += 3;
    } else if (bytes[i] === 0x2b) {
      out.push(0x20);
      i++;
    } else out.push(bytes[i++]!);
  }
  return new TextDecoder("utf-8").decode(Buffer.from(out));
}

/// A session key a reference holds, in whichever form people pass chats around: a chat's page (…/chats/<key>), a
/// still.fail link (…/o/<workspace>/<station>/<key>), a link to execution history (?history=<key>&entry=<n>).
export function linkedSession(reference: string): [string, number | null] | null {
  const end = (s: string) => {
    const at = s.search(/[/?#)>|"'\s]/u);
    return at < 0 ? s.length : at;
  };
  const history = reference.indexOf("history=");
  if (history >= 0) {
    const rest = reference.slice(history + "history=".length);
    const stop = rest.search(/[&#)>|\s]/u);
    const key = percentDecode(rest.slice(0, stop < 0 ? rest.length : stop));
    const at = reference.indexOf("entry=");
    const digits = at >= 0 ? (/^[0-9]*/.exec(reference.slice(at + "entry=".length))?.[0] ?? "") : "";
    const entry = digits !== "" && Number.isSafeInteger(Number(digits)) ? Number(digits) : null;
    return key !== "" ? [key, entry] : null;
  }
  const segment = (rest: string) => percentDecode(rest.slice(0, end(rest)).replaceAll("+", "%2B"));
  const chats = reference.indexOf("/chats/");
  if (chats >= 0) {
    const key = segment(reference.slice(chats + "/chats/".length));
    return key !== "" ? [key, null] : null;
  }
  const o = reference.indexOf("/o/");
  if (o >= 0) {
    const parts = splitN(reference.slice(o + "/o/".length), "/", 3);
    if (parts.length === 3) {
      const key = segment(parts[2]!);
      return key !== "" ? [key, null] : null;
    }
  }
  return null;
}

/// The station a link to a chat is on: a still.fail link (…/o/<workspace>/<station>/<key>) or a chat's page under its
/// station's (…/w/<workspace>/s/<station>/chats/<key>, as a reference written in a chat is).
export function linkedStation(reference: string): string | null {
  const page = /\/w\/[^/\s]+\/s\/([^/?#\s]+)\/chats\//u.exec(reference);
  if (page) return page[1]!;
  const at = reference.indexOf("/o/");
  if (at < 0) return null;
  const parts = splitN(reference.slice(at + 3), "/", 3);
  return parts.length === 3 && parts[1] !== "" ? parts[1]! : null;
}

/// What another station answers with when it is from before a request (it took it for a remote job, then called a task).
export function fromBefore(refusal: string): boolean {
  return refusal.includes("remote tasks are not enabled") || refusal.includes("task key");
}

/// The other station of the workspace a chat's link is on, for session `key` to read it there; null when it is on this
/// one (or this station is in no workspace, so has no others).
export function elsewhere(hub: Hub, key: string, reference: string): string | null {
  const link = hub.link(key);
  const here = link !== undefined ? linkedStation(link) : null;
  const there = linkedStation(reference);
  return here !== null && there !== null && there !== here ? there : null;
}

/// chat_read or session_history of a chat on another station of the workspace: asked of that station (`forPeer` there).
export async function readAfar(hub: Hub, key: string, station: string, tool: "chat_read" | "session_history", args: Args): Promise<string> {
  const call = hub.peers();
  if (!call) throw new Error("other stations cannot be reached from this one yet");
  const given = Object.fromEntries(["chat", "before", "limit", "max_chars"].filter((k) => args[k] !== undefined).map((k) => [k, args[k]]));
  let answer: Json;
  try {
    answer = await call(station, { method: READ, session: key, tool, args: given });
  } catch (error) {
    const why = (error as Error).message;
    if (error instanceof Refused && fromBefore(why)) throw new Error(`station ${station} is not updated yet: its chats cannot be read from here`);
    throw new Error(`not read from station ${station}: ${why}`);
  }
  if (typeof answer?.text !== "string") throw new Error(`station ${station} answered with nothing to read`);
  return `(Read from station ${station}: give its chats' links, not their addresses or keys, to read more there.)\n${answer.text}`;
}

/// What another station's session reads here (`readAfar` there), from station `peer`: its own chats are not involved.
export async function forPeer(hub: Hub, peer: string, request: Json): Promise<Json> {
  const tool = request?.tool;
  const args: Args = request?.args !== null && typeof request?.args === "object" && !Array.isArray(request.args) ? request.args : {};
  const from = typeof request?.session === "string" ? request.session : "";
  if (typeof args.chat !== "string" || args.chat.trim() === "") throw new Error("chat is required");
  if (tool === "chat_read") return { text: await chatRead(hub, `${peer}/${from}`, args) };
  if (tool === "session_history") return { text: sessionHistory(hub, args) };
  throw new Error(`cannot read with ${JSON.stringify(tool)}`);
}

/// str::splitn.
export function splitN(s: string, sep: string, n: number): string[] {
  const parts: string[] = [];
  let rest = s;
  while (parts.length < n - 1) {
    const at = rest.indexOf(sep);
    if (at < 0) break;
    parts.push(rest.slice(0, at));
    rest = rest.slice(at + sep.length);
  }
  parts.push(rest);
  return parts;
}

/// Cuts text to `max` characters, saying how much was left out.
function cut(text: string, max: number): string {
  const chars = Array.from(text);
  return chars.length <= max ? text : `${chars.slice(0, max).join("")}… (${chars.length - max} more characters)`;
}

/// One-line text: a title or a message's start, as a list shows it.
const line = (text: string, max: number) => cut(text.split(/\s+/u).filter((w) => w !== "").join(" "), max);

/// Execution history entries as the agent reads them: numbered as the pages number them (…&entry=<n>).
export function formatSteps(start: number, entries: TimelineEntry[], maxChars: number): string {
  return entries
    .map((e, i) => {
      const what = e.kind === "tool_call" && e.tool !== undefined ? `tool_call ${e.tool}` : e.kind === "tool_result" && e.ok === false ? "tool_result (error)" : e.kind;
      const sub = e.subagent === true ? " subagent" : "";
      const at = e.at !== null ? ` ${e.at}` : "";
      return `#${start + i}${at} ${what}${sub}:\n${cut(e.text.trim(), maxChars)}`;
    })
    .join("\n\n");
}

/// What a reference names on this station: a chat link, an execution history link, a thread address (CHANNEL/THREAD_TS)
/// or a session key.
export function named(hub: Hub, given: string): Named {
  const reference = given.trim();
  if (reference === "") throw new Error("chat is required: a chat's link, a thread address (CHANNEL/THREAD_TS) or a session key; chat_list lists them");
  const linked = linkedSession(reference);
  if (linked) {
    const [key, entry] = linked;
    if (hub.store.getSession(key) === null) throw new Error(`${reference} names session ${key}, which is not on this station (it may be another station's, or deleted)`);
    return { type: "session", key, entry };
  }
  const address = parseThreadAddress(reference);
  if (address) {
    const found = hub.store.threadsAt(address[0], address[1]);
    if (found.length === 0) throw new Error(`no conversation ${reference} on this station`);
    return { type: "thread", thread: found[0]! };
  }
  if (hub.store.getSession(reference) !== null) return { type: "session", key: reference, entry: null };
  throw new Error(`${JSON.stringify(reference)} is not a chat of this station: give a chat's link, a thread address (CHANNEL/THREAD_TS) or a session key; chat_list lists them`);
}

/// The conversation a session is best read in: its own chat on the pages, else the one it last heard from.
export function sessionThreadOf(hub: Hub, key: string): SessionThread {
  const home = hub.store.sessionThreads(key).find((t) => t.thread.home === key);
  if (home) return home;
  const latest = hub.store.latestThread(key);
  if (!latest) throw new Error(`session ${key} has no conversation yet`);
  return latest;
}

/// chat_list: the station's conversations, the latest first, each with its agents (session keys).
export function chatList(hub: Hub, key: string, args: Args): string {
  const given = args.limit === undefined ? null : jsNumber(args.limit);
  const limit = given === null ? 20 : Number.isNaN(given) ? 0 : Math.trunc(Math.min(100, Math.max(1, given)));
  const query = (args.query === undefined ? "" : jsString(args.query)).trim().toLowerCase();
  const sessions = new Map<string, SessionRow>(hub.store.listSessions().map((s) => [s.key, s]));
  const threads = hub.store.listThreads("", null, null);
  const when = (t: (typeof threads)[number]) => t.lastMessage?.createdAt ?? t.thread.createdAt;
  threads.sort((a, b) => when(b) - when(a));
  const lines: string[] = [];
  let matched = 0;
  for (const t of threads) {
    const titles = [t.thread.title, t.thread.autoTitle, t.firstText, ...t.sessions.map((m) => sessions.get(m.session)?.title ?? null)].filter((x): x is string => x !== null);
    const last = t.lastMessage?.text ?? "";
    if (query !== "") {
      const haystack = `${titles.join(" ")} ${last} ${t.sessions.map((m) => m.session).join(" ")}`.toLowerCase();
      if (!haystack.includes(query)) continue;
    }
    matched++;
    if (lines.length >= limit) continue;
    const address = threadAddress(t.thread.channel, t.thread.threadTs);
    const place = t.thread.surface === STILLFAIL_SURFACE ? "still.fail chat" : t.thread.surface === TASK_SURFACE ? "Task of another station" : "Slack thread";
    const title = titles.length > 0 ? line(titles[0]!, 80) : "(untitled)";
    const agents = t.sessions.map((m) => `${m.session}${m.session === key ? " (you)" : ""}${(sessions.get(m.session)?.archivedAt ?? null) !== null ? " archived" : ""}`);
    const at = iso(t.lastMessage?.createdAt ?? t.thread.createdAt);
    const hidden = t.thread.hiddenAt !== null ? ", archived" : "";
    let entry = `- ${address} (${place}${hidden}) "${title}"\n  agents: ${agents.length === 0 ? "none" : agents.join(", ")}; last message ${at}`;
    if (last !== "") entry += `: ${line(last, 120)}`;
    lines.push(entry);
  }
  if (lines.length === 0) return query === "" ? "No conversations on this station." : `No conversation matches ${JSON.stringify(query)}.`;
  const more = matched > lines.length ? `\n(${matched - lines.length} more; raise limit or narrow query)` : "";
  return `${lines.join("\n")}${more}`;
}

/// chat_read: the messages of any conversation of the station.
export async function chatRead(hub: Hub, key: string, args: Args): Promise<string> {
  const reference = args.chat === undefined ? "" : jsString(args.chat);
  const what = named(hub, reference);
  let thread: ThreadRow;
  let connect: string;
  let note = "";
  if (what.type === "thread") {
    thread = what.thread;
    connect = hub.store.threadSessions(thread.id)[0]?.connect ?? "";
  } else {
    const found = sessionThreadOf(hub, what.key);
    [thread, connect] = [found.thread, found.connect];
    const others = hub.store
      .sessionThreads(what.key)
      .filter((t) => t.thread.id !== found.thread.id)
      .map((t) => threadAddress(t.thread.channel, t.thread.threadTs));
    if (others.length > 0) note = `\n(Session ${what.key} also takes part in ${others.join(", ")}; read them with chat_read chat=<address>.)`;
  }
  const address = threadAddress(thread.channel, thread.threadTs);
  const text = await threadHistory(hub, key, thread, connect, address, args);
  const agents = hub.store.threadSessions(thread.id).map((m) => m.session);
  return `Conversation ${address}; its agents: ${agents.length === 0 ? "none" : agents.join(", ")}.\n${text}${note}`;
}

/// session_history: what a session's agent did (its execution history, as the pages show it), from its transcript.
export function sessionHistory(hub: Hub, args: Args): string {
  const reference = args.chat === undefined ? "" : jsString(args.chat);
  const what = named(hub, reference);
  let session: string;
  let entry: number | null = null;
  if (what.type === "session") [session, entry] = [what.key, what.entry];
  else {
    const agents = hub.store.threadSessions(what.thread.id).map((m) => m.session);
    if (agents.length === 0) throw new Error(`${reference} has no agent, so no execution history`);
    if (agents.length > 1) throw new Error(`${reference} has several agents; give one of them as chat: ${agents.join(", ")}`);
    session = agents[0]!;
  }
  const number = (name: string, low: number, high: number, fallback: number) => {
    const n = args[name] === undefined ? null : jsNumber(args[name]);
    return n === null ? fallback : Number.isNaN(n) ? 0 : Math.trunc(Math.min(high, Math.max(low, n)));
  };
  const limit = number("limit", 1, 200, 40);
  const maxChars = number("max_chars", 100, 4000, 1500);
  const given = args.before === undefined ? null : jsNumber(args.before);
  // A link to one entry: it and what came around it.
  const before = given !== null ? (Number.isNaN(given) ? 0 : Math.trunc(Math.max(0, given))) : entry !== null ? entry + 1 + Math.floor(limit / 2) : Number.MAX_SAFE_INTEGER;
  const row = hub.store.getSession(session);
  if (!row) throw new Error(`unknown session ${session}`);
  const read = hub.live.before(session, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
  if (!read) return `Session ${session} has no execution history yet.`;
  const all = read[1];
  const total = all.length;
  const end = Math.min(before, total);
  const start = Math.max(0, end - limit);
  const entries = all.slice(start, end);
  if (total === 0) return `Session ${session} has no execution history yet.`;
  if (entries.length === 0) return `Session ${session} has ${total} entries of execution history; none before #${before}.`;
  const model = row.model !== null ? `, ${row.model}` : "";
  const older = start > 0 ? ` Older ones: before=${start}.` : "";
  return `Session ${session} (${row.runtime}${model}): entries #${start}–#${start + entries.length - 1} of ${total}.${older}\n\n${formatSteps(start, entries, maxChars)}`;
}
