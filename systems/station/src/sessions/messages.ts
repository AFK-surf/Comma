// session_send (the Rust station's hub/messages.rs): one session's agent writes to another's, on this station or on another
// station of the workspace (through the station transport, as station_job goes). The message is posted in the other
// chat for people to see, headed with a link back to the sender's chat, and handed to the sessions there like any
// message; they answer the same way. Nothing limits how long two agents talk: that is theirs to judge.
import { threadAddress } from "../agents/instructions.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import { STILLFAIL_SURFACE, type SessionThread } from "../store/store.ts";
import { type Args, jsString } from "./args.ts";
import type { Hub } from "./hub.ts";
import { Refused } from "./neighbours.ts";
import { fromBefore, linkedSession, linkedStation, named, sessionThreadOf } from "./others.ts";

export { linkedStation };

type Json = any;

/// The method another station's message comes as (Remote hands it to `fromPeer`).
export const METHOD = "session.message";

/// At most this much text in one message (a peer request is bounded at 1 MiB).
const MAX_TEXT = 200_000;

const chars = (s: string) => Array.from(s).length;

/// Who a message comes from, as its header shows it: the sender's chat by its title, linked when it has a link.
function header(surface: string, title: string, link: string | null): string {
  let from: string;
  if (link !== null && surface === STILLFAIL_SURFACE) from = `[${title.replace(/[[\]]/g, "")}](${link})`;
  else if (link !== null) from = `<${link}|${title.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("|", "/")}>`;
  else from = title;
  return tr(stationLang(), "station.session.from", { from });
}

/// The sender's chat as a message from it is headed: its title, and its link once the station is in a workspace.
function sender(hub: Hub, key: string): [string, string | null] {
  const row = hub.store.getSession(key);
  if (!row) throw new Error("unknown session");
  let thread = null;
  try {
    thread = sessionThreadOf(hub, key).thread;
  } catch {}
  const title = [thread?.title ?? thread?.autoTitle ?? null, row.title].find((t) => t !== null && t !== undefined);
  const shown = title !== undefined && title !== null && title.trim() !== "" ? title : key;
  return [shown, hub.link(key) ?? null];
}

/// session_send from session `key`.
export async function sessionSend(hub: Hub, key: string, args: Args): Promise<string> {
  const to = (args.to === undefined ? "" : jsString(args.to)).trim();
  const text = (args.text === undefined ? "" : jsString(args.text)).trim();
  if (to === "") throw new Error("to is required: the other chat's link, its session key or a thread address; chat_list lists this station's");
  if (text === "") throw new Error("text is empty");
  if (chars(text) > MAX_TEXT) throw new Error(`text is too long (at most ${MAX_TEXT} characters): put the rest in a file and name its path`);
  const [title, link] = sender(hub, key);
  const here = link !== null ? linkedStation(link) : null;
  const there = linkedStation(to);
  if (there !== null && there !== here) {
    const target = linkedSession(to)?.[0];
    if (target === undefined) throw new Error(`${to} names no chat`);
    const call = hub.peers();
    if (!call) throw new Error("other stations cannot be reached from this one yet");
    const request = { method: METHOD, session: key, to: target, text, from: { title, link } };
    let answer: Json;
    try {
      answer = await call(there, request);
    } catch (error) {
      // What a station from before session.message answers it with (it took it for a task).
      const old = (error as Error).message;
      if (error instanceof Refused && fromBefore(old)) {
        throw new Error(`not sent to ${to}: that station is not updated yet and takes no messages`);
      }
      throw new Error(`not sent to ${to}: ${old}. If it timed out, it may have arrived: ask before sending it again`);
    }
    const place = typeof answer?.thread === "string" ? answer.thread : "its chat";
    return `Sent to ${target} on station ${there} (${place}). Its agent answers with session_send to your chat.`;
  }
  const what = named(hub, to);
  let thread: SessionThread;
  let targets: string[];
  if (what.type === "session") {
    if (what.key === key) throw new Error("that is this session: use chat_post for your own conversations");
    // Said in its chat: every agent there hears it, as they would a person.
    thread = sessionThreadOf(hub, what.key);
    targets = hub.store.threadSessions(thread.thread.id).map((m) => m.session);
    if (targets.includes(key)) throw new Error(`${threadAddress(thread.thread.channel, thread.thread.threadTs)} is one of your conversations: use chat_post there`);
  } else {
    const members = hub.store.threadSessions(what.thread.id);
    if (members.some((m) => m.session === key)) throw new Error(`${to} is one of your conversations: use chat_post there`);
    const connect = members[0]?.connect;
    if (connect === undefined) throw new Error(`no agent takes part in ${to}`);
    thread = { thread: what.thread, connect };
    targets = members.map((m) => m.session);
  }
  const place = await postFrom(hub, thread, key, title, link, text, targets);
  return `Sent to ${place} (agents there: ${targets.join(", ")}). They answer with session_send to your chat.`;
}

/// A message another station's session sent here (session_send there), from station `peer`.
export async function fromPeer(hub: Hub, peer: string, request: Json): Promise<Json> {
  const text = typeof request?.text === "string" ? request.text.trim() : "";
  const target = typeof request?.to === "string" ? request.to : "";
  const from = typeof request?.session === "string" ? request.session : "";
  if (text === "" || target === "" || from === "" || chars(text) > MAX_TEXT) throw new Error(`a message needs to, session and text (at most ${MAX_TEXT} characters)`);
  if (hub.store.getSession(target) === null) throw new Error(`no session ${target} on this station (it may have been deleted)`);
  const thread = sessionThreadOf(hub, target);
  const targets = hub.store.threadSessions(thread.thread.id).map((m) => m.session);
  const title = typeof request?.from?.title === "string" && request.from.title.trim() !== "" ? request.from.title : from;
  const link = typeof request?.from?.link === "string" && request.from.link !== "" ? request.from.link : null;
  // Not a session of this station: by its station and key, so it is never taken for one.
  const place = await postFrom(hub, thread, `${peer}/${from}`, title, link, text, targets);
  return { thread: place };
}

/// Posts `text` from `author` in `thread`, headed with where it comes from, and hands it to `targets`. Its address.
async function postFrom(hub: Hub, thread: SessionThread, author: string, title: string, link: string | null, text: string, targets: string[]): Promise<string> {
  const row = thread.thread;
  const said = `${header(row.surface, title, link)}\n\n${text}`;
  const ts = await hub.chat(thread.connect).post({ channel: row.channel, threadTs: row.threadTs }, said, []);
  const [n] = hub.store.insertMessage({ thread: row.id, ts, authorKind: "agent", author, text: said });
  hub.deliver(row.id, n, targets.filter((t) => t !== author), said);
  return threadAddress(row.channel, row.threadTs);
}
