// Tasks between Stations. A Task is a conversation kept on one Station, its host: only the host stores its Messages.
// Sessions of other Stations take part in it, each running on its own Station. A Message is in the Task once the host
// has it; from then on every Station taking part gets it, however long that takes. These requests go between Stations
// over the station transport (Remote hands them here), or over Salix's own connection when Salix is the host:
// - task.invite: the host asks a Station to start a Session for the Task. Answered at once: the Session, or why not
//   (offline, no such model). Nothing is written into the Task either way.
// - task.put: the host gives a Station taking part the Messages after those it had (`sent`, kept by the host for each
//   Session taking part, as a Session here has its deliveries). The Station writes them into its thread of the Task
//   and hands them to its Sessions, then answers. Given again, nothing is written twice. A Station that has no thread
//   of the Task (it lost it) answers `unknown`: it is invited again with what it was first invited with, and given the
//   Task from its start. What its Sessions posted is given as its own (`author.session`), the old Session's too. One
//   whose Sessions of it ended answers `gone`: it is given nothing more.
//   With all a Station is given (a put, and an invite made again) the host says through which Message that Station's
//   Sessions answered the Task already (`answered`: how far it had been given the Task when one of them last ended a
//   turn, all_done or need_help; the host keeps it as their posts arrive). Whatever the Station has of the Task (none
//   after losing it, less after being restored from before), it hands no Session a Message through that.
// - task.post: one of its Sessions writes a Message into the Task (`key`: a post asked again is one Message). Answered
//   at once; a post that fails is the Session's to know.
//   A Message may carry the key steps its agent finished (`milestones`, shown only in the Task's Activity). One of
//   milestones alone (empty text) is given like any, and handed to no Session. The station's word that its Session's
//   turn did not start carries why (`cannot_start`): the host offers to run the Task on another model with it.
// - task.hello: a Station that connected tells the hosts of the Tasks it takes part in, with how far it has each of
//   theirs (`fetched`); each gives it what it missed, from there.
// - task.file: a Station taking part reads a file of a Message it was given (`files`: their names and sizes), a part
//   at a time from where it has it to, into the uploads of its Session there. The Message is written into its thread,
//   and handed to its Sessions, once its files are there; those after it wait for it, so the Task keeps its order.
// - task.posted_file: a Salix host reads a file a Session's post named (`files`: their names and sizes), a part at a
//   time, before it answers the post; the files are read here only while that post waits.
// - task.post_file: to another station as host, the files go first, a part at a time, each from as much as the host
//   has of it (a part given again, or one it was not answered for, goes on from there); the post that names them takes
//   them, whole, into the Task's chat.
// - task.status: the host asks a Station where its Session of the Task stands (running, waiting, idle, cannot_start,
//   gone; what is pending, for how long, why its last start failed). A read: it starts no turn and changes nothing.
// - task.invite with `replace`: the Task now runs another model here. A new Session, started as `start` says, takes the
//   part of those here in the Task's thread, which leave it with what was pending for them.
// - task.leave: the Task now runs elsewhere. Sessions here leave its thread with what was pending for them; the thread
//   stays, as what was said.
// - task.app_deploy: a coding Session of a Task kept on Salix with a Mini App (`start.mini_app`, kept beside its
//   workspace) deploys what its agent built (tool app_deploy): its worktree saved and pushed, then packed (coding.ts),
//   the files named as a post's are (`files`), and read by Salix with task.posted_file under the request's `key` while
//   it waits. Asked once more with the same key when it did not get through: one Version. task.app_logs reads the
//   app's recent backend log lines (tool app_logs).
// The host gives a Station what it has not had when a Message is added, when it starts or connects, and when that
// Station says hello. A Station that answered no put of a Station it could reach is given it again, backing off (1 s,
// 2 s… up to a minute) until it has it; one it cannot reach is waited for to say hello.
// A Task here is a chat of the station's own (EMBER/…). A Task elsewhere is a thread here of its own (TASK/…, through the
// `task` connect, which this is the surface of), holding what it was given of it, so its Sessions hear and answer it as
// they do any conversation.
import { createHash, randomUUID } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readSync, readdirSync, renameSync, rmSync, statSync, writeFileSync, appendFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { Effect } from "effect";
import { parseThreadAddress, threadAddress } from "../agents/instructions.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type Attachment, type AuthorKind, type EntryRow, type NewMessage, STILLFAIL_SURFACE, type ThreadRow, milestoneTitles, onlyMilestones } from "../store/store.ts";
import type { ChatSurface, PostFrom, ThreadRef } from "../sessions/chat.ts";
import type { Runtime } from "../sessions/config.ts";
import type { Hub } from "../sessions/hub.ts";
import { INTERNAL_CHANNEL } from "../sessions/internal.ts";
import { imageSize } from "../sessions/image-size.ts";
import { newSession } from "../sessions/lifecycle.ts";
import { Refused, Unreachable } from "../sessions/neighbours.ts";
import { TASK_CHANNEL, TASK_CONNECT, TASK_SURFACE } from "./names.ts";
import { type Repo, repoOf } from "./coding.ts";

type Json = any;

/// A request to another Station of the workspace (Remote.ask).
export type Call = (station: string, request: Json) => Promise<Json>;

export { TASK_CHANNEL, TASK_CONNECT, TASK_SURFACE };
export const INVITE = "task.invite";
export const PUT = "task.put";
export const POST = "task.post";
export const HELLO = "task.hello";
export const STATUS = "task.status";
export const FILE = "task.file";
export const LEAVE = "task.leave";
/// To a station host: a part of a file of the post a Session is about to make (`key`), before that post.
export const POST_FILE = "task.post_file";
export const METHODS = [INVITE, PUT, POST, HELLO, STATUS, FILE, LEAVE, POST_FILE];
/// About a coding Session (tasks/coding.ts), from Salix only: its changes, saving its work, a pull request.
export const DIFF = "task.diff";
export const SAVE = "task.save";
export const PULL_REQUEST = "task.pull_request";
export const CODING_METHODS = [DIFF, SAVE, PULL_REQUEST];
/// From Salix only: a part of a file a Session's task.post named (`files`), while that post waits for its answer.
export const POSTED_FILE = "task.posted_file";
/// To Salix only, from a coding Session of a Task with a Mini App: a deploy of what it built, and the app's backend log.
export const APP_DEPLOY = "task.app_deploy";
export const APP_LOGS = "task.app_logs";
/// At most this much in a deploy's notes.
const MAX_NOTES = 2000;
/// From Salix only: a page of the execution history of the Session taking part in a Task, and its token usage.
export const HISTORY = "task.history";
/// Entries one task.history page has at most, by default and at all; and its entries' text in bytes at most.
const HISTORY_PAGE = 100;
const HISTORY_PAGE_MAX = 200;
const HISTORY_PAGE_BYTES = 600 * 1024;
/// Salix's Router reads a Task of this station's own (a chat on its page) and writes in it, over the station's own
/// connection to Salix only (the connector's request table): no other Station asks these.
export const READ = "task.read";
export const SAY = "task.say";
/// Messages one task.read answers at most.
export const READ_LIMIT = 100;

/// Messages one put gives at most.
export const PUT_LIMIT = 100;
/// At most this much text in one Message (a peer request is bounded at 1 MiB).
const MAX_TEXT = 200_000;
/// Bytes one task.file answers at most (a peer request is bounded at 1 MiB, and base64 adds a third).
export const FILE_PART = 256 * 1024;
/// The largest file of a Message a Station taking part fetches; and the most a Session's post to a station host brings.
export const MAX_TASK_FILE = 1024 * 1024 * 1024;
/// Files one post to a station host brings at most.
const POST_FILES = 20;
/// Files given for a post that was never made are kept this long.
const STAGED_KEPT_MS = 24 * 60 * 60 * 1000;
/// A put not answered by a Station that could be reached is given again after 1 s, then 2 s, 4 s… at most this long.
export const PUT_AGAIN_MAX_MS = 60_000;
const DECLARED = ["all_done", "need_help", "waiting"];

/// What a Station asked to start a Session for a Task is told of it.
export type TaskStart = { runtime?: Runtime | null; model?: string | null; effort?: string | null; title?: string | null; requester: string; repo?: Repo | null };

/// A Message as task.put gives it. `author.session`: the Session of the receiver's that posted it, one it has now or
/// one a Session there took the place of since.
/// `id`: the Message's own id at the host, where it has one (Salix), which task.file names it by with its seq. `files`:
/// what it brings, each by its `index` among the Message's parts. `milestones`: the key steps its agent recorded with
/// it; a Message of milestones alone has empty text, and no Session is handed it.
export type TaskMessage = {
  seq: number; author: { kind: AuthorKind; id: string; session?: string }; text: string; declared: string | null; at: number;
  id?: string; files?: TaskFile[]; milestones?: string[];
};

/// A file of a Task's Message, as task.put names it.
export type TaskFile = { index: number; name: string; size: number };

const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key].trim() : "");
const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);
const chars = (s: string) => Array.from(s).length;
/// An entry that is a Message of the Task: something said, or milestones recorded alone.
const isMessage = (e: EntryRow) => e.kind === "message" || e.kind === "milestone";
/// Milestones a peer gave; none when they do not read (a put is not refused for them).
const givenMilestones = (value: Json): string[] | null => {
  try {
    return milestoneTitles(value);
  } catch {
    return null;
  }
};
/// The files a Message given by put brings, as named well enough to fetch.
const files = (m: TaskMessage): TaskFile[] =>
  Array.isArray(m?.files) ? m.files.filter((f) => count(f?.index) !== null && typeof f?.name === "string" && f.name !== "" && count(f?.size) !== null) : [];
/// A file's name as it is kept here: no separators or control characters, nor leading dots.
const safeName = (name: string) =>
  Array.from(name)
    .map((c) => (c === "\\" || c === "/" || c.codePointAt(0)! < 0x20 ? "_" : c))
    .join("")
    .replace(/^\.+/, "") || "file";
/// A Message's ts in a Task's thread elsewhere: its seq at the host, so what a Session posted and what is given back are one.
export const seqTs = (seq: number) => `${seq}.000000`;

/// One Station's part in one Task here: what is being given to it now, and whether to give again once that is done.
/// The same for a Task elsewhere whose Messages are being written here as their files arrive.
type Giving = { running: boolean; again: boolean; failures: number; retry: boolean };

/// What a file part read from the host said: its bytes, or why there are none (it holds no such file any more).
class Missing extends Error {}

/// A part of `file` from `offset`, at most FILE_PART bytes (base64); `missing` when it is no longer on disk.
function readPart(file: Attachment, offset: number): Json {
  let fd: number;
  try {
    fd = openSync(file.path, "r");
  } catch {
    return { missing: "no longer on its station" };
  }
  try {
    const size = statSync(file.path).size;
    const part = Buffer.alloc(Math.max(0, Math.min(FILE_PART, size - offset)));
    const read = part.length > 0 ? readSync(fd, part, 0, part.length, offset) : 0;
    return { name: file.name, size, offset, data: part.subarray(0, read).toString("base64") };
  } finally {
    closeSync(fd);
  }
}

export class Tasks implements ChatSurface {
  private readonly hub: Hub;
  private readonly call: () => Call | null;
  /// By `${thread} ${station}`: one put at a time to each Station taking part in each Task.
  private readonly giving = new Map<string, Giving>();
  /// By thread: the Messages of a Task elsewhere written in as their files arrive, one at a time.
  private readonly arriving = new Map<number, Giving>();
  private unsubscribe: (() => void) | null = null;
  /// Stations reached otherwise than the station transport: Salix, over a connector's connection (null while it is
  /// not connected).
  private readonly hosts = new Map<string, ((request: Json) => Promise<Json>) | null>();
  /// The files of the Sessions' posts a Salix has not answered yet, by the post's key: it reads them (task.posted_file)
  /// before it answers.
  private readonly posting = new Map<string, { task: string; session: string; files: Attachment[] }>();

  constructor(hub: Hub, call: () => Call | null) {
    this.hub = hub;
    this.call = call;
  }

  private get db() {
    return this.hub.store.db;
  }

  /// Gives the Stations taking part in Tasks here what is said in them, from now on and what they have not had yet.
  begin(): void {
    this.unsubscribe = this.hub.store.subscribe((change) => {
      if (change.type !== "thread" || !change.entries.some(isMessage)) return;
      for (const station of new Set(this.taking(change.id).map((s) => s.station))) this.give(change.id, station);
    });
    this.giveAll();
    this.arriveAll();
  }

  end(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  /// This Station is on the station transport again (its roster is current): the hosts of Tasks Sessions here take
  /// part in are told, and the Stations taking part in Tasks here are given what they have not had.
  connected(): void {
    const hosts = this.db.prepare("SELECT DISTINCT station FROM tasks_elsewhere").all() as { station: string }[];
    for (const { station } of hosts) if (!this.hosts.has(station)) this.hello(station);
    this.giveAll();
    this.arriveAll();
  }

  /// How to ask `host` now, a Station reached over its own connection (Salix: connector/connector.ts); null when it
  /// is not connected. Once connected, it is told so.
  attachHost(host: string, ask: ((request: Json) => Promise<Json>) | null): void {
    this.hosts.set(host, ask);
    if (ask !== null) {
      this.hello(host);
      this.arriveAll();
    }
  }

  /// How to ask `host` now, a Station reached over its own connection; null when it is not connected.
  host(host: string): ((request: Json) => Promise<Json>) | null {
    return this.hosts.get(host) ?? null;
  }

  /// Tells `host` this Station is here, and how far it has each of its Tasks that Sessions here still take part in: it
  /// gives what they have not had, and tells to leave those that run elsewhere now. A Task they left is named no more.
  private hello(host: string): void {
    const tasks = this.db
      .prepare("SELECT task, fetched FROM tasks_elsewhere te WHERE station = ? AND EXISTS (SELECT 1 FROM thread_sessions ts WHERE ts.thread = te.thread) ORDER BY thread")
      .all(host) as { task: string; fetched: number }[];
    this.via()(host, { method: HELLO, tasks: tasks.map(({ task, fetched }) => ({ task, fetched })) }).catch((error) => log.info("tasks", "a host was not told this station is here", { host, error: (error as Error).message }));
  }

  /// How `station` is asked: over its own connection when it has one, else the station transport.
  private via(): Call {
    const call = this.call();
    return (station, request) => {
      if (this.hosts.has(station)) {
        const ask = this.hosts.get(station);
        return ask ? ask(request) : Promise.reject(new Unreachable(`station ${station} is not connected`));
      }
      return call ? call(station, request) : Promise.reject(new Unreachable("other stations cannot be reached from this one yet"));
    };
  }

  /// The models Sessions here can run, by runtime: what the profiles have enabled, each once. For a desktop connection's
  /// host, only those its Workspace's account source lets its Sessions run on (none for a runtime under `none`).
  models(host?: string): Record<string, string[]> {
    const models: Record<string, string[]> = {};
    const profiles = this.hub.config().profiles;
    for (const runtime of [...new Set(profiles.flatMap((p) => p.runtimes))]) {
      let usable = profiles.filter((p) => p.runtimes.includes(runtime));
      try {
        usable = this.hub.accounts.candidates(runtime, host ?? null);
      } catch {
        usable = [];
      }
      const known = (models[runtime] = [] as string[]);
      for (const profile of usable) for (const model of profile.models) if (!known.includes(model)) known.push(model);
    }
    return models;
  }

  // ── the host's side ────────────────────────────────────────────────────────────────────────────────────────────

  /// The Sessions of other Stations taking part in Task `thread` here.
  taking(thread: number): { station: string; session: string }[] {
    return this.db.prepare("SELECT station, session FROM task_sessions WHERE thread = ? ORDER BY joined_at, rowid").all(thread) as { station: string; session: string }[];
  }

  /// Asks `station` to start a Session for Task `thread` here; it takes part from then on and is given the Task from
  /// its start. The Session's key there. Fails as `station` answers: offline, or it cannot run it.
  async invite(thread: number, station: string, start: TaskStart): Promise<string> {
    const row = this.hosted(thread);
    const answer = await this.via()(station, { method: INVITE, task: threadAddress(row.channel, row.threadTs), start });
    const session = text(answer, "session");
    if (session === "") throw new Error(`station ${station} started no Session`);
    this.db
      .prepare("INSERT OR IGNORE INTO task_sessions (thread, station, session, joined_at, start, answered) VALUES (?, ?, ?, ?, ?, 0)")
      .run(thread, station, session, this.hub.now(), JSON.stringify(start));
    log.info("tasks", "a session of another station takes part", { thread, station, session });
    this.give(thread, station);
    return session;
  }

  /// Task `thread` here runs on `station` from now on, as `start` says (its runtime, model and effort; `requester`, who
  /// asks), as Salix moves a Task of its own (SalixIM.TaskRun): `station` is asked to run it first (task.invite, with
  /// `replace` when its Session runs it already), and one that cannot leaves all as it was. Then the Task's run before
  /// leaves it: the Station it ran on (task.leave), or the chat's own sessions, whose turn is stopped and which are handed
  /// nothing of it from then on (what was pending for them is given up). The new Session takes part, given the Task
  /// from its start and handed what was not answered yet. Its session there.
  async moveTo(thread: number, station: string, start: TaskStart): Promise<string> {
    const row = this.hosted(thread);
    const task = threadAddress(row.channel, row.threadTs);
    const was = this.hub.store.runsOn(thread);
    const own = this.hub.store.threadSessions(thread).map((m) => m.session);
    const answered = was === null ? this.hub.store.answeredBy(thread, own) : this.answered(thread, was);
    const before = this.db.prepare("SELECT session FROM task_sessions WHERE thread = ? AND station = ?").all(thread, station) as { session: string }[];
    const replace = before.length > 0;
    const answer = await this.via()(station, { method: INVITE, task, start, ...(replace ? { replace: true } : {}), ...(answered > 0 ? { answered } : {}) });
    const session = text(answer, "session");
    if (session === "") throw new Error(`station ${station} started no Session`);
    // A Station from before `replace` answers with the Session it had: it cannot run the Task another way.
    if (replace && before.some((b) => b.session === session)) throw new Error(`station ${station} is too old to run the Task another way: update it first`);
    this.db.prepare("DELETE FROM task_sessions WHERE thread = ? AND station = ?").run(thread, station);
    this.db
      .prepare("INSERT INTO task_sessions (thread, station, session, joined_at, sent, start, answered) VALUES (?, ?, ?, ?, 0, ?, ?)")
      .run(thread, station, session, this.hub.now(), JSON.stringify(start), answered);
    this.hub.store.setRunsOn(thread, station);
    if (was !== null && was !== station) await this.leaveRun(thread, was);
    if (was === null) {
      for (const key of own) {
        this.hub.store.dropPending(thread, key);
        this.hub.stop(key, true).catch((error) => log.warn("tasks", "a session whose Task runs elsewhere was not stopped", { session: key, error: (error as Error).message }));
      }
    }
    log.info("tasks", "a task here runs on another station", { thread, station, session, was });
    this.give(thread, station);
    return session;
  }

  /// Task `thread` here runs on the chat's own sessions again: the Station it ran on leaves it (task.leave), and they go
  /// on afresh in a new runtime session each (they read back what was done meanwhile, sessions/afresh.ts), handed what
  /// that Station had not answered. Nothing when it runs here.
  async moveHome(thread: number): Promise<void> {
    const row = this.hosted(thread);
    const was = this.hub.store.runsOn(thread);
    if (was === null) return;
    const answered = this.answered(thread, was);
    await this.leaveRun(thread, was);
    this.hub.store.setRunsOn(thread, null);
    const own = this.hub.store.threadSessions(thread).map((m) => m.session);
    for (const key of own) this.hub.store.leaveRuntimeSession(key);
    // What it had not answered: what people (and Salix's Router) said after, not what the Station's Sessions posted.
    const prefix = `${was}/`;
    for (const e of this.hub.store.entriesAfter(row.id, answered)) {
      if (e.kind !== "message" || e.text === null || (e.authorKind === "agent" && e.author.startsWith(prefix))) continue;
      this.hub.deliver(row.id, e.n, own, e.text);
    }
    log.info("tasks", "a task here runs on its own sessions again", { thread, was });
  }

  /// `station` runs Task `thread` here no more: it is told to leave it (task.leave), and given nothing of it again. One
  /// that cannot be told now is told when it says hello.
  private async leaveRun(thread: number, station: string): Promise<void> {
    const row = this.hosted(thread);
    this.db.prepare("DELETE FROM task_sessions WHERE thread = ? AND station = ?").run(thread, station);
    await this.via()(station, { method: LEAVE, task: threadAddress(row.channel, row.threadTs) }).catch((error) =>
      log.info("tasks", "a station that ran a task was not told to leave it; it is told when it says hello", { thread, station, error: (error as Error).message }),
    );
  }

  private hosted(thread: number): ThreadRow {
    const row = this.hub.store.getThread(thread);
    if (!row || row.surface !== STILLFAIL_SURFACE) throw new Error(`no Task ${thread} here`);
    return row;
  }

  /// Every Station taking part in a Task here is given what it has not had.
  private giveAll(): void {
    const parts = this.db.prepare("SELECT DISTINCT thread, station FROM task_sessions").all() as { thread: number; station: string }[];
    for (const { thread, station } of parts) this.give(thread, station);
  }

  /// Gives `station` the Messages of Task `thread` it has not had. One put at a time; asked meanwhile, once more after.
  give(thread: number, station: string): void {
    const key = `${thread} ${station}`;
    const giving = this.giving.get(key) ?? { running: false, again: false, failures: 0, retry: false };
    this.giving.set(key, giving);
    if (giving.running) {
      giving.again = true;
      return;
    }
    giving.running = true;
    giving.retry = false;
    void this.giveNow(thread, station).then(
      () => {
        giving.failures = 0;
        this.given(key, giving, thread, station);
      },
      (error: Error) => {
        if (error instanceof Unreachable) {
          // Not reachable: it says hello when it is.
          giving.failures = 0;
          log.info("tasks", "a station taking part cannot be reached; it is given what it missed when it says hello", { thread, station, error: error.message });
        } else {
          giving.failures++;
          const wait = Math.min(PUT_AGAIN_MAX_MS, 1000 * 2 ** (giving.failures - 1));
          log.warn("tasks", "a station taking part did not take what it was given; given again", { thread, station, wait, error: error.message });
          giving.retry = true;
          this.hub.fork(
            Effect.sleep(wait).pipe(
              Effect.andThen(
                Effect.sync(() => {
                  if (giving.retry && !giving.running) this.give(thread, station);
                }),
              ),
            ),
          );
        }
        this.given(key, giving, thread, station);
      },
    );
  }

  private given(key: string, giving: Giving, thread: number, station: string): void {
    giving.running = false;
    if (giving.again) {
      giving.again = false;
      this.give(thread, station);
    } else if (!giving.retry && giving.failures === 0) this.giving.delete(key);
  }

  /// Puts what `station` has not had of Task `thread`, a part at a time, until it has all.
  private async giveNow(thread: number, station: string): Promise<void> {
    const row = this.hub.store.getThread(thread);
    if (!row) return;
    const task = threadAddress(row.channel, row.threadTs);
    let invitedAgain = false;
    for (;;) {
      const sent = this.db.prepare("SELECT MIN(sent) AS sent FROM task_sessions WHERE thread = ? AND station = ?").get(thread, station) as { sent: number | null };
      if (sent.sent === null) return;
      const messages: TaskMessage[] = [];
      let through = sent.sent;
      for (const entry of this.hub.store.entriesAfter(thread, sent.sent)) {
        if (isMessage(entry)) {
          if (messages.length === PUT_LIMIT) break;
          messages.push(this.message(entry, station));
        }
        through = entry.n;
      }
      if (through === sent.sent) return;
      const answered = this.answered(thread, station);
      const answer = await this.via()(station, { method: PUT, task, messages, through, ...(answered > 0 ? { answered } : {}) });
      if (answer?.unknown === true) {
        // Invited again once; still unknown after that is a Station not answering as it should: given again later.
        if (invitedAgain) throw new Error(`station ${station} does not know Task ${task} it was invited to again`);
        invitedAgain = true;
        await this.inviteAgain(row, station, answered);
        continue;
      }
      if (answer?.gone === true) {
        // Its Sessions of the Task are no more (deleted there): nothing is given to it again.
        this.db.prepare("DELETE FROM task_sessions WHERE thread = ? AND station = ?").run(thread, station);
        log.info("tasks", "a station no longer takes part in a task", { thread, station });
        return;
      }
      this.db.prepare("UPDATE task_sessions SET sent = MAX(sent, ?) WHERE thread = ? AND station = ?").run(through, thread, station);
    }
  }

  /// `station` has no thread of Task `row` (it lost it): it is invited again as it was first, and told through which
  /// Message its Sessions answered the Task already; its new Session takes the place of those it had, and it is given
  /// the Task from its start. Fails as an invite does.
  private async inviteAgain(row: ThreadRow, station: string, answered: number): Promise<void> {
    const first = this.db.prepare("SELECT start FROM task_sessions WHERE thread = ? AND station = ? ORDER BY joined_at, rowid LIMIT 1").get(row.id, station) as
      | { start: string | null }
      | undefined;
    if (!first) return;
    // Invited before `start` was kept: as the Task's chat says (who made it, its title).
    const start: TaskStart = first.start !== null ? JSON.parse(first.start) : { requester: row.createdBy ?? "", title: row.title };
    const answer = await this.via()(station, { method: INVITE, task: threadAddress(row.channel, row.threadTs), start, ...(answered > 0 ? { answered } : {}) });
    const session = text(answer, "session");
    if (session === "") throw new Error(`station ${station} started no Session`);
    this.db
      .prepare("INSERT OR REPLACE INTO task_sessions (thread, station, session, joined_at, sent, start, answered) VALUES (?, ?, ?, ?, 0, ?, ?)")
      .run(row.id, station, session, this.hub.now(), JSON.stringify(start), answered);
    this.db.prepare("DELETE FROM task_sessions WHERE thread = ? AND station = ? AND session != ?").run(row.id, station, session);
    log.info("tasks", "a station that lost a task was invited to it again", { thread: row.id, station, session });
  }

  /// Through which Message the Sessions of `station` answered Task `thread` already. Kept with them as their posts
  /// arrive (postHere). For those taking part from before it was kept, read once from the Task's entries, by their key
  /// (thread, n): the last Message one of them ended a turn with.
  private answered(thread: number, station: string): number {
    const kept = this.db.prepare("SELECT MAX(COALESCE(answered, 0)) AS most, SUM(answered IS NULL) AS unread FROM task_sessions WHERE thread = ? AND station = ?").get(thread, station) as { most: number | null; unread: number | null };
    if (!kept.unread) return kept.most ?? 0;
    const prefix = `${station}/`;
    const last = this.db
      .prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND substr(author, 1, ?) = ? AND declared IN ('all_done', 'need_help')")
      .get(thread, prefix.length, prefix) as { n: number | null };
    const answered = Math.max(kept.most ?? 0, last.n ?? 0);
    this.db.prepare("UPDATE task_sessions SET answered = ? WHERE thread = ? AND station = ? AND answered IS NULL").run(answered, thread, station);
    return answered;
  }

  private message(entry: EntryRow, peer: string): TaskMessage {
    const prefix = `${peer}/`;
    const author: TaskMessage["author"] = { kind: entry.authorKind, id: entry.author };
    if (entry.authorKind === "agent" && entry.author.startsWith(prefix)) author.session = entry.author.slice(prefix.length);
    const message: TaskMessage = { seq: entry.n, author, text: entry.text ?? "", declared: entry.declared, at: entry.at };
    if (entry.attachments.length > 0) message.files = entry.attachments.map((a, index) => ({ index, name: a.name, size: a.size }));
    if (entry.milestones) message.milestones = entry.milestones;
    return message;
  }

  /// The Task a request from `peer` names, and its Session there, which must take part in it.
  private ofPeer(peer: string, request: Json): { thread: ThreadRow; session: string } {
    const task = text(request, "task");
    const session = text(request, "session");
    const address = parseThreadAddress(task);
    const thread = address && address[0] === INTERNAL_CHANNEL ? this.hub.store.threadAt(STILLFAIL_SURFACE, address[0], address[1]) : null;
    const takes = thread !== null && this.db.prepare("SELECT 1 FROM task_sessions WHERE thread = ? AND station = ? AND session = ?").get(thread.id, peer, session) !== undefined;
    if (!thread || !takes) throw new Error(`session ${session} of station ${peer} takes no part in Task ${task} here`);
    return { thread, session };
  }

  /// task.post from `peer`: a Message of its Session, handed to the Sessions here; its seq. One of milestones alone is
  /// handed to no one.
  private postHere(peer: string, request: Json): Json {
    const { thread, session } = this.ofPeer(peer, request);
    const said = text(request, "text");
    const key = text(request, "key");
    const milestones = milestoneTitles(request?.milestones);
    const named = Array.isArray(request?.files) && request.files.length > 0;
    if ((said === "" && milestones === null && !named) || chars(said) > MAX_TEXT) throw new Error(`text is required (at most ${MAX_TEXT} characters)`);
    if (key === "" || key.length > 128) throw new Error("key is required (at most 128 characters)");
    const posted = this.db.prepare("SELECT n FROM task_posts WHERE thread = ? AND station = ? AND session = ? AND key = ?").get(thread.id, peer, session, key) as { n: number } | undefined;
    if (posted) return { seq: posted.n };
    const attachments = this.takeStaged(peer, thread, session, key, request?.files);
    const only = said === "" && attachments.length === 0;
    const declared = !only && DECLARED.includes(text(request, "declared")) ? text(request, "declared") : null;
    this.answered(thread.id, peer);
    const [n] = this.hub.store.insertMessage({ thread: thread.id, ts: this.hub.nextTs(), authorKind: "agent", author: `${peer}/${session}`, text: said, attachments, declared, milestones });
    rmSync(this.staged(peer, thread.id, session, key), { recursive: true, force: true });
    // A post that ends a turn: its Session answered what `peer` had been given by then, no further than this Message.
    // One it was not given yet is not answered by it.
    if (declared === "all_done" || declared === "need_help") {
      this.db.prepare("UPDATE task_sessions SET answered = MAX(COALESCE(answered, 0), MIN(sent, ?)) WHERE thread = ? AND station = ?").run(n, thread.id, peer);
    }
    this.db.prepare("INSERT OR IGNORE INTO task_posts (thread, station, session, key, n) VALUES (?, ?, ?, ?, ?)").run(thread.id, peer, session, key, n);
    if (!only) this.hub.deliver(thread.id, n, this.hub.store.threadSessions(thread.id).map((m) => m.session), said);
    return { seq: n };
  }

  /// Where the files given for post `key` of `peer`'s Session in Task `thread` here are kept until it is made.
  private staged(peer: string, thread: number, session: string, key: string): string {
    const id = createHash("sha256").update(JSON.stringify([peer, thread, session, key])).digest("hex").slice(0, 32);
    return join(this.hub.config().dataDir, "task-posts", id);
  }

  /// task.post_file from `peer`: a part of file `index` (`name`, `size`) of the post `key` its Session is about to make
  /// in a Task here, from `offset`. Kept only from as much as is here of it (one given again, or past it, is not
  /// written), until that post takes it. How much is here now (`have`).
  private postFileHere(peer: string, request: Json): Json {
    const { thread, session } = this.ofPeer(peer, request);
    const key = text(request, "key");
    const index = count(request?.index);
    const size = count(request?.size);
    const offset = count(request?.offset) ?? 0;
    if (key === "" || key.length > 128) throw new Error("key is required (at most 128 characters)");
    if (index === null || index >= POST_FILES) throw new Error(`a post brings at most ${POST_FILES} files`);
    if (size === null || size > MAX_TASK_FILE) throw new Error(`a file is at most ${MAX_TASK_FILE / 1024 / 1024} MB`);
    const dir = this.staged(peer, thread.id, session, key);
    if (!existsSync(dir)) {
      this.sweepStaged();
      mkdirSync(dir, { recursive: true });
    }
    const part = join(dir, String(index));
    if (!existsSync(part)) writeFileSync(part, "");
    const have = statSync(part).size;
    if (offset !== have || have >= size) return { have };
    const limit = Math.min(FILE_PART, size - have);
    const data = typeof request?.data === "string" && request.data.length <= 4 * Math.ceil(limit / 3) ? Buffer.from(request.data, "base64") : null;
    if (data === null || data.length === 0 || data.length > limit) throw new Error(`an invalid part of file ${index} at ${have}`);
    appendFileSync(part, data);
    return { have: have + data.length };
  }

  /// The files post `key` of `peer`'s Session names (`files`: each `index`, `name`, `size`), given whole beforehand
  /// (postFileHere), as they are kept in the uploads of the chat's own session. Refused when one is not whole.
  private takeStaged(peer: string, thread: ThreadRow, session: string, key: string, named: Json): Attachment[] {
    if (!Array.isArray(named) || named.length === 0) return [];
    if (named.length > POST_FILES) throw new Error(`a post brings at most ${POST_FILES} files`);
    const files = named.map((f: Json) => ({ index: count(f?.index), name: typeof f?.name === "string" ? f.name : "", size: count(f?.size) }));
    if (files.some((f) => f.index === null || f.name === "" || f.size === null)) throw new Error("each file is named by its index, name and size");
    if (files.reduce((sum, f) => sum + f.size!, 0) > MAX_TASK_FILE) throw new Error(`a post brings at most ${MAX_TASK_FILE / 1024 / 1024} MB of files`);
    const dir = this.staged(peer, thread.id, session, key);
    for (const f of files) {
      const part = join(dir, String(f.index));
      if (!existsSync(part) || statSync(part).size !== f.size) throw new Error(`file ${f.name} of the post was not given whole first (task.post_file)`);
    }
    const own = thread.home ?? this.hub.store.threadSessions(thread.id)[0]?.session;
    const row = own ? this.hub.store.getSession(own) : null;
    if (!row) throw new Error("the Task here has no session to keep its files");
    const uploads = join(row.workspace, "uploads");
    mkdirSync(uploads, { recursive: true });
    return files.map((f) => {
      const path = join(uploads, `posted-${basename(dir).slice(0, 12)}-${f.index}-${safeName(f.name)}`);
      renameSync(join(dir, String(f.index)), path);
      const attachment: Attachment = { name: f.name, path, size: f.size! };
      const size = /\.(png|jpe?g|gif|webp)$/i.test(f.name) ? imageSize(path) : null;
      if (size) [attachment.width, attachment.height] = size;
      return attachment;
    });
  }

  /// Removes the files given for posts never made, once kept STAGED_KEPT_MS.
  private sweepStaged(): void {
    const root = join(this.hub.config().dataDir, "task-posts");
    let names: string[];
    try {
      names = readdirSync(root);
    } catch {
      return;
    }
    const now = this.hub.now();
    for (const name of names) {
      const dir = join(root, name);
      try {
        if (now - statSync(dir).mtimeMs > STAGED_KEPT_MS) rmSync(dir, { recursive: true, force: true });
      } catch {}
    }
  }

  /// task.hello from `peer`: it is here; it is given what it has not had of every Task here it takes part in. With
  /// `tasks` (how far it has each), it is given each from there: one it has less of than it was given (restored from
  /// before) is given the rest again, and one it does not name it has none of (its put answers `unknown`, so it is
  /// invited again). Without (a Station from before `tasks`), from what it was given.
  private helloHere(peer: string, request: Json): Json {
    const threads = this.db.prepare("SELECT DISTINCT thread FROM task_sessions WHERE station = ?").all(peer) as { thread: number }[];
    const had = Array.isArray(request?.tasks) ? new Map((request.tasks as Json[]).map((t) => [text(t, "task"), count(t?.fetched) ?? 0])) : null;
    const taking = new Set<string>();
    for (const { thread } of threads) {
      const row = this.hub.store.getThread(thread);
      if (row) taking.add(threadAddress(row.channel, row.threadTs));
      if (row && had !== null) {
        const fetched = had.get(threadAddress(row.channel, row.threadTs)) ?? 0;
        this.db.prepare("UPDATE task_sessions SET sent = ? WHERE thread = ? AND station = ? AND sent > ?").run(fetched, thread, peer, fetched);
      }
      this.give(thread, peer);
    }
    // A Task here it names but runs no more (it moved while that Station was away): it is told to leave it now.
    for (const task of had?.keys() ?? []) {
      if (taking.has(task)) continue;
      const ref = parseThreadAddress(task);
      if (!ref || ref[0] !== INTERNAL_CHANNEL || !this.hub.store.threadAt(STILLFAIL_SURFACE, ref[0], ref[1])) continue;
      this.via()(peer, { method: LEAVE, task }).catch((error) => log.info("tasks", "a station was not told to leave a task it runs no more", { station: peer, task, error: (error as Error).message }));
    }
    return {};
  }

  /// task.file from `peer`: a part of a file of a Message of the Task its Session takes part in, from `offset`, at
  /// most FILE_PART bytes (base64). `missing` when the Message has no such file, or it is no longer here.
  private fileHere(peer: string, request: Json): Json {
    const { thread } = this.ofPeer(peer, request);
    const seq = count(request?.seq);
    const index = count(request?.index);
    const offset = count(request?.offset) ?? 0;
    const entry = seq === null ? undefined : this.hub.store.entriesBetween(thread.id, seq, seq).find((e) => e.kind === "message");
    const file = index === null ? undefined : entry?.attachments[index];
    if (!file) return { missing: "no such file" };
    return readPart(file, offset);
  }

  /// task.posted_file from a Salix host: a part of file `index` of the post `key` its Session is making, from
  /// `offset`, at most FILE_PART bytes (base64). `missing` when no such post waits for its answer.
  private postedFile(peer: string, request: Json): Json {
    const posting = this.hosts.has(peer) ? this.posting.get(text(request, "key")) : undefined;
    const index = count(request?.index);
    const offset = count(request?.offset) ?? 0;
    if (!posting || posting.task !== text(request, "task") || index === null) return { missing: "no such post" };
    const file = posting.files[index];
    if (!file) return { missing: "no such file" };
    return readPart(file, offset);
  }

  // ── a Station taking part ──────────────────────────────────────────────────────────────────────────────────────

  /// task.invite from the host `peer`: a Session for the Task (one per Task), or why not. `answered` (an invite made
  /// again, to a Station that lost the Task) is kept with the Task's thread, as a put's is. With `replace` (the Task
  /// now runs another model here), a new Session takes the part of those taking part, which leave the thread with what
  /// was pending for them; the host then gives the new one what they had not answered. A thread of the Task kept here
  /// without Sessions (they left it) is taken up by the new Session.
  private async invited(peer: string, request: Json): Promise<Json> {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const start = request?.start;
    if (start === null || typeof start !== "object" || Array.isArray(start)) throw new Error("start is required");
    const thread = this.elsewhere(peer, task);
    const before = thread !== null ? this.hub.store.threadSessions(thread).map((m) => m.session) : [];
    if (before.length > 0 && request?.replace !== true) return { session: before[0] };
    const requester = text(start, "requester");
    if (requester === "") throw new Error("start needs its requester");
    const runtimes = this.hub.config().profiles.flatMap((p) => p.runtimes);
    const runtime = (text(start, "runtime") || (runtimes.includes("claude") ? "claude" : runtimes[0])) as Runtime;
    if (runtime === undefined) throw new Error("this station runs no agents");
    const title = text(start, "title") || null;
    let made: ThreadRow | null = null;
    // What it cannot run (no profile with the model, say) throws here: the host is told why, and nothing is made.
    const [session] = newSession(
      this.hub,
      { runtime, model: text(start, "model") || null, effort: text(start, "effort") || null, title, createdBy: requester, host: peer },
      undefined,
      (key) => {
        const kept = thread !== null ? this.hub.store.getThread(thread) : null;
        made = kept ?? this.hub.store.openThreadOf(TASK_SURFACE, TASK_CHANNEL, this.hub.nextTs(), title, requester, key);
        this.hub.store.joinThread(made.id, key, TASK_CONNECT);
        this.db.prepare("INSERT OR IGNORE INTO tasks_elsewhere (thread, station, task, answered) VALUES (?, ?, ?, ?)").run(made.id, peer, task, count(request?.answered) ?? 0);
        return made;
      },
    );
    for (const old of before) this.quit(made!.id, old);
    log.info("tasks", "a session takes part in a task of another station", { station: peer, task, session, replaced: before });
    this.checkout(session, start);
    return { session, thread: threadAddress(made!.channel, made!.threadTs) };
  }

  /// A coding Session (`start.repo`) works in a checkout of its repository: made now, its turns held until it is. One
  /// that cannot be made is said in the Task.
  private checkout(session: string, start: Json): void {
    const repo = repoOf(start);
    const coding = this.hub.coding;
    if (repo === null) return;
    const row = this.hub.store.getSession(session);
    if (coding === null || !row) {
      log.warn("tasks", "a coding task came to a station that runs no repositories", { session });
      return;
    }
    const app = text(start?.mini_app, "app_id");
    if (app !== "") coding.keepMiniApp(row.workspace, app);
    void this.hub.prepare(session, coding.checkout(session, row.workspace, repo)).catch((error) => {
      log.warn("tasks", "a coding session's checkout was not made", { session, error: (error as Error).message });
      void this.hub.notice(session, `The repository ${repo.owner}/${repo.name} could not be checked out: ${(error as Error).message}`);
    });
  }

  /// A Session no longer runs Task `thread`: it leaves the thread with what was pending for it, so it is handed nothing
  /// more of the Task and the host refuses what it posts there. The turn it runs, or the wait it is in, is asked to stop
  /// (the runtime's interrupt), not waited for: the actor takes the stop in its turn, and a step in progress may finish.
  private quit(thread: number, session: string): void {
    this.hub.store.leaveThread(thread, session);
    this.hub.stop(session).catch((error) => log.warn("tasks", "a session that left a task was not stopped", { session, error: (error as Error).message }));
  }

  /// task.leave from the host `peer`: its Task now runs elsewhere. The Sessions here leave the Task's thread with what
  /// was pending for them, so none starts a turn for it again; the thread stays, as what was said. Nothing here of the
  /// Task is nothing to leave.
  private async left(peer: string, request: Json): Promise<Json> {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const thread = this.elsewhere(peer, task);
    if (thread === null) return {};
    const sessions = this.hub.store.threadSessions(thread).map((m) => m.session);
    for (const session of sessions) this.quit(thread, session);
    log.info("tasks", "sessions left a task that runs elsewhere now", { station: peer, task, sessions });
    return {};
  }

  /// task.put from the host `peer`: Messages of a Task Sessions here take part in, written into its thread here and
  /// handed to them; what was had already is not written again. `unknown` when there is no thread here of it (lost:
  /// the host invites again), `gone` when there is but no Session here takes part any more.
  /// A Message the host says a Session of this Station posted (`author.session`) that is none of those here now is of
  /// the Session one here took the place of (this Station lost the Task and was invited again): it is written as that
  /// Session's. The Messages through `answered` (the most the host said, with this put, one before or the invite) were
  /// answered by this Station's Sessions: they are written as what was said before, and handed to no Session. Those
  /// after are handed over as any are.
  private put(peer: string, request: Json): Json {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const part = this.db.prepare("SELECT thread, answered FROM tasks_elsewhere WHERE station = ? AND task = ?").get(peer, task) as { thread: number; answered: number } | undefined;
    // `gone` too: a host from before `unknown` stops giving it, as it did.
    if (part === undefined) return { unknown: true, gone: true };
    const thread = part.thread;
    const sessions = this.hub.store.threadSessions(thread).map((m) => m.session);
    if (sessions.length === 0) return { gone: true };
    const answered = Math.max(part.answered, count(request?.answered) ?? 0);
    if (answered > part.answered) this.answeredThrough(thread, answered);
    let waiting = this.db.prepare("SELECT 1 FROM task_arrivals WHERE thread = ? LIMIT 1").get(thread) !== undefined;
    for (const m of Array.isArray(request?.messages) ? (request.messages as TaskMessage[]) : []) {
      if (count(m?.seq) === null || typeof m.text !== "string") continue;
      // Nothing to write: no words, files or milestones.
      if (m.text === "" && files(m).length === 0 && givenMilestones(m.milestones) === null) continue;
      // One with files is written once they are here, and those after it after it: kept until then.
      if (waiting || files(m).length > 0) {
        if (this.hub.store.messageAt(thread, seqTs(m.seq)) !== null) continue;
        this.db.prepare("INSERT OR IGNORE INTO task_arrivals (thread, seq, message) VALUES (?, ?, ?)").run(thread, m.seq, JSON.stringify(m));
        waiting = true;
      } else this.write(peer, thread, m, []);
    }
    const through = count(request?.through);
    if (through !== null) this.db.prepare("UPDATE tasks_elsewhere SET fetched = MAX(fetched, ?) WHERE thread = ?").run(through, thread);
    if (waiting) this.arrive(thread);
    return { through };
  }

  /// Writes Message `m` of the Task elsewhere that `thread` is, with its files fetched here, and hands it to the
  /// Sessions here, unless they answered it already.
  private write(peer: string, thread: number, m: TaskMessage, attachments: Attachment[]): void {
    const sessions = this.hub.store.threadSessions(thread).map((s) => s.session);
    const answered = (this.db.prepare("SELECT answered FROM tasks_elsewhere WHERE thread = ?").get(thread) as { answered: number } | undefined)?.answered ?? 0;
    const own = typeof m.author?.session === "string" ? (sessions.includes(m.author.session) ? m.author.session : (sessions[0] ?? null)) : null;
    const kind: AuthorKind = own !== null ? "agent" : m.author?.kind === "person" || m.author?.kind === "agent" ? m.author.kind : "ember";
    const author = own ?? (typeof m.author?.id === "string" && m.author.id !== "" ? m.author.id : peer);
    const said: NewMessage = {
      thread, ts: seqTs(m.seq), authorKind: kind, author, text: m.text, attachments, declared: own !== null ? m.declared : null,
      milestones: givenMilestones(m.milestones),
    };
    const [n] = this.hub.store.insertMessage(said);
    // Handed over again when given again: a Session that had it already is not given it twice. Milestones alone are
    // handed to no one.
    if (m.seq > answered && !onlyMilestones(said)) this.hub.deliver(thread, n, sessions.filter((s) => s !== own), m.text);
  }

  /// Every Task elsewhere with Messages waiting for their files goes on fetching them.
  private arriveAll(): void {
    for (const { thread } of this.db.prepare("SELECT DISTINCT thread FROM task_arrivals").all() as { thread: number }[]) this.arrive(thread);
  }

  /// Writes the Messages of Task elsewhere `thread` that wait, in order, each once its files are fetched. One at a
  /// time; asked meanwhile, once more after. A host that cannot be reached is waited for (it is fetched from again once
  /// it is); one that is reached and fails is asked again, backing off.
  private arrive(thread: number): void {
    const arriving = this.arriving.get(thread) ?? { running: false, again: false, failures: 0, retry: false };
    this.arriving.set(thread, arriving);
    if (arriving.running) {
      arriving.again = true;
      return;
    }
    arriving.running = true;
    arriving.retry = false;
    void this.arriveNow(thread).then(
      () => {
        arriving.failures = 0;
        this.arrived(thread, arriving);
      },
      (error: Error) => {
        if (error instanceof Unreachable) {
          arriving.failures = 0;
          log.info("tasks", "the host of a task cannot be reached; its files are fetched when it can", { thread, error: error.message });
        } else {
          arriving.failures++;
          const wait = Math.min(PUT_AGAIN_MAX_MS, 1000 * 2 ** (arriving.failures - 1));
          log.warn("tasks", "a file of a task was not fetched; fetched again", { thread, wait, error: error.message });
          arriving.retry = true;
          this.hub.fork(
            Effect.sleep(wait).pipe(
              Effect.andThen(
                Effect.sync(() => {
                  if (arriving.retry && !arriving.running) this.arrive(thread);
                }),
              ),
            ),
          );
        }
        this.arrived(thread, arriving);
      },
    );
  }

  private arrived(thread: number, arriving: Giving): void {
    arriving.running = false;
    if (arriving.again) {
      arriving.again = false;
      this.arrive(thread);
    } else if (!arriving.retry && arriving.failures === 0) this.arriving.delete(thread);
  }

  private async arriveNow(thread: number): Promise<void> {
    for (;;) {
      const next = this.db.prepare("SELECT seq, message FROM task_arrivals WHERE thread = ? ORDER BY seq LIMIT 1").get(thread) as { seq: number; message: string } | undefined;
      const where = this.where(thread);
      if (!next || !where) return;
      const m = JSON.parse(next.message) as TaskMessage;
      // A crash after delivery can leave the arrival queued. The runtime may have edited its files.
      if (this.hub.store.messageAt(thread, seqTs(m.seq)) !== null) {
        this.db.prepare("DELETE FROM task_arrivals WHERE thread = ? AND seq = ?").run(thread, m.seq);
        continue;
      }
      const attachments: Attachment[] = [];
      const missing: string[] = [];
      for (const file of files(m)) {
        try {
          attachments.push(await this.fetchFile(thread, where, m, file));
        } catch (error) {
          if (!(error instanceof Missing)) throw error;
          log.warn("tasks", "a file of a task is not fetched", { thread, seq: m.seq, file: file.name, error: error.message });
          missing.push(tr(stationLang(), "station.slack.fileNotFetched", { name: file.name, error: error.message }));
        }
      }
      const said = { ...m, text: [m.text, ...missing].filter((t) => t !== "").join("\n\n") };
      if (this.hub.store.messageAt(thread, seqTs(m.seq)) === null) this.write(where.station, thread, said, attachments);
      this.db.prepare("DELETE FROM task_arrivals WHERE thread = ? AND seq = ?").run(thread, m.seq);
    }
  }

  /// Fetches `file` of Message `m` from the host into the uploads of the Session here, from as much of it as it has
  /// already (a fetch cut off goes on from there). Missing when the host no longer has it or it is too large.
  private async fetchFile(thread: number, where: { station: string; task: string }, m: TaskMessage, file: TaskFile): Promise<Attachment> {
    if (file.size > MAX_TASK_FILE) throw new Missing(`over ${MAX_TASK_FILE / 1024 / 1024} MB`);
    const session = this.hub.store.threadSessions(thread)[0]?.session;
    const row = session ? this.hub.store.getSession(session) : null;
    if (!session || !row) throw new Missing("no Session here to give it to");
    const dir = join(row.workspace, "uploads");
    const path = join(dir, `task-${m.seq}-${file.index}-${safeName(file.name)}`);
    const part = join(dir, `.part-task-${thread}-${m.seq}-${file.index}`);
    if (!existsSync(path) || statSync(path).size !== file.size) {
      mkdirSync(dir, { recursive: true });
      if (!existsSync(part) || statSync(part).size > file.size) writeFileSync(part, "");
      // The Message fixes the size. A reply cannot change it or exceed one chunk or the remaining bytes.
      for (let have = statSync(part).size; have < file.size; ) {
        const answer = await this.via()(where.station, { method: FILE, task: where.task, session, seq: m.seq, ...(m.id ? { id: m.id } : {}), index: file.index, offset: have });
        if (typeof answer?.missing === "string") throw new Missing(answer.missing);
        const limit = Math.min(FILE_PART, file.size - have);
        const data = typeof answer?.data === "string" && answer.data.length <= 4 * Math.ceil(limit / 3) ? Buffer.from(answer.data, "base64") : null;
        if (count(answer?.size) !== file.size || count(answer?.offset) !== have || data === null || data.length === 0 || data.length > limit) {
          throw new Error(`station ${where.station} returned an invalid part of ${file.name} at ${have}`);
        }
        appendFileSync(part, data);
        have += data.length;
      }
      if (statSync(part).size !== file.size) throw new Error(`download of ${file.name} does not match its announced size`);
      renameSync(part, path);
    }
    const attachment: Attachment = { name: file.name, path, size: statSync(path).size };
    if (attachment.size !== file.size) throw new Error(`download of ${file.name} does not match its announced size`);
    const size = /\.(png|jpe?g|gif|webp)$/i.test(file.name) ? imageSize(path) : null;
    if (size) [attachment.width, attachment.height] = size;
    return attachment;
  }

  /// The host said the Sessions of this Station answered Task `thread` through `seq`: kept, and what was handed to a
  /// Session through it and waits to be heard (this Station was restored from before it was answered) waits no more.
  private answeredThrough(thread: number, seq: number): void {
    this.db.prepare("UPDATE tasks_elsewhere SET answered = ? WHERE thread = ?").run(seq, thread);
    const waiting = this.db
      .prepare(
        "SELECT d.session, d.n FROM deliveries d JOIN entries e ON e.thread = d.thread AND e.n = d.n WHERE d.thread = ? AND d.delivered_at IS NULL AND e.ts IS NOT NULL AND CAST(e.ts AS INTEGER) <= ?",
      )
      .all(thread, seq) as { session: string; n: number }[];
    for (const { session, n } of waiting) this.hub.store.markDelivered(session, [[thread, n]]);
  }

  /// task.status from the host `peer`: where the Session here taking part in its Task stands (`session`, or the one
  /// taking part when it names none). `gone` when there is no thread here of the Task, or no such Session takes part.
  /// A read: it starts no turn and changes nothing.
  private async statusHere(peer: string, request: Json): Promise<Json> {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const gone = { state: "gone", pending: 0, for_ms: null, last_failure: null };
    const thread = this.elsewhere(peer, task);
    if (thread === null) return gone;
    const sessions = this.hub.store.threadSessions(thread).map((m) => m.session);
    const asked = text(request, "session");
    const session = asked !== "" ? (sessions.includes(asked) ? asked : null) : (sessions[0] ?? null);
    if (session === null) return gone;
    const status = this.hub.sessionStatus(session);
    const row = this.hub.store.getSession(session);
    const standing = row && this.hub.coding ? await this.hub.coding.standing(row.workspace).catch(() => null) : null;
    return standing === null ? status : { ...status, ...standing };
  }

  /// task.history from a Salix host: the entries of the execution history of the Session taking part in `task` before
  /// entry `before` (all), the latest `limit` (HISTORY_PAGE, at most HISTORY_PAGE_MAX) of them that fit a page, with the
  /// index of the first (`start`), how many there are (`total`), and the tokens its model calls used.
  private executionHistory(peer: string, request: Json): Json {
    const thread = this.hosts.has(peer) ? this.elsewhere(peer, text(request, "task")) : null;
    const session = thread === null ? undefined : this.hub.store.threadSessions(thread)[0]?.session;
    if (session === undefined) return { start: 0, total: 0, entries: [], usage: null };
    const { entries, usage } = this.hub.history(session);
    const end = Math.min(count(request?.before) ?? entries.length, entries.length);
    const limit = Math.min(Math.max(count(request?.limit) ?? HISTORY_PAGE, 1), HISTORY_PAGE_MAX);
    let start = Math.max(0, end - limit);
    // The newest of them first: older ones drop off past the page's bytes.
    let bytes = 0;
    for (let i = end - 1; i >= start; i--) {
      bytes += Buffer.byteLength(entries[i]!.text) + 256;
      if (bytes > HISTORY_PAGE_BYTES) {
        start = i + 1;
        break;
      }
    }
    return { start, total: entries.length, entries: entries.slice(start, end), usage };
  }

  /// task.diff, task.save, task.pull_request from Salix: about the coding Session taking part in its Task.
  private async coding(peer: string, method: string, request: Json): Promise<Json> {
    const thread = this.elsewhere(peer, text(request, "task"));
    const session = thread === null ? undefined : this.hub.store.threadSessions(thread)[0]?.session;
    const row = session === undefined ? undefined : this.hub.store.getSession(session);
    const coding = this.hub.coding;
    if (!row || coding === null || coding.get(row.workspace) === null) throw new Error("no coding session takes part in this task here");
    if (method === DIFF) {
      const commit = text(request, "commit");
      if (commit !== "" && !/^[0-9a-f]{40}$/.test(commit)) throw new Error("a commit is named by its full sha");
      return await coding.diff(row.workspace, commit !== "" ? { commit } : { uncommitted: request?.uncommitted === true });
    }
    if (method === SAVE) return await coding.save(row.workspace);
    return await coding.pullRequest(row.workspace, {
      title: text(request, "title") || undefined,
      body: typeof request?.body === "string" ? request.body : undefined,
      draft: request?.draft === true,
    });
  }

  /// The thread here of Task `task` on `station`, if Sessions here take part in it.
  private elsewhere(station: string, task: string): number | null {
    const row = this.db.prepare("SELECT thread FROM tasks_elsewhere WHERE station = ? AND task = ?").get(station, task) as { thread: number } | undefined;
    return row?.thread ?? null;
  }

  private where(thread: number): { station: string; task: string } | null {
    return (this.db.prepare("SELECT station, task FROM tasks_elsewhere WHERE thread = ?").get(thread) as { station: string; task: string } | undefined) ?? null;
  }

  // ── requests from other Stations ───────────────────────────────────────────────────────────────────────────────

  /// A task.* request from `peer`, a Station of the workspace (the transport checked it).
  async handle(peer: string, request: Json): Promise<Json> {
    const method = text(request, "method");
    if (method === INVITE) return this.invited(peer, request);
    if (method === PUT) return this.put(peer, request);
    if (method === POST) return this.postHere(peer, request);
    if (method === HELLO) return this.helloHere(peer, request);
    if (method === STATUS) return this.statusHere(peer, request);
    if (method === LEAVE) return this.left(peer, request);
    if (method === FILE) return this.fileHere(peer, request);
    if (method === POSTED_FILE) return this.postedFile(peer, request);
    if (method === POST_FILE) return this.postFileHere(peer, request);
    if (method === READ) return this.readHere(request);
    if (method === SAY) return this.sayHere(peer, request);
    if (CODING_METHODS.includes(method)) return await this.coding(peer, method, request);
    if (method === HISTORY) return this.executionHistory(peer, request);
    throw new Error(`unsupported task method: ${method}`);
  }

  /// A Task of this station's own: its page chat at `task` (its address, as the Task index gives it).
  private ownTask(request: Json): ThreadRow {
    const ref = parseThreadAddress(text(request, "task"));
    const row = ref ? this.hub.store.threadAt(STILLFAIL_SURFACE, ref[0], ref[1]) : null;
    if (!row) throw new Error(`no Task ${text(request, "task")} of this station`);
    return row;
  }

  /// task.read from Salix: the Task's Messages after `after` (its n), at most `limit` (READ_LIMIT), oldest first, and
  /// how far the Task goes. A Message's `milestones` are the key steps its agent recorded; one of milestones alone has
  /// empty text.
  private readHere(request: Json): Json {
    const row = this.ownTask(request);
    const after = count(request?.after) ?? 0;
    const limit = Math.min(count(request?.limit) ?? READ_LIMIT, READ_LIMIT);
    const messages = this.hub.store
      .entriesAfter(row.id, after)
      .filter((e) => (e.kind === "message" && e.text !== null) || e.kind === "milestone")
      .slice(0, limit)
      .map((e) => ({
        seq: e.n, author_kind: e.authorKind, author: e.author, text: e.text ?? "", at: e.at, declared: e.declared,
        ...(e.milestones ? { milestones: e.milestones } : {}),
      }));
    const last = this.hub.store.entriesBefore(row.id, null, 1).at(-1)?.n ?? 0;
    return { task: text(request, "task"), title: row.title ?? row.autoTitle ?? null, messages, through: last };
  }

  /// task.say from Salix: `requester` (the Router) writes `text` into the Task, and the chat's Sessions are given it.
  /// Said again with the same `key`, it is one Message.
  private sayHere(peer: string, request: Json): Json {
    const row = this.ownTask(request);
    const said = text(request, "text");
    const key = text(request, "key");
    const requester = text(request, "requester") || "Router";
    if (said === "" || chars(said) > MAX_TEXT) throw new Error(`text is required (at most ${MAX_TEXT} characters)`);
    if (key === "" || key.length > 128) throw new Error("key is required (at most 128 characters)");
    const posted = this.db.prepare("SELECT n FROM task_posts WHERE thread = ? AND station = ? AND session = ? AND key = ?").get(row.id, peer, SAY, key) as { n: number } | undefined;
    if (posted) return { seq: posted.n };
    const [n] = this.hub.store.insertMessage({ thread: row.id, ts: this.hub.nextTs(), authorKind: "agent", author: `${peer}/${requester}`, text: said });
    this.db.prepare("INSERT OR IGNORE INTO task_posts (thread, station, session, key, n) VALUES (?, ?, ?, ?, ?)").run(row.id, peer, SAY, key, n);
    this.hub.deliver(row.id, n, this.hub.store.threadSessions(row.id).map((m) => m.session), said);
    return { seq: n };
  }

  // ── the surface of Tasks elsewhere ─────────────────────────────────────────────────────────────────────────────

  botUserId(): string {
    return "";
  }

  workspace(): string | null {
    return null;
  }

  /// A Session's Message, written into the Task at its host: its seq there, as the ts the Message is kept by here.
  /// Not written there, it fails here: the Session is told and may say it again.
  async post(thread: ThreadRef, message: string, files: Attachment[], from?: PostFrom): Promise<string> {
    const row = this.hub.store.threadAt(TASK_SURFACE, thread.channel, thread.threadTs);
    const where = row ? this.where(row.id) : null;
    if (!where) throw new Error(`no Task ${threadAddress(thread.channel, thread.threadTs)} here`);
    // The station's own word about its Session there (a turn that failed, say) is written as that Session's: only the
    // Sessions taking part write in a Task of another station.
    const session = from?.session ?? this.hub.store.threadSessions(row!.id)[0]?.session;
    if (!session) throw new Error("only the Sessions taking part write in a Task of another station");
    const call = this.via();
    const milestones = from?.milestones ?? null;
    // The station's word that its Session's turn did not start: the host offers another model with it.
    const cannotStart = from?.cannotStart ? { cannot_start: { error: from.cannotStart } } : {};
    const request = {
      method: POST, task: where.task, session, text: message, key: randomUUID(), declared: from?.declared ?? null, ...(milestones ? { milestones } : {}), ...cannotStart,
      ...(files.length > 0 ? { files: files.map((f, index) => ({ index, name: f.name, size: f.size })) } : {}),
    };
    // A Salix reads a post's files from here while the post waits (task.posted_file); another station is given them
    // first (task.post_file).
    if (files.length > 0 && this.hosts.has(where.station)) this.posting.set(request.key, { task: where.task, session, files });
    else if (files.length > 0) await this.giveFiles(call, where, session, request.key, files);
    let answer: Json;
    try {
      answer = await askTwice(call, where.station, request);
    } finally {
      this.posting.delete(request.key);
    }
    const seq = count(answer?.seq);
    if (seq === null) throw new Error(`station ${where.station} answered without the Message's seq`);
    return seqTs(seq);
  }

  /// Gives the files of post `key` to the station hosting the Task, a part at a time, each from as much as it has.
  private async giveFiles(call: Call, where: { station: string; task: string }, session: string, key: string, files: Attachment[]): Promise<void> {
    if (files.length > POST_FILES) throw new Error(`a post brings at most ${POST_FILES} files`);
    for (const [index, file] of files.entries()) {
      let have = 0;
      for (;;) {
        const part = readPart(file, have);
        if (typeof part.missing === "string") throw new Error(`${file.name}: ${part.missing}`);
        const answer = await askTwice(call, where.station, { method: POST_FILE, task: where.task, session, key, index, name: file.name, size: part.size, offset: have, data: part.data });
        const now = count(answer?.have);
        if (now === null || now > part.size) throw new Error(`station ${where.station} answered how much it has of ${file.name} wrongly`);
        if (now >= part.size) break;
        if (now <= have && part.data === "") throw new Error(`${file.name} is shorter than it was`);
        have = now;
      }
    }
  }

  // ── Mini Apps ──────────────────────────────────────────────────────────────────────────────────────────────────

  /// The Mini App of the Task kept on Salix that coding Session `session` takes part in, with where the Task is and
  /// the Session's workspace; null when it has none (the tools app_deploy and app_logs are not offered to it).
  miniApp(session: string): { appId: string; station: string; task: string; workspace: string } | null {
    const coding = this.hub.coding;
    const row = this.hub.store.getSession(session);
    if (coding === null || !row || coding.get(row.workspace) === null) return null;
    const appId = coding.miniApp(row.workspace);
    if (appId === null) return null;
    const where = this.db
      .prepare("SELECT te.station, te.task FROM tasks_elsewhere te JOIN thread_sessions ts ON ts.thread = te.thread WHERE ts.session = ? ORDER BY te.thread DESC LIMIT 1")
      .get(session) as { station: string; task: string } | undefined;
    if (!where || !this.hosts.has(where.station)) return null;
    return { appId, station: where.station, task: where.task, workspace: row.workspace };
  }

  private ofMiniApp(session: string) {
    const app = this.miniApp(session);
    if (app === null) throw new Error("This session's Task has no Mini App: app_deploy and app_logs work only in a Task that builds one.");
    return app;
  }

  /// Deploys what the agent of coding Session `session` built as a new preview Version of its Task's Mini App: the
  /// worktree saved and pushed (as task.save does), packed (coding.ts) beside the workspace, and named in
  /// task.app_deploy, whose files Salix reads (task.posted_file under its `key`) before it answers. Not got through,
  /// asked once more with the same key: one Version. The Version Salix made, or why it made none.
  async appDeploy(session: string, notes: string): Promise<Json> {
    const app = this.ofMiniApp(session);
    if (chars(notes) > MAX_NOTES) throw new Error(`notes are at most ${MAX_NOTES} characters`);
    const coding = this.hub.coding!;
    const key = randomUUID();
    const out = join(dirname(app.workspace), "app-deploys", key);
    try {
      const subject = notes.split("\n")[0]!.trim().slice(0, 72);
      const { commit, files } = await coding.packApp(app.workspace, out, subject !== "" ? `Deploy: ${subject}` : "Deploy the Mini App");
      const request = {
        method: APP_DEPLOY, task: app.task, session, key, app_id: app.appId, commit, notes,
        files: files.map((f, index) => ({ index, name: f.name, size: f.size })),
      };
      this.posting.set(key, { task: app.task, session, files });
      try {
        return await askTwice(this.via(), app.station, request);
      } finally {
        this.posting.delete(key);
      }
    } finally {
      rmSync(out, { recursive: true, force: true });
    }
  }

  /// The recent backend log lines of the Mini App of the Task coding Session `session` takes part in (of `version`,
  /// else of the latest), as Salix reads them.
  async appLogs(session: string, version: number | null): Promise<string[]> {
    const app = this.ofMiniApp(session);
    const answer = await this.via()(app.station, { method: APP_LOGS, task: app.task, session, app_id: app.appId, ...(version !== null ? { version } : {}) });
    if (typeof answer?.error === "string") throw new Error(typeof answer.message === "string" ? answer.message : answer.error);
    return Array.isArray(answer?.lines) ? answer.lines.filter((l: unknown) => typeof l === "string") : [];
  }
}

/// Asks `station`; a request that did not get through (neither refused nor unreachable) is asked once more, the same
/// (its `key` makes it one).
async function askTwice(call: Call, station: string, request: Json): Promise<Json> {
  try {
    return await call(station, request);
  } catch (error) {
    if (error instanceof Refused || error instanceof Unreachable) throw error;
    return await call(station, request);
  }
}
