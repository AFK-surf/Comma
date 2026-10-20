// GET /events (the Rust station's admin/events.rs): what changed, as it changes, pushed. Changes that come in a burst go out
// as one event per session, and one round of sidebar rows; a thread's entries go out as they are written; `host` adds
// host samples, `job` a job's output as it grows, `live` sessions as they run. Keepalives and host samples only while
// someone follows. The same event names and data as the Rust station's; each event now also carries an `id:` (its
// sequence number): clients from before ignore it.
//
// Where the Rust re-read a job's log every second, a log is watched (fs.watch); the sidebar rows of a viewer are read
// once per round for all their streams, off the main thread (the readers).
import { type FSWatcher, existsSync, statSync, watch } from "node:fs";
import type { Viewer } from "../mesh/credential.ts";
import type { Lang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import type { Readers } from "../read/pool.ts";
import type { StoreChange } from "../store/rows.ts";
import type { Answer } from "./request.ts";
import type { Clock } from "effect";
import { Fibers } from "../ops/fibers.ts";

const PING_MS = 25_000;
const HOST_MS = 10_000;

/// What the events need of the rest of the station.
export type EventsDeps = {
  readers: Readers;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  subscribe(listener: (change: StoreChange) => void): () => void;
  /// A host sample (GET /host's answer).
  host(): Promise<unknown>;
  /// A job's log path and how its lines are read (jobs.rs `tail`, `output_at`).
  jobLog(id: string): string | null;
  tail(path: string, lines: number): string;
  outputAt(path: string): number | null;
  /// A session's live steps, from `from`, to `send`, until the returned function is called (live.rs).
  live?(key: string, from: number, last: number | null, send: (message: unknown) => void): () => void;
  /// Whether a session is still there (a summary is told only of one that is).
  sessionExists(key: string): boolean;
  /// The overview as `viewer` sees it, in `lang` (GET /overview); none until the agents' side is up.
  overview?(viewer: Viewer, lang: Lang): Promise<unknown>;
  /// A session's process state (the overview counts running and warm ones).
  processState?(key: string): string;
  /// Someone follows again, after nobody did (allowances are read again then).
  followed?(): void;
};

type Client = {
  id: number;
  viewer: Viewer;
  lang: Lang;
  host: boolean;
  /// The sidebar rows last sent to it, by id (as JSON).
  rows: Map<string, string>;
  send(event: string, data: unknown): void;
  raw(text: string): void;
  /// What it follows besides (live sessions, job logs): ended with it.
  stops: (() => void)[];
};

export class Events {
  private clients: Client[] = [];
  private next = 1;
  private seq = 0;
  private deps: EventsDeps;
  private dirty = { sessions: new Set<string>(), rowsAll: false, rows: new Set<string>(), overview: false };
  /// The process state last told per session.
  private states = new Map<string, string>();
  private flushing: Promise<void> | null = null;
  private time: Fibers;
  private timers: (() => void)[] = [];
  private lastHost = "";

  constructor(deps: EventsDeps) {
    this.deps = deps;
    this.time = new Fibers("events", deps.clock);
    deps.subscribe((change) => this.storeChanged(change));
  }

  /// Where `live` sessions are followed from, the overview and process states (the agents' side, once it is made).
  follow(more: Pick<EventsDeps, "live" | "overview" | "processState" | "followed">) {
    Object.assign(this.deps, more);
  }

  /// Something the overview shows changed (config, accounts, connects, cloud, updates).
  overviewChanged() {
    this.dirty.overview = true;
    this.wake();
  }

  inUse(): boolean {
    return this.clients.length > 0;
  }

  /// The sidebar rows of `viewer` (everyone's when null) may have changed.
  rowsChanged(viewer: string | null) {
    if (viewer === null) this.dirty.rowsAll = true;
    else this.dirty.rows.add(viewer);
    this.wake();
  }

  /// Opens a stream for `viewer`: the sidebar as it is now is remembered, so later changes are told against it.
  async open(viewer: Viewer, lang: Lang, host: boolean, live: [string, number, number | null][], logs: [string, number][]): Promise<Answer> {
    const queue: string[] = [];
    let wakeReader: (() => void) | null = null;
    let closed = false;
    const push = (text: string) => {
      if (closed) return;
      queue.push(text);
      wakeReader?.();
    };
    const client: Client = {
      id: this.next++,
      viewer,
      lang,
      host,
      rows: new Map(),
      send: (event, data) => push(`id: ${++this.seq}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
      raw: push,
      stops: [],
    };
    push("retry: 3000\n\n");
    try {
      const rows = JSON.parse(await this.deps.readers.read("chats", { viewer, archived: false }, lang)) as any[];
      client.rows = new Map(rows.map((r) => [String(r.id ?? ""), JSON.stringify(r)]));
    } catch (error) {
      log.warn("events", "sidebar rows not read", { error: (error as Error).message });
    }
    // Those sessions as they run, on this same stream: each message a `live` event with its key.
    for (const [key, from, last] of live) {
      const stop = this.deps.live?.(key, from, last, (message) => client.send("live", { ...(message as object), key }));
      if (stop) client.stops.push(stop);
    }
    // Those jobs' last lines: a `job-log` event now, and again each time the log changes, until the stream goes.
    for (const [id, lines] of logs) client.stops.push(this.followLog(client, id, lines));
    if (host) void this.deps.host().then((info) => client.send("host", info), () => {});
    this.clients.push(client);
    if (this.clients.length === 1) {
      this.startTimers();
      this.deps.followed?.();
    }
    const remove = () => {
      if (closed) return;
      closed = true;
      wakeReader?.();
      this.clients = this.clients.filter((c) => c !== client);
      client.stops.forEach((stop) => stop());
      if (this.clients.length === 0) this.stopTimers();
    };
    // The stream lasts as long as its reader: when it goes (the mesh stream closed), the client does, at once (an
    // async generator would end only once its pending wait woke up).
    const body: AsyncIterableIterator<Buffer> = {
      [Symbol.asyncIterator]: () => body,
      next: async () => {
        while (!closed && queue.length === 0) await new Promise<void>((resolve) => (wakeReader = resolve));
        wakeReader = null;
        if (queue.length === 0) return { done: true, value: undefined };
        return { done: false, value: Buffer.from(queue.shift()!) };
      },
      return: async () => {
        remove();
        return { done: true, value: undefined };
      },
    };
    return {
      status: 200,
      headers: { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive", "x-accel-buffering": "no" },
      body,
    };
  }

  /// A job's last `lines` of output (`job-log`: id, lines, text, outputAt): at once, then whenever its log changes.
  private followLog(client: Client, id: string, lines: number): () => void {
    const path = this.deps.jobLog(id);
    if (path === null) return () => {};
    let seen = "";
    const tell = () => {
      let now = "none";
      try {
        const st = statSync(path);
        now = `${st.size}:${st.mtimeMs}`;
      } catch {}
      if (now === seen) return;
      seen = now;
      client.send("job-log", { id, lines, text: existsSync(path) ? this.deps.tail(path, lines) : "", outputAt: this.deps.outputAt(path) });
    };
    tell();
    let watcher: FSWatcher | null = null;
    let pending: (() => void) | null = null;
    const soon = () => {
      // A burst of writes is one event.
      if (pending) return;
      pending = this.time.after(200, () => {
        pending = null;
        tell();
      });
    };
    const follow = () => {
      if (watcher) return;
      try {
        watcher = watch(path, { persistent: false }, soon);
        watcher.on("error", () => {
          watcher?.close();
          watcher = null;
        });
      } catch {
        // No log yet: the check below finds it once the job writes one.
      }
    };
    follow();
    // A log that was not there yet, or was written anew (its watch then ends), is found again here.
    const check = this.time.every(5_000, () => {
      follow();
      tell();
    });
    return () => {
      watcher?.close();
      check();
      pending?.();
    };
  }

  private startTimers() {
    this.timers.push(this.time.every(PING_MS, () => this.clients.forEach((c) => c.raw(": ping\n\n"))));
    this.timers.push(
      this.time.every(HOST_MS, () => {
        if (!this.clients.some((c) => c.host)) return;
        void this.deps.host().then((info: any) => {
          const { checkedAt: _a, uptimeSec: _b, ...shown } = info ?? {};
          const key = JSON.stringify(shown);
          if (key === this.lastHost) return;
          this.lastHost = key;
          for (const c of this.clients) if (c.host) c.send("host", info);
        });
      }),
    );
  }

  private stopTimers() {
    for (const stop of this.timers) stop();
    this.timers = [];
    this.lastHost = "";
  }

  private emit(event: string, data: unknown, to: (c: Client) => boolean = () => true) {
    for (const c of this.clients) if (to(c)) c.send(event, data);
  }

  private storeChanged(change: StoreChange) {
    switch (change.type) {
      case "session":
        this.dirty.sessions.add(change.key);
        this.rowsChanged(null);
        break;
      case "sessionRemoved":
        this.dirty.sessions.delete(change.key);
        this.states.delete(change.key);
        this.overviewChanged();
        this.emit("session-removed", { key: change.key });
        this.rowsChanged(null);
        break;
      case "thread":
        if (this.clients.length > 0 && change.entries.length > 0) {
          const first = change.entries[0].n;
          const last = change.entries.at(-1)!.n;
          // Entries as the pages show them (with their authors' names), read off the main thread.
          void this.deps.readers
            .read("entries", { viewer: this.clients[0].viewer, thread: change.id, params: [["from", String(first)], ["to", String(last)]] }, this.clients[0].lang)
            .then((text) => this.emit("thread", { id: change.id, entries: JSON.parse(text).entries }), (e) => log.warn("events", "thread event not sent", { error: (e as Error).message }));
        }
        this.rowsChanged(null);
        break;
      case "threadRemoved":
        this.emit("thread-removed", { id: change.id });
        this.rowsChanged(null);
        break;
      case "read":
        this.emit("read", { viewer: change.viewer, thread: change.thread, n: change.n }, (c) => c.viewer.email === change.viewer);
        this.rowsChanged(change.viewer);
        break;
      case "identities":
        // Who the viewer is on Slack: their overview says it, and their rows count it.
        this.overviewChanged();
        this.rowsChanged(change.viewer);
        break;
      case "pins":
      case "dismissed":
        this.rowsChanged(change.viewer);
        break;
      case "job":
        // A job as GET /jobs/:id answers it, so a client holding it puts it in place without reading anything again.
        void this.deps.readers.read("job", { id: change.id }, "zh").then((text) => this.emit("job", JSON.parse(text)), () => {});
        break;
      case "jobRemoved":
        this.emit("job-removed", { id: change.id, session: change.session });
        break;
      case "usage":
        // Model calls were recorded: a page showing usage reads it again (it is too big to send to everyone).
        this.emit("usage", {});
        break;
      case "processes":
      case "decisionChecks":
        this.overviewChanged();
        break;
    }
  }

  /// Changes gathered into one round: after what happens now, once.
  private wake() {
    if (this.flushing) return;
    this.flushing = new Promise<void>((resolve) => setImmediate(resolve)).then(() => this.flush()).finally(() => {
      this.flushing = null;
      if (this.dirty.sessions.size > 0 || this.dirty.rowsAll || this.dirty.rows.size > 0 || this.dirty.overview) this.wake();
    });
  }

  /// One round: an event per changed session, and the sidebar rows that changed, each viewer's in each language their
  /// streams were asked in.
  private async flush() {
    const dirty = this.dirty;
    this.dirty = { sessions: new Set(), rowsAll: false, rows: new Set(), overview: false };
    let overview = dirty.overview;
    for (const key of dirty.sessions) {
      if (!this.deps.sessionExists(key)) continue;
      // The overview counts running and warm sessions.
      const state = this.deps.processState?.(key);
      if (state !== undefined && this.states.get(key) !== state) {
        this.states.set(key, state);
        overview = true;
      }
    }
    if (this.clients.length === 0) return;
    for (const key of dirty.sessions) {
      if (!this.deps.sessionExists(key)) continue;
      try {
        this.emit("session", JSON.parse(await this.deps.readers.read("summary", { key }, "zh")));
      } catch (error) {
        log.warn("events", "session event not sent", { session: key, error: (error as Error).message });
      }
    }
    // The overview to each viewer, in each language their streams were asked in.
    if (overview && this.deps.overview) {
      const seen = new Set<string>();
      const viewers = this.clients.filter((c) => !seen.has(`${c.viewer.email}\0${c.lang}`) && seen.add(`${c.viewer.email}\0${c.lang}`));
      await Promise.all(
        viewers.map(async ({ viewer, lang }) => {
          try {
            const value = await this.deps.overview!(viewer, lang);
            this.emit("overview", value, (c) => c.viewer.email === viewer.email && c.lang === lang);
          } catch (error) {
            log.warn("events", "overview not told", { error: (error as Error).message });
          }
        }),
      );
    }
    if (!dirty.rowsAll && dirty.rows.size === 0) return;
    const seen = new Set<string>();
    const viewers = this.clients.filter((c) => (dirty.rowsAll || dirty.rows.has(c.viewer.email)) && !seen.has(`${c.viewer.email}\0${c.lang}`) && seen.add(`${c.viewer.email}\0${c.lang}`));
    await Promise.all(
      viewers.map(async ({ viewer, lang }) => {
        let rows: any[];
        try {
          rows = JSON.parse(await this.deps.readers.read("chats", { viewer, archived: false }, lang));
        } catch (error) {
          log.warn("events", "sidebar rows not read", { error: (error as Error).message });
          return;
        }
        const now = new Map(rows.map((r) => [String(r.id ?? ""), JSON.stringify(r)]));
        for (const c of this.clients.filter((c) => c.viewer.email === viewer.email && c.lang === lang)) {
          for (const row of rows) {
            const id = String(row.id ?? "");
            if (c.rows.get(id) !== now.get(id)) c.send("chat", row);
          }
          for (const gone of c.rows.keys()) if (!now.has(gone)) c.send("chat-removed", { id: gone });
          c.rows = now;
        }
      }),
    );
  }
}
