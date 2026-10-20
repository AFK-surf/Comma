// What the people of a chat hear about while no client of theirs runs (admin/notify.rs, docs/notifications.md): an
// agent's turn ending in one of the station's own chats (done with something said, or blocked), something going wrong
// there (the station says so, ⚠️ first), and a person saying something there. Worked out here, off the main thread,
// from a store change the station saw; the station posts them to still.fail cloud (src/cloud/notify.ts).
import { type Lang, tr as translate } from "../ops/i18n.ts";
import { type EntryRow, type MessageRow, STILLFAIL_SURFACE, type Store, type TurnSummary } from "./store.ts";
import * as store from "./store.ts";
import { apiOf, authorNames, chatTitle, people, useNames } from "./views.ts";
import { wall } from "../ops/fibers.ts";

/// How long a notice's text is kept, in characters (still.fail cloud cuts it shorter).
const TEXT = 400;

export type Notice = { to: string[]; kind: string; session: string; thread: number; title: string; by: string; text: string; at: number };

/// What a turn's end is worth telling its chat, and in what words: blocked, or done having said something there (the
/// chat's last message is the agent's, from this turn). Any other end says nothing; a failed one, the station's ⚠️ does.
export function turnNotice(turn: TurnSummary, last: MessageRow | null, key: string, file: string): [string, string] | null {
  const theirs = last !== null && last.authorKind === "agent" && last.author === key && last.createdAt >= (turn.startedAt as number) ? last : null;
  const text = theirs !== null && theirs.text.trim() !== "" ? theirs.text : null;
  if (turn.declared === "block") {
    const need = typeof turn.need === "string" && turn.need.trim() !== "" ? turn.need : null;
    return ["block", need ?? text ?? ""];
  }
  if (turn.outcome === "failed") return null;
  if (turn.declared === "final") return theirs !== null ? ["done", text ?? file] : null;
  return null;
}

/// The station's word in a chat that something went wrong (⚠️ first, as the session posts it): what went wrong.
export function wentWrong(text: string): string | null {
  return text.startsWith("⚠️") ? text.slice("⚠️".length).trim() : null;
}

/// The emails of a chat's people: who made it, who said something in it, who started its agents; but `except`.
function emailsOf(s: Store, creator: string | null, said: string[], sessions: string[], except: string | null): string[] {
  const starters = sessions.flatMap((k) => store.getSession(s, k)?.createdBy ?? []);
  const refs = [...(creator === null ? [] : [creator]), ...said, ...starters];
  const not = except?.toLowerCase() ?? null;
  const seen = new Set<string>();
  return people(refs)
    .flatMap((p) => (typeof p.email === "string" ? [p.email.toLowerCase()] : []))
    .filter((e) => e !== not && !seen.has(e) && (seen.add(e), true));
}

function notice(s: Store, thread: number, session: string, kind: string, by: string, text: string, except: string | null): Notice | null {
  const summary = store.listThreads(s, "", null, thread).pop();
  if (summary === undefined) return null;
  const to = emailsOf(s, summary.thread.createdBy, summary.people, summary.sessions.map((m) => m.session), except);
  if (to.length === 0) return null;
  return { to, kind, session, thread, title: chatTitle(summary, null), by, text: [...text].slice(0, TEXT).join(""), at: wall.now() };
}

/// A session changed: its last turn, if it ended since `since` and is not `ended` (the end already told), told to its
/// chats. Gives the end it saw.
export function turnNotices(s: Store, key: string, since: number, ended: number | null, lang: Lang): { ended: number | null; notices: Notice[] } {
  useNames(s);
  const turn = store.sessionStats(s, key).get(key)?.lastTurn ?? null;
  const at = turn?.endedAt;
  if (turn === null || typeof at !== "number" || at < since) return { ended, notices: [] };
  if (at === ended) return { ended, notices: [] };
  const api = apiOf(s);
  const out: Notice[] = [];
  for (const thread of store.sessionThreads(s, key)) {
    if (thread.surface !== STILLFAIL_SURFACE || thread.hiddenAt !== null) continue;
    const told = turnNotice(turn, store.lastMessage(s, thread.id), key, translate(lang, "station.notice.file"));
    if (told === null) continue;
    const by = authorNames(api, thread.id)("agent", key) ?? "";
    const n = notice(s, thread.id, key, told[0], by, told[1], null);
    if (n !== null) out.push(n);
  }
  return { ended: at, notices: out };
}

/// Entries written in a chat: a person's message (the chat's other people hear it), the station saying something
/// went wrong (everyone does).
export function saidNotices(s: Store, id: number, entries: EntryRow[], since: number, lang: Lang): Notice[] {
  useNames(s);
  const fresh = entries.filter((e) => e.kind === "message" && e.at >= since);
  const person = fresh.filter((e) => e.authorKind === "person").at(-1);
  const wrong = fresh.filter((e) => e.authorKind === "ember").flatMap((e) => (e.text === null ? [] : (wentWrong(e.text) ?? []))).at(-1);
  if (person === undefined && wrong === undefined) return [];
  const thread = store.getThread(s, id);
  if (thread === null || thread.surface !== STILLFAIL_SURFACE || thread.hiddenAt !== null) return [];
  const session = store.threadSessions(s, id)[0]?.session;
  if (session === undefined) return [];
  const out: Notice[] = [];
  if (person !== undefined) {
    const by = authorNames(apiOf(s), id)("person", person.author) ?? person.author;
    const text = person.text !== null && person.text.trim() !== "" ? person.text : translate(lang, "station.notice.file");
    const n = notice(s, id, session, "message", by, text, person.author);
    if (n !== null) out.push(n);
  }
  if (wrong !== undefined) {
    const n = notice(s, id, session, "failed", "", wrong, null);
    if (n !== null) out.push(n);
  }
  return out;
}

