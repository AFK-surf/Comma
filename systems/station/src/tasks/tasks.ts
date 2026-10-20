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
// - task.hello: a Station that connected tells the hosts of the Tasks it takes part in, with how far it has each of
//   theirs (`fetched`); each gives it what it missed, from there.
// - task.status: the host asks a Station where its Session of the Task stands (running, waiting, idle, cannot_start,
//   gone; what is pending, for how long, why its last start failed). A read: it starts no turn and changes nothing.
// The host gives a Station what it has not had when a Message is added, when it starts or connects, and when that
// Station says hello. A Station that answered no put of a Station it could reach is given it again, backing off (1 s,
// 2 s… up to a minute) until it has it; one it cannot reach is waited for to say hello.
// A Task here is a chat of the station's own (EMBER/…). A Task elsewhere is a thread here of its own (TASK/…, through the
// `task` connect, which this is the surface of), holding what it was given of it, so its Sessions hear and answer it as
// they do any conversation.
import { randomUUID } from "node:crypto";
import { Effect } from "effect";
import { parseThreadAddress, threadAddress } from "../agents/instructions.ts";
import { log } from "../ops/log.ts";
import { type Attachment, type AuthorKind, type EntryRow, STILLFAIL_SURFACE, type ThreadRow } from "../store/store.ts";
import type { ChatSurface, PostFrom, ThreadRef } from "../sessions/chat.ts";
import type { Runtime } from "../sessions/config.ts";
import type { Hub } from "../sessions/hub.ts";
import { INTERNAL_CHANNEL } from "../sessions/internal.ts";
import { newSession } from "../sessions/lifecycle.ts";
import { Refused, Unreachable } from "../sessions/neighbours.ts";
import { TASK_CHANNEL, TASK_CONNECT, TASK_SURFACE } from "./names.ts";

type Json = any;

/// A request to another Station of the workspace (Remote.ask).
export type Call = (station: string, request: Json) => Promise<Json>;

export { TASK_CHANNEL, TASK_CONNECT, TASK_SURFACE };
export const INVITE = "task.invite";
export const PUT = "task.put";
export const POST = "task.post";
export const HELLO = "task.hello";
export const STATUS = "task.status";
export const METHODS = [INVITE, PUT, POST, HELLO, STATUS];
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
/// A put not answered by a Station that could be reached is given again after 1 s, then 2 s, 4 s… at most this long.
export const PUT_AGAIN_MAX_MS = 60_000;
const DECLARED = ["all_done", "need_help", "waiting"];

/// What a Station asked to start a Session for a Task is told of it.
export type TaskStart = { runtime?: Runtime | null; model?: string | null; effort?: string | null; title?: string | null; requester: string };

/// A Message as task.put gives it. `author.session`: the Session of the receiver's that posted it, one it has now or
/// one a Session there took the place of since.
export type TaskMessage = { seq: number; author: { kind: AuthorKind; id: string; session?: string }; text: string; declared: string | null; at: number };

const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key].trim() : "");
const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);
const chars = (s: string) => Array.from(s).length;
/// A Message's ts in a Task's thread elsewhere: its seq at the host, so what a Session posted and what is given back are one.
export const seqTs = (seq: number) => `${seq}.000000`;

/// One Station's part in one Task here: what is being given to it now, and whether to give again once that is done.
type Giving = { running: boolean; again: boolean; failures: number; retry: boolean };

export class Tasks implements ChatSurface {
  private readonly hub: Hub;
  private readonly call: () => Call | null;
  /// By `${thread} ${station}`: one put at a time to each Station taking part in each Task.
  private readonly giving = new Map<string, Giving>();
  private unsubscribe: (() => void) | null = null;
  /// Stations reached otherwise than the station transport: Salix, over a connector's connection (null while it is
  /// not connected).
  private readonly hosts = new Map<string, ((request: Json) => Promise<Json>) | null>();

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
      if (change.type !== "thread" || !change.entries.some((e) => e.kind === "message")) return;
      for (const station of new Set(this.taking(change.id).map((s) => s.station))) this.give(change.id, station);
    });
    this.giveAll();
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
  }

  /// How to ask `host` now, a Station reached over its own connection (Salix: connector/connector.ts); null when it
  /// is not connected. Once connected, it is told so.
  attachHost(host: string, ask: ((request: Json) => Promise<Json>) | null): void {
    this.hosts.set(host, ask);
    if (ask !== null) this.hello(host);
  }

  /// Tells `host` this Station is here, and how far it has each of its Tasks: it gives what Sessions here have not had.
  private hello(host: string): void {
    const tasks = this.db.prepare("SELECT task, fetched FROM tasks_elsewhere WHERE station = ? ORDER BY thread").all(host) as { task: string; fetched: number }[];
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

  /// The models Sessions here can run, by runtime: what the profiles have enabled, each once.
  models(): Record<string, string[]> {
    const models: Record<string, string[]> = {};
    for (const profile of this.hub.config().profiles) {
      for (const runtime of profile.runtimes) {
        const known = (models[runtime] ??= []);
        for (const model of profile.models) if (!known.includes(model)) known.push(model);
      }
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
        if (entry.kind === "message") {
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
    return { seq: entry.n, author, text: entry.text ?? "", declared: entry.declared, at: entry.at };
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

  /// task.post from `peer`: a Message of its Session, handed to the Sessions here; its seq.
  private postHere(peer: string, request: Json): Json {
    const { thread, session } = this.ofPeer(peer, request);
    const said = text(request, "text");
    const key = text(request, "key");
    if (said === "" || chars(said) > MAX_TEXT) throw new Error(`text is required (at most ${MAX_TEXT} characters)`);
    if (key === "" || key.length > 128) throw new Error("key is required (at most 128 characters)");
    const posted = this.db.prepare("SELECT n FROM task_posts WHERE thread = ? AND station = ? AND session = ? AND key = ?").get(thread.id, peer, session, key) as { n: number } | undefined;
    if (posted) return { seq: posted.n };
    const declared = DECLARED.includes(text(request, "declared")) ? text(request, "declared") : null;
    this.answered(thread.id, peer);
    const [n] = this.hub.store.insertMessage({ thread: thread.id, ts: this.hub.nextTs(), authorKind: "agent", author: `${peer}/${session}`, text: said, declared });
    // A post that ends a turn: its Session answered what `peer` had been given by then, no further than this Message.
    // One it was not given yet is not answered by it.
    if (declared === "all_done" || declared === "need_help") {
      this.db.prepare("UPDATE task_sessions SET answered = MAX(COALESCE(answered, 0), MIN(sent, ?)) WHERE thread = ? AND station = ?").run(n, thread.id, peer);
    }
    this.db.prepare("INSERT OR IGNORE INTO task_posts (thread, station, session, key, n) VALUES (?, ?, ?, ?, ?)").run(thread.id, peer, session, key, n);
    this.hub.deliver(thread.id, n, this.hub.store.threadSessions(thread.id).map((m) => m.session), said);
    return { seq: n };
  }

  /// task.hello from `peer`: it is here; it is given what it has not had of every Task here it takes part in. With
  /// `tasks` (how far it has each), it is given each from there: one it has less of than it was given (restored from
  /// before) is given the rest again, and one it does not name it has none of (its put answers `unknown`, so it is
  /// invited again). Without (a Station from before `tasks`), from what it was given.
  private helloHere(peer: string, request: Json): Json {
    const threads = this.db.prepare("SELECT DISTINCT thread FROM task_sessions WHERE station = ?").all(peer) as { thread: number }[];
    const had = Array.isArray(request?.tasks) ? new Map((request.tasks as Json[]).map((t) => [text(t, "task"), count(t?.fetched) ?? 0])) : null;
    for (const { thread } of threads) {
      const row = had !== null ? this.hub.store.getThread(thread) : undefined;
      if (row) {
        const fetched = had!.get(threadAddress(row.channel, row.threadTs)) ?? 0;
        this.db.prepare("UPDATE task_sessions SET sent = ? WHERE thread = ? AND station = ? AND sent > ?").run(fetched, thread, peer, fetched);
      }
      this.give(thread, peer);
    }
    return {};
  }

  // ── a Station taking part ──────────────────────────────────────────────────────────────────────────────────────

  /// task.invite from the host `peer`: a Session for the Task (one per Task), or why not. `answered` (an invite made
  /// again, to a Station that lost the Task) is kept with the Task's thread, as a put's is.
  private invited(peer: string, request: Json): Json {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const start = request?.start;
    if (start === null || typeof start !== "object" || Array.isArray(start)) throw new Error("start is required");
    const thread = this.elsewhere(peer, task);
    const already = thread !== null ? this.hub.store.threadSessions(thread)[0]?.session : undefined;
    if (already !== undefined) return { session: already };
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
      { runtime, model: text(start, "model") || null, effort: text(start, "effort") || null, title, createdBy: requester },
      undefined,
      (key) => {
        made = this.hub.store.openThreadOf(TASK_SURFACE, TASK_CHANNEL, this.hub.nextTs(), title, requester, key);
        this.hub.store.joinThread(made.id, key, TASK_CONNECT);
        this.db.prepare("INSERT OR IGNORE INTO tasks_elsewhere (thread, station, task, answered) VALUES (?, ?, ?, ?)").run(made.id, peer, task, count(request?.answered) ?? 0);
        return made;
      },
    );
    log.info("tasks", "a session takes part in a task of another station", { station: peer, task, session });
    return { session, thread: threadAddress(made!.channel, made!.threadTs) };
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
    for (const m of Array.isArray(request?.messages) ? (request.messages as TaskMessage[]) : []) {
      if (count(m?.seq) === null || typeof m.text !== "string") continue;
      const own = typeof m.author?.session === "string" ? (sessions.includes(m.author.session) ? m.author.session : sessions[0]!) : null;
      const kind: AuthorKind = own !== null ? "agent" : m.author?.kind === "person" || m.author?.kind === "agent" ? m.author.kind : "ember";
      const author = own ?? (typeof m.author?.id === "string" && m.author.id !== "" ? m.author.id : peer);
      const [n] = this.hub.store.insertMessage({ thread, ts: seqTs(m.seq), authorKind: kind, author, text: m.text, declared: own !== null ? m.declared : null });
      // Handed over again when given again: a Session that had it already is not given it twice.
      if (m.seq > answered) this.hub.deliver(thread, n, sessions.filter((s) => s !== own), m.text);
    }
    const through = count(request?.through);
    if (through !== null) this.db.prepare("UPDATE tasks_elsewhere SET fetched = MAX(fetched, ?) WHERE thread = ?").run(through, thread);
    return { through };
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
  private statusHere(peer: string, request: Json): Json {
    const task = text(request, "task");
    if (task === "") throw new Error("task is required");
    const gone = { state: "gone", pending: 0, for_ms: null, last_failure: null };
    const thread = this.elsewhere(peer, task);
    if (thread === null) return gone;
    const sessions = this.hub.store.threadSessions(thread).map((m) => m.session);
    const asked = text(request, "session");
    const session = asked !== "" ? (sessions.includes(asked) ? asked : null) : (sessions[0] ?? null);
    if (session === null) return gone;
    return this.hub.sessionStatus(session);
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
    if (method === READ) return this.readHere(request);
    if (method === SAY) return this.sayHere(peer, request);
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
  /// how far the Task goes.
  private readHere(request: Json): Json {
    const row = this.ownTask(request);
    const after = count(request?.after) ?? 0;
    const limit = Math.min(count(request?.limit) ?? READ_LIMIT, READ_LIMIT);
    const messages = this.hub.store
      .entriesAfter(row.id, after)
      .filter((e) => e.kind === "message" && e.text !== null)
      .slice(0, limit)
      .map((e) => ({ seq: e.n, author_kind: e.authorKind, author: e.author, text: e.text, at: e.at, declared: e.declared }));
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
    if (files.length > 0) throw new Error("files cannot be posted to a Task on another station yet: name them in the text");
    const row = this.hub.store.threadAt(TASK_SURFACE, thread.channel, thread.threadTs);
    const where = row ? this.where(row.id) : null;
    if (!where) throw new Error(`no Task ${threadAddress(thread.channel, thread.threadTs)} here`);
    // The station's own word about its Session there (a turn that failed, say) is written as that Session's: only the
    // Sessions taking part write in a Task of another station.
    const session = from?.session ?? this.hub.store.threadSessions(row!.id)[0]?.session;
    if (!session) throw new Error("only the Sessions taking part write in a Task of another station");
    const call = this.via();
    const request = { method: POST, task: where.task, session, text: message, key: randomUUID(), declared: from?.declared ?? null };
    let answer: Json;
    try {
      answer = await call(where.station, request);
    } catch (error) {
      // Not got through: asked once more with the same key, so it is not written twice.
      if (error instanceof Refused || error instanceof Unreachable) throw error;
      answer = await call(where.station, request);
    }
    const seq = count(answer?.seq);
    if (seq === null) throw new Error(`station ${where.station} answered without the Message's seq`);
    return seqTs(seq);
  }
}
