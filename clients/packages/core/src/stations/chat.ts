// One chat on a station, as its page shows it (`stationChat`): its latest page of entries, older pages as asked, new
// entries as the station's `thread` events bring them (a gap is read), its agents as the station's chat row says, and
// what is being sent from here. A message sent goes into the chat's outbox, kept on this device, and to the station
// with its own key: sent again (a retry, or the next start), the station answers it as it answered the first, so it
// is never posted twice. It leaves the outbox once the chat holds it. A chat a session does not have yet is made when
// the first message is sent to it.
//
// Bounds: per open chat, one read of its summary and latest page when it opens and again when its station's stream
// opens again; one read per gap and per older page asked; one read mark per newest message seen.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect } from "effect";
import { route } from "../api.ts";
import type {
  StationAttachment,
  StationChatAgent,
  StationChatMessage,
  StationChatValue,
  StationOutgoing,
} from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { fromBase64 } from "../record.ts";
import type { StationActivity } from "./activity.ts";
import type { Stations } from "./index.ts";
import {
  entriesSchema,
  sentSchema,
  threadEventSchema,
  threadSchema,
  uploadedSchema,
  type StationChatRow,
  type StationEntry,
  type StationThread,
} from "./station-api.ts";
import { agentState, cardShown, firstLine, type Viewer } from "./views.ts";

/** The most a message's files may weigh, together. */
export const UPLOAD_MAX_BYTES = 8 * 1024 * 1024;
const PAGE = 50;

type Outgoing = StationOutgoing & {
  attachments: StationAttachment[];
  /** The write's key: the station answers it again as it answered the first. */
  key: string;
  /** The chat's last entry when it was added: a message of mine after it with its text is it. */
  after: number;
  /** Its entry, once the station took it. */
  seq?: number;
};

type Open = {
  workspace: string;
  station: string;
  thread: number;
  /** Topics showing it. */
  shown: number;
  view: StationThread | null;
  entries: Map<number, StationEntry>;
  /** The lowest entry held (more before it when above 1). */
  first: number | null;
  loading: boolean;
  error: string | undefined;
  /** The newest message the station was told the viewer read. */
  readSent: number;
};

const outboxDoc = (station: string, thread: number) =>
  `stations.outbox.${station}.${thread}`;
const keyOf = (station: string, thread: number) => `${station}\t${thread}`;
const sameEmail = (a: string, b: string) =>
  a.trim().toLowerCase() === b.trim().toLowerCase();

const params = {
  text(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  thread(raw: unknown): number {
    const v = (raw as Record<string, unknown> | null)?.thread;
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0)
      throw CoreError.invalid("thread is required");
    return v;
  },
};

export class StationChats {
  readonly #ctx: Ctx;
  readonly #stations: Stations;
  readonly #activity: StationActivity;
  readonly #open = new Map<string, Open>();
  /** Outboxes by chat, loaded from this device as a chat first needs its own. */
  readonly #outboxes = new Map<string, Outgoing[]>();
  /** The chats sessions got made here, by `station\tsession`. */
  readonly #made = new Map<string, number>();
  #nextId = 1;

  constructor(ctx: Ctx, stations: Stations, activity: StationActivity) {
    this.#ctx = ctx;
    this.#stations = stations;
    this.#activity = activity;
    ctx.kernel.source("stationChat", {
      start: (topic) => this.#show(topic),
      stop: (topic) => this.#hide(topic),
      compute: (topic): Value => ({ ok: this.#value(topic) }),
      // Each step of a message going out is shown (sending, then in the chat).
      coalesce: false,
    });
    activity.onEvent((station, event, value) => this.#event(station, event, value));
    activity.onOpened((station) => {
      for (const open of this.#open.values())
        if (open.station === station) this.#fork(open, this.#refresh(open));
    });
    stations.onChange((workspace) => {
      for (const open of this.#open.values())
        if (open.workspace === workspace) this.#changed(open);
    });
    stations.onAccount(() => {
      this.#open.clear();
      this.#outboxes.clear();
      this.#made.clear();
    });

    ctx.kernel.calls({
      "stations.send": {
        run: (p) => {
          const workspace = params.text(p, "workspace");
          const station = params.text(p, "station");
          const raw = (p ?? {}) as Record<string, unknown>;
          const text = typeof raw.text === "string" ? raw.text.trim() : "";
          if (text.length > 100_000) throw CoreError.invalid("text is too long");
          const attachments = attachmentsOf(raw.attachments);
          if (text === "" && attachments.length === 0)
            throw CoreError.invalid("text is required");
          const thread =
            typeof raw.thread === "number" ? params.thread(raw) : undefined;
          const session =
            thread === undefined ? params.text(raw, "session", 512) : undefined;
          return this.#threadFor(workspace, station, thread, session).pipe(
            Effect.flatMap((id) =>
              this.#add({ workspace, station, thread: id }, text, attachments)
            ),
            Effect.as(null)
          );
        },
      },
      "stations.retry": {
        run: (p) => {
          const at = this.#at(p);
          const id = params.text(p, "id");
          return Effect.suspend(() => {
            const entry = this.#outbox(at.station, at.thread).find((o) => o.id === id);
            if (!entry) return Effect.fail(CoreError.invalid("No such message."));
            this.#update(at, id, { state: "sending" });
            return this.#deliver(at, id);
          }).pipe(Effect.as(null));
        },
      },
      "stations.discard": {
        run: (p) => {
          const at = this.#at(p);
          const id = params.text(p, "id");
          return Effect.sync(() => {
            this.#setOutbox(
              at,
              this.#outbox(at.station, at.thread).filter((o) => o.id !== id)
            );
            return null;
          });
        },
      },
      "stations.older": {
        run: (p) => {
          const at = this.#at(p);
          return Effect.suspend(() => {
            const open = this.#open.get(keyOf(at.station, at.thread));
            if (!open || open.first === null || open.first <= 1) return Effect.void;
            return this.#read(open, `?before=${open.first}&limit=${PAGE}`);
          }).pipe(Effect.as(null));
        },
      },
      "stations.read": {
        run: (p) => {
          const at = this.#at(p);
          return Effect.suspend(() => {
            const open = this.#open.get(keyOf(at.station, at.thread));
            const newest = open ? this.#newest(open) : 0;
            if (!open?.view || newest <= open.view.read || newest <= open.readSent)
              return Effect.void;
            open.readSent = newest;
            return this.#stations
              .ask(
                at.workspace,
                at.station,
                "PUT",
                route`/threads/${String(at.thread)}/read`,
                {
                  n: newest,
                }
              )
              .pipe(
                Effect.tap((answer) =>
                  Effect.sync(() => {
                    const n = (answer as { n?: unknown } | null)?.n;
                    if (open.view && typeof n === "number")
                      open.view = { ...open.view, read: n };
                  })
                ),
                // Not marked: the next look marks it.
                Effect.tapError(() => Effect.sync(() => (open.readSent = 0)))
              );
          }).pipe(Effect.as(null));
        },
      },
      "stations.upload": {
        doing: true,
        run: (p) => {
          const workspace = params.text(p, "workspace");
          const station = params.text(p, "station");
          const name = params.text(p, "name", 1_024);
          const encoded = params.text(p, "bytes", Math.ceil(UPLOAD_MAX_BYTES / 3) * 4);
          return Effect.suspend(() => {
            let bytes: Uint8Array;
            try {
              bytes = fromBase64(encoded);
            } catch {
              return Effect.fail(CoreError.invalid("bytes are not base64"));
            }
            if (bytes.length > UPLOAD_MAX_BYTES)
              return Effect.fail(CoreError.invalid("The file is larger than 8 MB."));
            return this.#stations.ask(
              workspace,
              station,
              "POST",
              `/uploads?name=${encodeURIComponent(name)}`,
              undefined,
              { raw: { bytes, type: "application/octet-stream" } }
            );
          }).pipe(
            Effect.flatMap((answer) => {
              const file = uploadedSchema.safeParse(answer);
              return file.success
                ? Effect.succeed(file.data)
                : Effect.fail(
                    new CoreError("bad_response", "The station kept no file.")
                  );
            })
          );
        },
      },
      "stations.stopAgent": {
        doing: true,
        run: (p) => {
          const workspace = params.text(p, "workspace");
          const station = params.text(p, "station");
          const session = params.text(p, "session", 512);
          return this.#stations
            .ask(workspace, station, "POST", `${route`/sessions/${session}`}/stop`)
            .pipe(Effect.as(null));
        },
      },
    });
  }

  #at(p: unknown) {
    return {
      workspace: params.text(p, "workspace"),
      station: params.text(p, "station"),
      thread: params.thread(p),
    };
  }

  // ── showing a chat ───────────────────────────────────────────────────

  /** The chat a topic shows: its thread, the one made for its session here, or its session's row's. */
  #threadOf(topic: Topic): number | null {
    const given = Number(topic.thread);
    if (topic.thread !== "" && Number.isSafeInteger(given) && given > 0) return given;
    const station = topic.station as string;
    const session = topic.session as string | null;
    if (!session) return null;
    return (
      this.#made.get(`${station}\t${session}`) ??
      this.#sessionRow(station, session)?.thread ??
      null
    );
  }

  #sessionRow(station: string, session: string): StationChatRow | null {
    for (const row of this.#activity.rowsOf(station))
      if (row.id === session || row.session === session) return row;
    return null;
  }

  #show(topic: Topic): void {
    const workspace = topic.workspace as string;
    this.#activity.hold(
      workspace,
      `chat:${String(topic.station)}:${String(topic.thread)}:${String(topic.session)}`
    );
    const thread = this.#threadOf(topic);
    if (thread !== null) this.#openThread(workspace, topic.station as string, thread);
  }

  #hide(topic: Topic): void {
    this.#activity.unhold(
      topic.workspace as string,
      `chat:${String(topic.station)}:${String(topic.thread)}:${String(topic.session)}`
    );
    const thread = this.#threadOf(topic);
    if (thread === null) return;
    const open = this.#open.get(keyOf(topic.station as string, thread));
    if (!open) return;
    open.shown--;
    if (open.shown <= 0) this.#open.delete(keyOf(open.station, open.thread));
  }

  #openThread(workspace: string, station: string, thread: number): Open {
    const key = keyOf(station, thread);
    let open = this.#open.get(key);
    if (open) {
      open.shown++;
      return open;
    }
    open = {
      workspace,
      station,
      thread,
      shown: 1,
      view: null,
      entries: new Map(),
      first: null,
      loading: true,
      error: undefined,
      readSent: 0,
    };
    this.#open.set(key, open);
    const opened = open;
    this.#fork(
      opened,
      this.#refresh(opened).pipe(
        // What was sending when this device last stopped goes again, as the same messages.
        Effect.andThen(
          Effect.forEach(
            this.#outbox(station, thread).filter(
              (o) => o.state === "sending" && o.seq === undefined
            ),
            (o) => Effect.ignore(this.#deliver(opened, o.id)),
            { discard: true }
          )
        )
      )
    );
    return open;
  }

  #fork(open: Open, work: Effect.Effect<unknown, CoreError>): void {
    this.#ctx.runner.fork(
      work.pipe(
        Effect.catch((e: CoreError) =>
          Effect.sync(() => {
            open.error = e.message;
            open.loading = false;
            this.#changed(open);
          })
        )
      )
    );
  }

  /** Reads the chat's summary, and its latest page (or what came since what is held). */
  #refresh(open: Open): Effect.Effect<void, CoreError> {
    return this.#stations
      .ask(open.workspace, open.station, "GET", route`/threads/${String(open.thread)}`)
      .pipe(
        Effect.flatMap((answer) => {
          const view = threadSchema.safeParse(answer);
          if (!view.success)
            return Effect.fail(
              new CoreError("bad_response", "The station's chat is unreadable.")
            );
          open.view = view.data;
          return this.#read(
            open,
            open.entries.size > 0 ? `?after=${this.#top(open)}` : ""
          );
        }),
        Effect.tap(() =>
          Effect.sync(() => {
            open.loading = false;
            open.error = undefined;
            this.#changed(open);
          })
        )
      );
  }

  /** Reads entries (`query`), and holds them. */
  #read(open: Open, query: string): Effect.Effect<void, CoreError> {
    return this.#stations
      .ask(
        open.workspace,
        open.station,
        "GET",
        `${route`/threads/${String(open.thread)}`}/entries${query}`
      )
      .pipe(
        Effect.flatMap((answer) => {
          const page = entriesSchema.safeParse(answer);
          if (!page.success)
            return Effect.fail(
              new CoreError("bad_response", "The station's messages are unreadable.")
            );
          this.#hold(open, page.data.entries);
          // The page before the first held: nothing older when it came short.
          if (query === "" || query.startsWith("?before"))
            open.first =
              page.data.entries.length === 0
                ? (open.first ?? page.data.last + 1)
                : Math.min(...page.data.entries.map((e) => e.n));
          if (open.view && page.data.last > open.view.last)
            open.view = { ...open.view, last: page.data.last };
          this.#changed(open);
          return Effect.void;
        })
      );
  }

  #hold(open: Open, entries: readonly StationEntry[]): void {
    for (const entry of entries) open.entries.set(entry.n, entry);
    this.#settle(open);
  }

  #top(open: Open): number {
    let top = 0;
    for (const n of open.entries.keys()) if (n > top) top = n;
    return top;
  }

  #newest(open: Open): number {
    let newest = 0;
    for (const entry of open.entries.values())
      if (entry.kind === "message" && entry.n > newest) newest = entry.n;
    return newest;
  }

  /** A followed station said something: a chat's new entries, or where the viewer read to. */
  #event(station: string, event: string, value: unknown): void {
    if (event === "thread") {
      const said = threadEventSchema.safeParse(value);
      if (!said.success) return;
      const open = this.#open.get(keyOf(station, said.data.id));
      if (!open) return;
      const top = this.#top(open);
      const lowest = Math.min(...said.data.entries.map((e) => e.n));
      this.#hold(open, said.data.entries);
      if (open.view)
        open.view = { ...open.view, last: Math.max(open.view.last, this.#top(open)) };
      this.#changed(open);
      // Entries between what was held and these were missed: they are read.
      if (top > 0 && lowest > top + 1)
        this.#fork(open, this.#read(open, `?after=${top}`));
      return;
    }
    if (event === "read") {
      const read = value as { thread?: unknown; n?: unknown } | null;
      if (typeof read?.thread !== "number" || typeof read.n !== "number") return;
      const open = this.#open.get(keyOf(station, read.thread));
      if (open?.view && read.n > open.view.read) {
        open.view = { ...open.view, read: read.n };
        this.#changed(open);
      }
    }
  }

  #changed(open: { workspace: string; station: string }): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "stationChat" && topic.station === open.station)
        this.#ctx.kernel.store.invalidate(topic);
  }

  // ── the value ────────────────────────────────────────────────────────

  #value(topic: Topic): StationChatValue {
    const workspace = topic.workspace as string;
    const station = topic.station as string;
    const link = this.#stations.linkOf(station);
    const thread = this.#threadOf(topic);
    const open = thread === null ? undefined : this.#open.get(keyOf(station, thread));
    const row =
      thread !== null
        ? this.#activity.rowOf(station, thread)
        : this.#sessionRow(station, String(topic.session ?? ""));
    const agents: StationChatAgent[] = (row?.agents ?? []).map((agent) => {
      const state = agentState(agent);
      return {
        session: agent.key,
        name: [agent.model ?? agent.runtime ?? "", agent.effort ?? ""]
          .filter(Boolean)
          .join(" · "),
        state,
        running: state.status === "running" || agent.process === "running",
      };
    });
    const outbox = thread === null ? [] : this.#outbox(station, thread);
    const messages = open ? this.#messages(open, row, outbox) : [];
    const shownOutbox = outbox.map(({ id, text, state, error }) => ({
      id,
      text,
      state,
      ...(error !== undefined ? { error } : {}),
    }));
    return {
      workspace,
      station,
      thread,
      title:
        row?.title ??
        open?.view?.title ??
        open?.view?.autoTitle ??
        (open?.view?.firstText ? firstLine(open.view.firstText) || null : null),
      link,
      agents,
      messages,
      more: open?.first !== null && open?.first !== undefined && open.first > 1,
      outbox: shownOutbox,
      loading: open ? open.loading : thread !== null,
      ...(open?.error !== undefined ? { error: open.error } : {}),
    };
  }

  #messages(
    open: Open,
    row: StationChatRow | null,
    outbox: Outgoing[]
  ): StationChatMessage[] {
    const viewer: Viewer = this.#stations.viewer() ?? { email: "" };
    const entries = [...open.entries.values()].toSorted((a, b) => a.n - b.n);
    const byN = new Map<number, StationEntry>();
    for (const entry of entries) {
      if (entry.kind === "message") byN.set(entry.n, entry);
      else if (entry.kind === "edit" && entry.target !== null) {
        const target = byN.get(entry.target);
        if (target)
          byN.set(entry.target, {
            ...target,
            text: entry.text,
            attachments: entry.attachments,
            quotes: entry.quotes,
          });
      }
    }
    const list = [...byN.values()].toSorted((a, b) => a.n - b.n);
    // Messages not taken yet: as many of the last people's as the agents have waiting.
    const waiting = Math.max(0, ...(row?.agents ?? []).map((a) => a.pending));
    const people = list.filter((e) => e.authorKind === "person").map((e) => e.n);
    const untaken = new Set(people.slice(people.length - waiting));
    const pending = this.#activity.rowsRead(open.station)
      ? (() => {
          const asked = row?.card ?? row?.decision ?? null;
          return asked ? { seq: asked.seq, dismissed: asked.dismissed === true } : null;
        })()
      : undefined;
    const sending = outbox.some((o) => o.state !== "failed");
    return list.map((entry, i): StationChatMessage => {
      const kind =
        entry.authorKind === "person"
          ? "person"
          : entry.authorKind === "agent"
            ? "agent"
            : "system";
      const mine = kind === "person" && sameEmail(entry.author, viewer.email);
      const message: StationChatMessage = {
        seq: entry.n,
        thread: open.thread,
        kind,
        author: entry.authorName ?? entry.author,
        mine,
        text: entry.text ?? "",
        attachments: entry.attachments,
        createdAt: entry.at,
        waiting: mine && untaken.has(entry.n),
      };
      if (
        entry.ending === "all_done" ||
        entry.ending === "need_help" ||
        entry.ending === "waiting"
      )
        message.ending = entry.ending;
      const card = entry.card;
      if (card && row) message.card = cardShown(card, row, viewer);
      else if (card)
        message.card = cardShown(card, { creator: null } as StationChatRow, viewer);
      if (card) {
        const later = list.slice(i + 1);
        const replaced = later.some((e) => e.card !== undefined);
        const answer = later.find((e) => e.authorKind === "person");
        const answeredHere = !answer && !replaced && sending;
        const waitingNow =
          pending === undefined
            ? !answer && !replaced && !answeredHere
            : pending !== null && pending.seq === entry.n;
        const by = (e: StationEntry) =>
          sameEmail(e.author, viewer.email) ? null : (e.authorName ?? e.author);
        const label = answer?.text?.trim() ?? "";
        const chose =
          answer &&
          entry.ts &&
          answer.quotes.some((q) => q.ts === entry.ts) &&
          card.options?.some((o) => o.label.trim() === label);
        message.cardState = {
          resolved: !waitingNow,
          ...(waitingNow && pending?.dismissed ? { dismissed: true } : {}),
          ...(waitingNow
            ? {}
            : answer
              ? chose
                ? { outcome: { kind: "chose", by: by(answer), label } as const }
                : { outcome: { kind: "replied", by: by(answer) } as const }
              : answeredHere
                ? { outcome: { kind: "replied", by: null } as const }
                : replaced
                  ? { outcome: { kind: "replaced" } as const }
                  : {}),
        };
      }
      return message;
    });
  }

  // ── sending ──────────────────────────────────────────────────────────

  /** The chat to send to: the one given, or the session's (made now when it has none). */
  #threadFor(
    workspace: string,
    station: string,
    thread: number | undefined,
    session: string | undefined
  ): Effect.Effect<number, CoreError> {
    return Effect.suspend(() => {
      if (thread !== undefined) return Effect.succeed(thread);
      const known =
        this.#made.get(`${station}\t${session}`) ??
        this.#sessionRow(station, session!)?.thread;
      if (known !== null && known !== undefined) return Effect.succeed(known);
      return this.#stations
        .ask(workspace, station, "POST", "/threads", { session })
        .pipe(
          Effect.flatMap((answer) => {
            const made = threadSchema.safeParse(answer);
            if (!made.success)
              return Effect.fail(
                new CoreError("bad_response", "The station made no chat.")
              );
            this.#made.set(`${station}\t${session}`, made.data.id);
            // A page showing the session shows its chat now.
            for (const topic of this.#ctx.kernel.store.liveTopics())
              if (
                topic.topic === "stationChat" &&
                topic.station === station &&
                topic.session === session
              )
                this.#openThread(workspace, station, made.data.id);
            return Effect.succeed(made.data.id);
          })
        );
    });
  }

  #outbox(station: string, thread: number): Outgoing[] {
    const key = keyOf(station, thread);
    let outbox = this.#outboxes.get(key);
    if (!outbox) {
      outbox =
        this.#ctx.session.current()?.doc<Outgoing[]>(outboxDoc(station, thread))
          ?.value ?? [];
      for (const o of outbox) {
        const n = Number(o.id.replace("out-", ""));
        if (Number.isSafeInteger(n) && n >= this.#nextId) this.#nextId = n + 1;
      }
      this.#outboxes.set(key, outbox);
    }
    return outbox;
  }

  #setOutbox(
    at: { workspace: string; station: string; thread: number },
    outbox: Outgoing[]
  ): void {
    this.#outboxes.set(keyOf(at.station, at.thread), outbox);
    const account = this.#ctx.session.current();
    if (account && !account.closed)
      if (outbox.length === 0) account.deleteDoc(outboxDoc(at.station, at.thread));
      else account.putDoc(outboxDoc(at.station, at.thread), outbox, this.#ctx.now());
    this.#changed(at);
  }

  #update(
    at: { workspace: string; station: string; thread: number },
    id: string,
    change: Partial<Outgoing>
  ): void {
    this.#setOutbox(
      at,
      this.#outbox(at.station, at.thread).map((o) => {
        if (o.id !== id) return o;
        const next = { ...o, ...change };
        if (change.state === "sending") delete next.error;
        return next;
      })
    );
  }

  /** What the station holds now leaves the outbox. */
  #settle(open: Open): void {
    const outbox = this.#outboxes.get(keyOf(open.station, open.thread));
    if (!outbox || outbox.length === 0) return;
    const viewer = this.#stations.viewer();
    const top = this.#top(open);
    let matched = 0;
    const kept = outbox.filter((o) => {
      if (o.seq !== undefined) return top < o.seq;
      for (const entry of open.entries.values()) {
        if (
          entry.kind === "message" &&
          entry.authorKind === "person" &&
          entry.n > Math.max(o.after, matched) &&
          viewer !== null &&
          sameEmail(entry.author, viewer.email) &&
          (entry.text ?? "") === o.text
        ) {
          matched = entry.n;
          return false;
        }
      }
      return true;
    });
    if (kept.length !== outbox.length) this.#setOutbox(open, kept);
  }

  /**
   * Puts `text` in the chat's outbox and sends it, once under `key`: a message the outbox has under it already is not
   * added again (the first message of a Task made again, tasks.ts).
   */
  post(
    at: { workspace: string; station: string; thread: number },
    text: string,
    key: string
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#outbox(at.station, at.thread).some((o) => o.key === key)
        ? Effect.void
        : this.#add(at, text, [], key)
    );
  }

  #add(
    at: { workspace: string; station: string; thread: number },
    text: string,
    attachments: StationAttachment[],
    key = this.#stations.onceKey()
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const open = this.#open.get(keyOf(at.station, at.thread));
      const entry: Outgoing = {
        id: `out-${this.#nextId++}`,
        text,
        attachments,
        state: "sending",
        key,
        after: open ? this.#top(open) : 0,
      };
      this.#setOutbox(at, [...this.#outbox(at.station, at.thread), entry]);
      // A message the station did not take stays in the outbox, failed: the call itself succeeded.
      return Effect.ignore(this.#deliver(at, entry.id));
    });
  }

  /** Sends an outbox message, with its own key. */
  #deliver(
    at: { workspace: string; station: string; thread: number },
    id: string
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const entry = this.#outbox(at.station, at.thread).find((o) => o.id === id);
      if (!entry) return Effect.void;
      return this.#stations
        .ask(
          at.workspace,
          at.station,
          "POST",
          `${route`/threads/${String(at.thread)}`}/messages`,
          {
            text: entry.text,
            ...(entry.attachments.length > 0 ? { attachments: entry.attachments } : {}),
          },
          { onceKey: entry.key }
        )
        .pipe(
          Effect.flatMap((answer) => {
            const sent = sentSchema.safeParse(answer);
            if (!sent.success)
              return Effect.fail(
                new CoreError("bad_response", "The station took no message.")
              );
            this.#update(at, id, { seq: sent.data.n });
            const open = this.#open.get(keyOf(at.station, at.thread));
            if (open) {
              this.#settle(open);
              if (this.#top(open) < sent.data.n)
                return this.#read(open, `?after=${this.#top(open)}`);
            }
            return Effect.void;
          }),
          Effect.tapError((e) =>
            Effect.sync(() =>
              this.#update(at, id, { state: "failed", error: e.message })
            )
          )
        );
    });
  }
}

function attachmentsOf(raw: unknown): StationAttachment[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 20)
    throw CoreError.invalid("attachments are invalid");
  return raw.map((a) => {
    const v = a as Record<string, unknown> | null;
    if (
      typeof v?.name !== "string" ||
      typeof v.path !== "string" ||
      typeof v.size !== "number"
    )
      throw CoreError.invalid("attachments are invalid");
    return { name: v.name, path: v.path, size: v.size };
  });
}
