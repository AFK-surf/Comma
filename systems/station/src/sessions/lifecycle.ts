// Sessions and chats as people make, change, archive and delete them (the Rust station's hub.rs: new_session, open_chat,
// add_to_thread, say, bind_single, configure, archive, archive_chat, auto_archive, delete_session,
// continue_machine_session). Archiving here is the record (archived, hidden) and what goes with it (the process ends,
// other stations are told); packing an archived session's files is the hub's ColdStorage.
import { copyFileSync, mkdirSync, renameSync, rmSync, statSync } from "node:fs";
import { rm } from "node:fs/promises";
import { basename, dirname, join, relative, sep } from "node:path";
import { unreadableDir, unreadableDirMessage } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { tr, type Lang, stationLang } from "../ops/i18n.ts";
import { type MachineSession, type Roots, rolloutOf, rolloutsIn } from "../read/machine.ts";
import { readTimeline, transcriptPath } from "../read/transcript.ts";
import { AUTO, type Attachment, MANUAL, type Quote, STILLFAIL_SURFACE, type ThreadRow } from "../store/store.ts";
import type { SessionChange } from "./accounts.ts";
import { unlockWorktrees, withLock } from "./archive.ts";
import { roomOf } from "./footprint.ts";
import { type Runtime, runs, runtimeTitle } from "./config.ts";
import { CLIENT_KEY_KEPT_MS, type Hub, connectOf, newChatKey, newSingleSessionKey, newToken } from "./hub.ts";
import { INTERNAL_CHANNEL, INTERNAL_CONNECT } from "./internal.ts";

/// A session of its own, talked to in the station's chat.
export type NewChat = {
  runtime: Runtime;
  profile?: string | null;
  model?: string | null;
  effort?: string | null;
  fast?: boolean | null;
  title?: string | null;
  createdBy: string;
  /// The key the asking client knows it by until it is made (`clientKey`): the sidebar's rows say it for a while.
  clientKey?: string | null;
  /// The Station whose Task it takes part in (tasks.ts), whose Workspace's account source it keeps to.
  host?: string | null;
};

const trimmed = (v: string | null | undefined) => {
  const t = v?.trim();
  return t ? t : null;
};

/// Points a single-session connect at a session: an existing one (any session on the same runtime, whichever connect
/// started it) or, with null, a new empty one. The bound session's key.
export function bindSingle(hub: Hub, connectId: string, target: string | null, title: string | null, createdBy: string | null): string {
  const config = hub.config();
  const connect = connectOf(config, connectId);
  if (connect.mode !== "single-session") throw new Error(`connect ${connectId} is not single-session`);
  if (target === null) {
    const key = newSingleSessionKey(connect.id);
    hub.createSession(config, key, connect, "all", null, trimmed(title), createdBy);
    hub.store.setBinding(connect.id, key);
    return key;
  }
  const row = hub.store.getSession(target);
  if (!row) throw new Error(`unknown session ${target}`);
  if (row.runtime !== connect.bind.runtime) throw new Error(`session ${target} runs ${row.runtime}, the connect runs ${connect.bind.runtime}`);
  hub.store.setBinding(connect.id, target);
  log.info("hub", "single-session connect rebound", { connect: connect.id, session: target });
  return target;
}

/// Opens a chat on the station's pages with a session in it. More sessions can join it later (addToThread).
export function openChat(hub: Hub, session: string, createdBy: string, title: string | null): ThreadRow {
  if (!hub.internal) throw new Error("still.fail chat is not available");
  const row = hub.store.getSession(session);
  if (!row) throw new Error(`unknown session ${session}`);
  // The first chat made with a session is its own; later ones are chats of their own (ThreadRow.home).
  const home = hub.store.homeChat(session) !== null ? null : session;
  // Its own chat keeps the name the session was given before it had one.
  const name = title ?? (home !== null ? row.title : null);
  const thread = hub.store.openThreadOf(STILLFAIL_SURFACE, INTERNAL_CHANNEL, hub.nextTs(), name, createdBy, home);
  hub.store.joinThread(thread.id, session, INTERNAL_CONNECT);
  return thread;
}

function stillfailChat(hub: Hub, thread: number): ThreadRow {
  const row = hub.store.getThread(thread);
  if (!row || row.surface !== STILLFAIL_SURFACE) throw new Error(`no still.fail chat ${thread}`);
  return row;
}

/// Brings another session into a chat on the station's pages; it hears what is said from then on.
export function addToThread(hub: Hub, thread: number, session: string) {
  stillfailChat(hub, thread);
  if (hub.store.getSession(session) === null) throw new Error(`unknown session ${session}`);
  hub.store.joinThread(thread, session, INTERNAL_CONNECT);
}

/// A person's message in a chat on the station's pages: recorded with its quotes and files and delivered to every
/// session in the chat, like a Slack message. `client`: the app it was sent from, as it said. Its entry number.
export function say(hub: Hub, thread: number, user: string, text: string, attachments: Attachment[] = [], quotes: Quote[] = [], client: string | null = null): number {
  stillfailChat(hub, thread);
  const [n] = hub.store.insertMessage({ thread, ts: hub.nextTs(), authorKind: "person", author: user, text, attachments, quotes, client });
  const sessions = hub.store.threadSessions(thread).map((m) => m.session);
  hub.deliver(thread, n, sessions, text);
  return n;
}

/// A session of its own, talked to in the station's chat: the runtime, model and effort chosen by whoever starts it
/// rather than a connect's, and the profile: one given keeps it there; else the pool picks one with the model on.
/// `open`: where it is talked to instead, its own (a Task of another station's, tasks.ts).
export function newSession(hub: Hub, options: NewChat, lang: Lang = stationLang(), open?: (key: string) => ThreadRow): [string, ThreadRow] {
  const config = hub.config();
  const runtime = options.runtime;
  // Refused with the reason when the Workspace it comes from chose no account for the runtime here.
  const profiles = hub.accounts.candidates(runtime, options.host ?? null, lang);
  if (profiles.length === 0) throw new Error(`no ${runtime} profile configured`);
  const model = trimmed(options.model);
  const pinned = options.profile ?? null;
  let profile;
  if (pinned !== null) {
    profile = profiles.find((p) => p.id === pinned);
    if (!profile) throw new Error(`no ${runtime} profile ${pinned}`);
    if (model !== null && !runs(profile, model)) throw new Error(tr(lang, "station.profile.modelOff", { profile: profile.name, model }));
  } else profile = hub.accounts.pick(profiles, model, true);
  const effort = options.effort ? options.effort : null;
  if (effort !== null) {
    const allowed = hub.accounts.modelEfforts(runtime, model, pinned);
    if (!allowed.includes(effort)) throw new Error(`effort must be one of ${allowed.join(", ")}`);
  }
  const key = newChatKey();
  const workspace = join(config.dataDir, "sessions", INTERNAL_CONNECT, key.slice(INTERNAL_CONNECT.length + 1), "workspace");
  mkdirSync(workspace, { recursive: true });
  mkdirSync(join(config.dataDir, "repos"), { recursive: true });
  const now = hub.now();
  // Known before its rows are (their events can reach the client before this answers), and for a while after.
  const client = trimmed(options.clientKey);
  if (client !== null) {
    for (const [k, [, at]] of hub.clientKeysMade) if (now - at >= CLIENT_KEY_KEPT_MS) hub.clientKeysMade.delete(k);
    hub.clientKeysMade.set(key, [Array.from(client).slice(0, 120).join(""), now]);
  }
  const title = trimmed(options.title);
  hub.store.insertSession({
    key,
    connect: INTERNAL_CONNECT,
    scope: "all",
    title,
    createdBy: options.createdBy,
    runtime,
    profile: profile.id,
    profilePinned: pinned !== null,
    model: model ?? profile.model ?? null,
    effort,
    fast: runtime === "codex" ? (options.fast ?? null) : null,
    workspace,
    cwd: null,
    runtimeSessionId: null,
    token: newToken(),
    createdAt: now,
    lastActiveAt: now,
  });
  log.info("hub", "session created", { session: key, connect: INTERNAL_CONNECT, runtime, profile: profile.id, model });
  return [key, open ? open(key) : openChat(hub, key, options.createdBy, title)];
}

/// Changes how a session runs from its next turn on: another profile of its runtime (another account, say), another
/// model it can run, another effort. Its transcript is shared by the runtime's profiles, so the next message resumes it
/// with all it had; its idle process ends first so the change takes. Not while a turn runs. Another model starts over
/// what went with the old one: its effort back to the runtime's default, its profile back to the station's choice
/// (picked here, among those with the model enabled), unless given with it.
/// Another runtime (Claude Code for Codex, say) is that runtime's model, effort and profile as given, else its defaults
/// and the pool's pick; its next turn goes on afresh in a new runtime session there (afresh.ts), and its history reads
/// on from what it ran before. Its chats and files stay as they are.
export async function configure(hub: Hub, key: string, change: SessionChange, lang: Lang = stationLang()) {
  const rerun = hub.accounts.rerun(key, change, lang);
  if (rerun !== null) {
    if (hub.processState(key) === "running") throw new Error(tr(lang, "station.session.busy"));
    const was = hub.store.getSession(key)?.runtime ?? "";
    await hub.evict(key);
    hub.store.setSessionRuntime(key, rerun.runtime, rerun.profile, rerun.pinned, rerun.model, rerun.effort, rerun.fast);
    log.info("hub", "session moved to another runtime", { session: key, was, runtime: rerun.runtime, profile: rerun.profile, model: rerun.model });
    return goOnAfterAllowance(hub, key);
  }
  const { row, model, effort, profile } = hub.accounts.change(key, change, lang);
  if (hub.processState(key) === "running") throw new Error(tr(lang, "station.session.busy"));
  await hub.evict(key);
  if (profile !== undefined) hub.store.setSessionProfile(key, profile ?? row.profile, profile !== null);
  if (model !== row.model || effort !== row.effort) hub.store.setSessionModel(key, model, effort);
  if (change.fast !== undefined) hub.store.setSessionFast(key, change.fast);
  if (profile === null) hub.accounts.runOn(key);
  log.info("hub", "session changed", { session: key, profile: hub.store.getSession(key)?.profile ?? "", model, effort });
  goOnAfterAllowance(hub, key);
}

/// Its last turn stopped at the allowance: changed, it goes on by itself.
function goOnAfterAllowance(hub: Hub, key: string): void {
  const row = hub.store.getSession(key);
  const last = hub.store.lastTurn(key);
  if (row && last?.outcome === "failed" && (last.detail ?? "").startsWith("rate_limit")) void hub.actor(row).goOn();
}

/// Where an archived session's transcript copy is.
const transcriptCopy = (hub: Hub, key: string) => join(hub.store.archiveDir(), "transcripts", `${key}.jsonl.zst`);

/// Hides a session from lists, or shows it again; `by` is MANUAL or AUTO. Archiving also ends its idle process and
/// hands its files to cold storage once it is idle; they are restored before the next runtime starts, and before it is
/// shown again (a promise then, when cold storage takes its time: the session is shown once they are back).
export function archiveBy(hub: Hub, key: string, archived: boolean, by: string): void | Promise<void> {
  const row = hub.store.getSession(key);
  if (!row) throw new Error(`unknown session ${key}`);
  if (!archived) {
    const shown = () => {
      hub.store.setArchived(key, false, by);
      rmSync(transcriptCopy(hub, key), { force: true });
    };
    const restoring = hub.cold.restore(key);
    return restoring ? restoring.then(shown) : shown();
  }
  hub.store.setArchived(key, archived, by);
  hub.closed(key);
  const actor = hub.actor(row);
  void actor.evict().then(() => actor.cleanArchive());
}

/// Hides a session from lists, or shows it again, by hand.
export const archive = (hub: Hub, key: string, archived: boolean) => archiveBy(hub, key, archived, MANUAL);

/// Archives a chat on the pages, or shows it again: a session's own chat goes with its session; a chat of its own goes
/// alone, its sessions staying as they are.
export function archiveChat(hub: Hub, thread: number, archived: boolean): void | Promise<void> {
  const chat = stillfailChat(hub, thread);
  if (chat.home !== null) return archive(hub, chat.home, archived);
  hub.store.setThreadHidden(thread, archived, MANUAL);
}

/// Archives what has idled past autoArchiveMs (counted from its last activity, or from being shown again by hand) and is
/// done: nothing running or waiting to be heard, no background job or service of its own still up (a watch above all),
/// not stopped at a block for someone, nothing its chat's starter has not read, and no single-session connect feeding
/// it. Anything new said brings it back.
export function autoArchive(hub: Hub, now: number) {
  const { store } = hub;
  const after = hub.config().autoArchiveMs;
  if (after <= 0) return;
  const idle = (at: (number | null | undefined)[]) => now - Math.max(0, ...at.filter((x): x is number => typeof x === "number")) >= after;
  const unread = (t: ThreadRow) => t.createdBy !== null && t.surface === STILLFAIL_SURFACE && store.unreadCount(t.createdBy, t.id) > 0;
  const bound = store.listBindings();
  const stats = store.sessionStats(null);
  const jobs = new Set(store.listJobs(null).filter((j) => j.state === "running" || (j.port !== null && j.state === "exited")).map((j) => j.sessionKey));
  const busy = (key: string) => {
    const row = store.getSession(key);
    if (!row) return true;
    const stat = stats.get(key);
    const last = stat?.lastTurn ?? null;
    return row.running || jobs.has(key) || hub.processState(key) === "running" || (stat?.pending ?? 0) > 0 || (last !== null && (last.declared === "block" || last.endedAt === null));
  };
  // A chat someone pinned stays in the lists until put away by hand.
  const pinned = store.pinnedSessions();
  const kept = store.keptChats(null);
  for (const s of store.listSessions()) {
    if (s.archivedAt !== null || !idle([s.lastActiveAt, s.shownAt]) || bound.has(s.key) || pinned.has(s.key) || busy(s.key)) continue;
    if (store.sessionThreads(s.key).some((t) => kept.has(t.thread.id) || unread(t.thread))) continue;
    log.info("hub", "archiving an idle session", { session: s.key });
    archiveBy(hub, s.key, true, AUTO);
  }
  for (const t of store.chatsOfTheirOwn()) {
    const said = store.lastMessage(t.id)?.createdAt ?? null;
    if (kept.has(t.id) || !idle([t.createdAt, said, t.shownAt]) || unread(t)) continue;
    if (store.threadSessions(t.id).some((m) => pinned.has(m.session) || busy(m.session))) continue;
    log.info("hub", "archiving an idle chat", { thread: t.id });
    store.setThreadHidden(t.id, true, AUTO);
  }
}

/// Deletes a session: its process ends, its rows go (with the threads only it was in) and its workspace directory and
/// transcript copy with them. The runtime's transcript stays in the profile's home, which may be a person's own.
export async function deleteSession(hub: Hub, key: string) {
  const row = hub.store.getSession(key);
  if (!row) throw new Error(`unknown session ${key}`);
  const actor = hub.dropActor(key);
  await actor?.dispose();
  hub.live.forget(key);
  hub.store.deleteSession(key);
  hub.closed(key);
  rmSync(transcriptCopy(hub, key), { force: true });
  // Sessions made by the station keep their workspace in a directory of their own.
  const sessions = join(hub.config().dataDir, "sessions");
  const own = basename(row.workspace) === "workspace" && (row.workspace + sep).startsWith(sessions + sep);
  const home = own ? dirname(row.workspace) : row.workspace;
  const room = roomOf(hub.config().dataDir, row.workspace);
  if (room !== null) {
    // Git worktrees it archived are let go first, so `git worktree prune` can clean them up.
    await withLock(room, async () => {
      await unlockWorktrees(room);
      await rm(home, { recursive: true, force: true });
    });
  } else rmSync(home, { recursive: true, force: true });
  log.info("hub", "session deleted", { session: key });
}

/// Copies a machine session's transcript to where the station's runtimes keep theirs (`shared`:
/// data/transcripts/<runtime>), at the same place under it, so a profile resumes it there: for Codex every file it keeps
/// the thread in. The originals are not touched. Where the transcript read is.
function copyTranscript(roots: Roots, session: MachineSession, shared: string): string {
  const root = session.runtime === "claude" ? roots.claude : roots.codex;
  if (root === null) throw new Error(`${session.path} is not the machine's`);
  const files = [session.path];
  if (session.runtime === "codex") {
    const rollouts: string[] = [];
    rolloutsIn(root, rollouts);
    files.push(...rollouts.filter((p) => p !== session.path && rolloutOf(p, session.id)));
  }
  const under = (path: string) => {
    const rel = relative(root, path);
    if (rel.startsWith("..") || rel === "") throw new Error(`${path} is not the machine's`);
    return rel;
  };
  for (const from of files) {
    const to = join(shared, under(from));
    mkdirSync(dirname(to), { recursive: true });
    const partial = to.replace(/\.jsonl$/, "") + ".jsonl.part";
    copyFileSync(from, partial);
    renameSync(partial, to);
  }
  return join(shared, under(session.path));
}

/// Goes on in a chat with a session the machine's own Claude Code or Codex kept (run in a terminal). Its transcript is
/// copied into the shared transcripts (the original is left as it was, and can go on in the terminal on its own); the
/// new session resumes it, running in the directory it ran in. The chat starts with a note of where it came from,
/// linking to the session's execution history, which shows what was said before (it is not copied into the chat). A
/// session already going on with it is that one's chat, brought back if archived.
export function continueMachineSession(hub: Hub, roots: Roots, found: MachineSession, createdBy: string, lang: Lang = stationLang()): [string, ThreadRow] {
  const { store } = hub;
  const runtime = found.runtime;
  // One it went on in (a runtime session left for a new one included).
  const going = store.listSessions().find((r) => store.runtimeSessions(r.key).some((ran) => ran.runtime === runtime && ran.id === found.id));
  if (going) {
    const thread = store.homeChat(going.key);
    if (thread) {
      if (going.archivedAt !== null) {
        // Its files come back before its runtime starts in any case: a failure here is only told.
        void Promise.resolve()
          .then(() => archive(hub, going.key, false))
          .catch((error) => log.warn("hub", "archived session not shown again", { session: going.key, error: (error as Error).message }));
      }
      return [going.key, thread];
    }
  }
  if (!(statSync(found.cwd, { throwIfNoEntry: false })?.isDirectory() ?? false)) throw new Error(tr(lang, "station.session.cwdGone", { cwd: found.cwd }));
  if (unreadableDir(found.cwd)) throw new Error(unreadableDirMessage(lang, found.cwd));
  const config = hub.config();
  const profiles = hub.accounts.candidates(runtime, null, lang);
  if (profiles.length === 0) throw new Error(tr(lang, "station.session.noProfile", { runtime: runtimeTitle(runtime) }));
  // The model it ran, where a profile has it enabled; else the one picked runs its own.
  const keptModel = found.model !== null && profiles.some((p) => p.models.includes(found.model!)) ? found.model : null;
  const profile = hub.accounts.pick(profiles, keptModel, false);
  const model = keptModel ?? profile.model ?? profile.models[0] ?? null;
  const copy = copyTranscript(roots, found, join(config.dataDir, "transcripts", runtime));
  // Where its execution history is when it comes here: its last entry, read as the history reads it (from the file the
  // profile's home finds).
  const read = transcriptPath(runtime, profile.home, found.id) ?? copy;
  const entries = readTimeline(runtime, read).length;
  const last = entries > 0 ? entries - 1 : null;
  const key = newChatKey();
  const workspace = join(config.dataDir, "sessions", INTERNAL_CONNECT, key.slice(INTERNAL_CONNECT.length + 1), "workspace");
  mkdirSync(workspace, { recursive: true });
  mkdirSync(join(config.dataDir, "repos"), { recursive: true });
  const now = hub.now();
  const titleOf = found.title ?? found.first;
  const title = titleOf !== null ? Array.from(titleOf).slice(0, 80).join("") : null;
  store.insertSession({
    key,
    connect: INTERNAL_CONNECT,
    scope: "all",
    title,
    createdBy,
    runtime,
    profile: profile.id,
    profilePinned: false,
    model,
    effort: null,
    fast: null,
    workspace,
    cwd: found.cwd,
    runtimeSessionId: found.id,
    token: newToken(),
    createdAt: now,
    lastActiveAt: now,
  });
  log.info("hub", "session continued from the machine's own", { session: key, runtime, profile: profile.id, from: found.id, cwd: found.cwd });
  const thread = openChat(hub, key, createdBy, title);
  // What was said before stays in its transcript: the note links to the session's execution history, which shows it, at
  // where it was when it came here (the pages open `?history=<session>&entry=<n>` links there).
  const at = last !== null ? `&entry=${last}` : "";
  const note = tr(lang, "station.session.continued", { runtime: runtimeTitle(runtime), cwd: found.cwd, link: `?history=${key}${at}` });
  store.insertMessage({ thread: thread.id, ts: hub.nextTs(), authorKind: "ember", author: "ember", text: note });
  store.setRead(createdBy, thread.id, store.lastEntry(thread.id));
  return [key, thread];
}
