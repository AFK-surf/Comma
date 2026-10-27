// What happens on a workspace's stations, as the Stations area lists it: the viewer's chats (`stationChats`), the
// cards and questions waiting for them (`stationDecisions`) and the jobs that have run long (`stationJobs`). While one
// of these is shown, each station of the workspace is followed: its chats and open jobs are read when its event stream
// opens (a station replays nothing), then each `chat` event replaces a row and each job event reads the jobs again. A
// station's chats are kept on this device, so the list shows at once next time.
//
// Answering a card sends a message that quotes it (the station takes that as the answer) or, for an option that closes
// it, closes it; dismissing it is the station's too. Setting it aside is this device's only.
//
// Bounds: per shown workspace, one event stream per station and one read of its chats and jobs per stream opened; job
// events read the jobs at most once a second per station. Ages and day names are worked out again once a minute while
// shown.
import { CoreError, type Scoped, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Result } from "effect";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import type {
  StationAttachment,
  StationChatsValue,
  StationDecision,
  StationDecisionsValue,
  StationJobsValue,
} from "../contract.ts";
import { type Ctx, Live } from "../ctx.ts";
import { readEvents } from "../sse.ts";
import type { Stations } from "./index.ts";
import {
  chatRowSchema,
  chatRowsSchema,
  jobsSchema,
  madeSchema,
  overviewSchema,
  sentSchema,
  type StationChatRow,
  type StationJob,
} from "./station-api.ts";
import {
  chatDays,
  chatItem,
  decisionOf,
  longJobs,
  optionOf,
  quoteOf,
  type StationNamed,
} from "./views.ts";

const RETRY_MS = [1_000, 5_000, 30_000];
const TICK_MS = 60_000;
const JOBS_EVERY_MS = 1_000;
const DEFERRED = "stations.deferred";
const MAX_DEFERRED = 200;
const rowsDoc = (station: string) => `stations.chats.${station}`;
const TOPICS = new Set(["stationChats", "stationDecisions", "stationJobs"]);

type Followed = {
  workspace: string;
  scoped: Scoped;
  /** Rows by chat id, once read. */
  rows: Map<string, StationChatRow> | null;
  jobs: StationJob[];
  jobsDue: boolean;
};

/** A message of a chat on a station, and its workspace: where a card is. */
export type CardAt = {
  workspace: string;
  station: string;
  thread: number;
  seq: number;
};

const where = {
  of(raw: unknown) {
    const p = (raw ?? {}) as Record<string, unknown>;
    const text = (name: string) => {
      const v = p[name];
      if (typeof v !== "string" || v === "" || v.length > 256)
        throw CoreError.invalid(`${name} is required`);
      return v;
    };
    const int = (name: string) => {
      const v = p[name];
      if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0)
        throw CoreError.invalid(`${name} is required`);
      return v;
    };
    return {
      workspace: text("workspace"),
      station: text("station"),
      thread: int("thread"),
      seq: int("seq"),
    };
  },
};

const keyOf = (station: string, thread: number, seq: number) =>
  `${station}\t${thread}\t${seq}`;

export class StationActivity {
  readonly #ctx: Ctx;
  readonly #stations: Stations;
  readonly #live: Live;
  /** Workspaces shown, and by which topics. */
  readonly #shown = new Map<string, Set<string>>();
  /** Stations followed, by id. */
  readonly #followed = new Map<string, Followed>();
  /** Cards answered from here, until their station's row no longer has them. */
  readonly #answered = new Set<string>();

  constructor(ctx: Ctx, stations: Stations) {
    this.#ctx = ctx;
    this.#stations = stations;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    for (const name of TOPICS)
      kernel.source(name, {
        start: (topic) => this.#show(topic),
        stop: (topic) => this.#hide(topic),
        compute: (topic): Value => ({ ok: this.#compute(topic) }),
      });
    stations.onChange((workspace) => {
      if (!this.#shown.has(workspace)) return;
      this.#follow();
      this.#changed(workspace);
    });
    stations.onAccount(() => {
      for (const followed of this.#followed.values()) ctx.runner.close(followed.scoped);
      this.#followed.clear();
      this.#answered.clear();
    });

    kernel.calls({
      "stations.newChat": {
        doing: true,
        run: (p) => {
          const workspace = param(p, "workspace");
          const station = param(p, "station");
          return this.#newChat(workspace, station);
        },
      },
      "stations.answer": {
        doing: true,
        run: (p) => {
          const at = where.of(p);
          const option = param(p, "option", 1_000);
          return this.#answer(at, option);
        },
      },
      "stations.reply": {
        doing: true,
        run: (p) => {
          const at = where.of(p);
          const reply = param(p, "text", 100_000).trim();
          if (reply === "") throw CoreError.invalid("text is required");
          return this.#reply(at, reply);
        },
      },
      "stations.dismiss": {
        doing: true,
        run: (p) => this.dismiss(where.of(p)),
      },
      "stations.defer": {
        run: (p) => {
          const at = where.of(p);
          return this.#account().pipe(
            Effect.map((account) => {
              const kept = account.meta<Record<string, number>>(DEFERRED) ?? {};
              const key = keyOf(at.station, at.thread, at.seq);
              const last = Math.max(0, ...Object.values(kept));
              const next = { ...kept, [key]: Math.max(this.#ctx.now(), last + 1) };
              const keep = Object.entries(next)
                .toSorted(([, a], [, b]) => b - a)
                .slice(0, MAX_DEFERRED);
              account.setMeta(DEFERRED, Object.fromEntries(keep));
              this.#changed(at.workspace);
              return null;
            })
          );
        },
      },
    });
  }

  // ── what is shown ────────────────────────────────────────────────────

  #show(topic: Topic): void {
    const workspace = topic.workspace as string;
    this.hold(workspace, topic.topic);
    // Ages and day names move with the time.
    if (topic.topic !== "stationDecisions")
      this.#live.run(
        topic,
        Effect.forever(
          Effect.sleep(TICK_MS).pipe(
            Effect.andThen(Effect.sync(() => this.#ctx.kernel.store.invalidate(topic)))
          )
        )
      );
  }

  #hide(topic: Topic): void {
    this.#live.stop(topic);
    this.unhold(topic.workspace as string, topic.topic);
  }

  /** Follows `workspace`'s stations for `holder` (a topic shown, an open chat): the first holder starts it. */
  hold(workspace: string, holder: string): void {
    let by = this.#shown.get(workspace);
    if (!by) this.#shown.set(workspace, (by = new Set()));
    by.add(holder);
    this.#stations.retain(workspace, "activity");
    this.#follow();
  }

  /** `holder` lets `workspace`'s stations go: the last one stops following them. */
  unhold(workspace: string, holder: string): void {
    const by = this.#shown.get(workspace);
    if (!by) return;
    by.delete(holder);
    if (by.size > 0) return;
    this.#shown.delete(workspace);
    this.#stations.release(workspace, "activity");
    this.#follow();
  }

  readonly #eventListeners = new Set<
    (station: string, event: string, value: unknown) => void
  >();
  readonly #openListeners = new Set<(station: string) => void>();

  /** Told each event a followed station says (a chat's new entries, a read). */
  onEvent(listener: (station: string, event: string, value: unknown) => void): void {
    this.#eventListeners.add(listener);
  }

  /** Told when a station's event stream opened again: what was held of it may have missed changes. */
  onOpened(listener: (station: string) => void): void {
    this.#openListeners.add(listener);
  }

  /** The row of `station`'s chat `thread`, as last read; null when there is none. */
  /** Answers the card of a chat's message (`at.seq`) with its option `label`, as a person on the station's page does. */
  answer(at: CardAt, label: string): Effect.Effect<null, CoreError> {
    return this.#answer(at, label);
  }

  /** Answers the card of a chat's message in a person's own words, with the files that went up for it. */
  reply(
    at: CardAt,
    text: string,
    attachments: StationAttachment[] = []
  ): Effect.Effect<null, CoreError> {
    return this.#reply(at, text, attachments);
  }

  /** The viewer will not answer the card of a chat's message: it leaves their list, on the station. */
  dismiss(at: CardAt): Effect.Effect<null, CoreError> {
    return this.#stations
      .ask(
        at.workspace,
        at.station,
        "PUT",
        route`/threads/${String(at.thread)}/dismissed`,
        {
          n: at.seq,
        }
      )
      .pipe(Effect.as(null));
  }

  rowOf(station: string, thread: number): StationChatRow | null {
    return this.#row(station, thread);
  }

  /** `station`'s chat rows, as last read. */
  rowsOf(station: string): StationChatRow[] {
    return [...(this.#rowsOf(station)?.values() ?? [])];
  }

  /** Whether `station`'s chats were read (a card's state is known). */
  rowsRead(station: string): boolean {
    return this.#rowsOf(station) !== null;
  }

  #changed(workspace: string): void {
    for (const name of TOPICS)
      this.#ctx.kernel.store.invalidate({ topic: name, workspace });
    for (const listener of this.#changeListeners) listener(workspace);
  }

  readonly #changeListeners = new Set<(workspace: string) => void>();

  /** Told whenever what is known of `workspace`'s stations' chats changed. */
  onChanged(listener: (workspace: string) => void): void {
    this.#changeListeners.add(listener);
  }

  /**
   * Keeps chat `thread` of `station` at the top of the viewer's list (`pinned`) or lets it go, on its station: shown so
   * at once, and as it was when the station refused.
   */
  pin(
    workspace: string,
    station: string,
    thread: number,
    pinned: boolean
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const followed = this.#followed.get(station);
      const row = this.#row(station, thread);
      if (!row)
        return Effect.fail(new CoreError("not_found", "The machine has no such chat."));
      const was = row.pinned ?? null;
      // Shown so where its station's chats are followed; elsewhere their next read says it.
      const set = (to: number | null) => {
        const now = followed?.rows?.get(row.id);
        if (!followed || !now) return;
        followed.rows!.set(row.id, { ...now, pinned: to });
        this.#keep(followed, station);
      };
      set(pinned ? this.#ctx.now() : null);
      return this.#stations
        .ask(
          workspace,
          station,
          pinned ? "PUT" : "DELETE",
          route`/sessions/${row.id}/pin`
        )
        .pipe(
          Effect.tapError(() => Effect.sync(() => set(was))),
          Effect.asVoid
        );
    });
  }

  #compute(topic: Topic): StationChatsValue | StationDecisionsValue | StationJobsValue {
    const workspace = topic.workspace as string;
    const stations = this.#stations.named(workspace);
    const now = this.#ctx.now();
    const loading = stations.some((s) => s.online && !this.#followed.get(s.id)?.rows);
    if (topic.topic === "stationJobs")
      return {
        workspace,
        groups: longJobs(
          stations
            .filter((s) => s.online)
            .map((station) => ({
              station,
              jobs: this.#followed.get(station.id)?.jobs ?? [],
            })),
          now
        ),
      };
    const rows = stations.flatMap((station) =>
      [...(this.#rowsOf(station.id)?.values() ?? [])].map((row) => ({ station, row }))
    );
    if (topic.topic === "stationChats")
      return {
        workspace,
        loading,
        days: chatDays(
          rows.map(({ station, row }) => ({ row, item: chatItem(row, station) })),
          now
        ),
      };
    return { workspace, loading, items: this.#decisions(rows) };
  }

  /** A station's rows: as read this run, else as kept on this device. */
  #rowsOf(station: string): Map<string, StationChatRow> | null {
    const followed = this.#followed.get(station);
    if (followed?.rows) return followed.rows;
    const kept = this.#ctx.session
      .current()
      ?.doc<StationChatRow[]>(rowsDoc(station))?.value;
    return kept ? new Map(kept.map((row) => [row.id, row])) : null;
  }

  #decisions(
    rows: { station: StationNamed; row: StationChatRow }[]
  ): StationDecision[] {
    const viewer = this.#stations.viewer();
    if (!viewer) return [];
    const deferred =
      this.#ctx.session.current()?.meta<Record<string, number>>(DEFERRED) ?? {};
    const items = rows.flatMap(({ station, row }) => {
      const thread = row.thread;
      if (thread === null) return [];
      const asked = decisionOf(row, station, viewer, false);
      if (!asked) return [];
      const key = keyOf(station.id, thread, asked.seq);
      if (this.#answered.has(key)) return [];
      return [
        {
          ...asked,
          deferred: deferred[key] !== undefined,
          at: deferred[key] ?? 0,
          asked: row,
        },
      ];
    });
    return items
      .toSorted((a, b) =>
        a.deferred !== b.deferred
          ? Number(a.deferred) - Number(b.deferred)
          : a.deferred
            ? a.at - b.at
            : askedAt(a.asked) - askedAt(b.asked)
      )
      .map(({ at: _at, asked: _asked, ...item }) => item);
  }

  // ── following each station ───────────────────────────────────────────

  /** Follows each station of the shown workspaces, and stops following the others. */
  #follow(): void {
    const wanted = new Map<string, string>();
    for (const workspace of this.#shown.keys())
      for (const station of this.#stations.named(workspace))
        wanted.set(station.id, workspace);
    for (const [id, followed] of this.#followed) {
      if (wanted.get(id) === followed.workspace) continue;
      this.#ctx.runner.close(followed.scoped);
      this.#followed.delete(id);
    }
    for (const [id, workspace] of wanted) {
      if (this.#followed.has(id)) continue;
      const followed: Followed = {
        workspace,
        scoped: this.#ctx.runner.child(),
        rows: null,
        jobs: [],
        jobsDue: false,
      };
      this.#followed.set(id, followed);
      this.#ctx.runner.fork(this.#keepFollowing(id, followed), followed.scoped);
    }
  }

  /** Opens the station's event stream, reads what it holds, and applies what it says; again after it ends. */
  #keepFollowing(station: string, followed: Followed): Effect.Effect<void> {
    const ctx = this.#ctx;
    const stations = this.#stations;
    const { workspace } = followed;
    return Effect.gen({ self: this }, function* () {
      let backoff = 0;
      for (;;) {
        const ran = yield* Effect.result(
          Effect.scoped(
            Effect.gen({ self: this }, function* () {
              const body = yield* stations.stream(workspace, station, "/events");
              yield* this.#readRows(followed, station);
              yield* this.#readJobs(followed, station);
              backoff = 0;
              for (const listener of this.#openListeners) listener(station);
              yield* readEvents(body, (value, event) =>
                this.#event(followed, station, event, value)
              );
            })
          )
        );
        if (Result.isFailure(ran) && ctx.session.current() === null) return;
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  #readRows(followed: Followed, station: string): Effect.Effect<void, CoreError> {
    return this.#stations.ask(followed.workspace, station, "GET", "/chats").pipe(
      Effect.flatMap((answer) => {
        const rows = chatRowsSchema.safeParse(answer);
        return rows.success
          ? Effect.succeed(rows.data)
          : Effect.fail(
              new CoreError("bad_response", "The station's chats are unreadable.")
            );
      }),
      Effect.tap((rows) =>
        Effect.sync(() => {
          followed.rows = new Map(rows.map((row) => [row.id, row]));
          this.#keep(followed, station);
        })
      ),
      Effect.asVoid
    );
  }

  #readJobs(followed: Followed, station: string): Effect.Effect<void, CoreError> {
    return this.#stations.ask(followed.workspace, station, "GET", "/jobs").pipe(
      Effect.flatMap((answer) => {
        const jobs = jobsSchema.safeParse(answer);
        return jobs.success
          ? Effect.succeed(jobs.data)
          : Effect.fail(
              new CoreError("bad_response", "The station's jobs are unreadable.")
            );
      }),
      Effect.tap((jobs) =>
        Effect.sync(() => {
          followed.jobs = jobs;
          this.#changed(followed.workspace);
        })
      ),
      Effect.asVoid
    );
  }

  /** The rows changed: kept on this device, answered cards the station no longer has forgotten, and shown. */
  #keep(followed: Followed, station: string): void {
    const rows = [...(followed.rows?.values() ?? [])];
    const account = this.#ctx.session.current();
    if (account && !account.closed)
      account.putDoc(rowsDoc(station), rows, this.#ctx.now());
    for (const key of this.#answered) {
      const [at, thread, seq] = key.split("\t");
      if (at !== station) continue;
      const row = rows.find((r) => String(r.thread) === thread);
      const asked = row?.card ?? row?.decision ?? row?.need;
      if (!asked || String(asked.seq) !== seq) this.#answered.delete(key);
    }
    this.#changed(followed.workspace);
  }

  #event(
    followed: Followed,
    station: string,
    event: string | undefined,
    value: unknown
  ): Effect.Effect<void, CoreError> {
    if (event !== undefined)
      for (const listener of this.#eventListeners) listener(station, event, value);
    if (event === "chat") {
      const row = chatRowSchema.safeParse(value);
      if (!row.success || !followed.rows) return Effect.void;
      return Effect.sync(() => {
        followed.rows!.set(row.data.id, row.data);
        this.#keep(followed, station);
      });
    }
    if (event === "chat-removed") {
      const id = (value as { id?: unknown } | null)?.id;
      if (typeof id !== "string" || !followed.rows) return Effect.void;
      return Effect.sync(() => {
        followed.rows!.delete(id);
        this.#keep(followed, station);
      });
    }
    if (event === "job" || event === "job-removed") {
      if (followed.jobsDue) return Effect.void;
      followed.jobsDue = true;
      // A burst of job events reads the jobs once.
      this.#ctx.runner.fork(
        Effect.sleep(JOBS_EVERY_MS).pipe(
          Effect.andThen(
            Effect.sync(() => {
              followed.jobsDue = false;
            })
          ),
          Effect.andThen(Effect.ignore(this.#readJobs(followed, station)))
        ),
        followed.scoped
      );
    }
    return Effect.void;
  }

  // ── what the viewer does ─────────────────────────────────────────────

  #account(): Effect.Effect<Account, CoreError> {
    return this.#ctx.session.account();
  }

  #row(station: string, thread: number): StationChatRow | null {
    for (const row of this.#rowsOf(station)?.values() ?? [])
      if (row.thread === thread) return row;
    return null;
  }

  /** Sends `text` to the chat as an answer to the card at `seq`: it quotes the card. */
  #send(
    at: ReturnType<typeof where.of>,
    words: string,
    quote: NonNullable<ReturnType<typeof quoteOf>>,
    attachments: StationAttachment[] = []
  ): Effect.Effect<null, CoreError> {
    return this.#stations
      .ask(
        at.workspace,
        at.station,
        "POST",
        route`/threads/${String(at.thread)}/messages`,
        {
          text: words,
          ...(attachments.length > 0 ? { attachments } : {}),
          quotes: [quote],
        }
      )
      .pipe(
        Effect.flatMap((answer) =>
          sentSchema.safeParse(answer).success
            ? Effect.void
            : Effect.fail(new CoreError("bad_response", "The station took no message."))
        ),
        Effect.andThen(this.#answeredHere(at)),
        Effect.as(null)
      );
  }

  /** Answered from here: it leaves the list now, and is no longer set aside. */
  #answeredHere(at: ReturnType<typeof where.of>): Effect.Effect<void, CoreError> {
    return this.#account().pipe(
      Effect.map((account) => {
        const key = keyOf(at.station, at.thread, at.seq);
        this.#answered.add(key);
        const kept = account.meta<Record<string, number>>(DEFERRED);
        if (kept && key in kept) {
          const { [key]: _gone, ...rest } = kept;
          account.setMeta(DEFERRED, rest);
        }
        this.#changed(at.workspace);
      })
    );
  }

  #answer(
    at: ReturnType<typeof where.of>,
    label: string
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const row = this.#row(at.station, at.thread);
      const quote = row ? quoteOf(row, at.seq) : null;
      if (!row || !quote)
        return Effect.fail(
          new CoreError("already_answered", "It was answered already.")
        );
      const option = optionOf(row, at.seq, label);
      if (!option) return Effect.fail(CoreError.invalid("No such option."));
      if (option.action === "close")
        return this.#stations
          .ask(
            at.workspace,
            at.station,
            "PUT",
            route`/threads/${String(at.thread)}/closed-card`,
            {
              n: at.seq,
              option: option.label.trim(),
            }
          )
          .pipe(Effect.andThen(this.#answeredHere(at)), Effect.as(null));
      return this.#send(at, option.label.trim(), quote);
    });
  }

  #reply(
    at: ReturnType<typeof where.of>,
    reply: string,
    attachments: StationAttachment[] = []
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const row = this.#row(at.station, at.thread);
      const quote = row ? quoteOf(row, at.seq) : null;
      if (!row || !quote)
        return Effect.fail(
          new CoreError("already_answered", "It was answered already.")
        );
      return this.#send(at, reply, quote, attachments);
    });
  }

  /** A new chat on the first runtime the station's profiles offer (Claude before Codex). */
  #newChat(
    workspace: string,
    station: string
  ): Effect.Effect<{ session: string; thread: number }, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const overview = overviewSchema.safeParse(
        yield* this.#stations.ask(workspace, station, "GET", "/overview")
      );
      const runtimes = new Set(
        (overview.success ? overview.data.profiles : []).flatMap(
          (p) => p.runtimes ?? (p.runtime ? [p.runtime] : [])
        )
      );
      const runtime = ["claude", "codex"].find((r) => runtimes.has(r));
      if (!runtime)
        return yield* Effect.fail(
          new CoreError("no_runtime", "The station has no profile to run a chat on.")
        );
      const made = madeSchema.safeParse(
        yield* this.#stations.ask(workspace, station, "POST", "/sessions", { runtime })
      );
      if (!made.success)
        return yield* Effect.fail(
          new CoreError("bad_response", "The station made no chat.")
        );
      return { session: made.data.key, thread: made.data.thread.id };
    });
  }
}

/** When the row's card or question was asked. */
function askedAt(row: StationChatRow): number {
  const asked = row.card ?? row.decision ?? row.need;
  return asked?.message.createdAt ?? 0;
}

function param(raw: unknown, name: string, max = 256): string {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
}
