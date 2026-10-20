// A participant's session history in a conversation: what the agent's model and tools did. Pages are read only when
// a UI asks (`history.load`); while a UI shows the history, the core keeps the server's live stream of it open, and a
// reconnect replays from the last checkpoint the stream completed (a cycle cut short never moves it).
//
// Bounds: at most 24 histories kept per account at once (one not shown and not loading gives its place up); one page
// read in flight per history, given up after 30 s; one stream per shown history (it ends 1 s after the last view), each connection at most 65 s, and
// after one ends or fails the next waits 1, 2, 4, 8 then 10 s (the wait starts again at 1 s once a frame arrives).
// Nothing is polled. Histories are kept only for this run, not on the device.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Deferred, Effect, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { historyFrameSchema, historyPageSchema } from "./comma/schemas.ts";
import type { SessionHistoryRecord, SessionHistoryValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { readEvents } from "./sse.ts";

const MAX_KEPT = 24;
const PAGE_TIMEOUT_MS = 30_000;
const CONNECTION_MS = 65_000;
const STREAM_GRACE_MS = 1_000;
const RECENT_MS = 180_000;

type Target = { group: string; conversation: string; participant: string };
type Mode = "preview" | "latest" | "older";

type Entry = {
  target: Target;
  value: SessionHistoryValue;
  /** The page read under way, which a second ask for the same history waits for. */
  pending: Effect.Effect<void> | null;
  /** The last checkpoint a stream cycle completed: a reconnect replays what came after it. */
  checkpoint: string | null;
  /** The newest record of the first page read: the stream adds only what is newer than it to the pages. */
  ledgerHead: string | null;
};

const keyOf = (t: Target) => JSON.stringify([t.group, t.conversation, t.participant]);

function targetOf(topic: Topic | Record<string, unknown> | null): Target {
  const t = topic as Partial<Record<string, unknown>> | null;
  const group = t?.group;
  const conversation = t?.conversation;
  const participant = t?.participant;
  if (
    typeof group !== "string" ||
    !group ||
    typeof conversation !== "string" ||
    !conversation ||
    typeof participant !== "string" ||
    !participant
  )
    throw CoreError.invalid("group, conversation and participant are required");
  return { group, conversation, participant };
}

function empty(t: Target): SessionHistoryValue {
  return {
    groupId: t.group,
    conversationId: t.conversation,
    participantId: t.participant,
    records: [],
    recentRecords: [],
    liveRecords: [],
    clockOffsetMs: 0,
    streamStatus: "closed",
    status: "idle",
    loaded: "none",
    error: null,
    hasMore: false,
    nextBefore: null,
  };
}

// Internal transcript ids are decimal sequence numbers and external ones ULIDs; each is ordered within its history.
const orderKey = (id: string) => (/^\d{1,20}$/.test(id) ? id.padStart(32, "0") : id);
function compareIds(a: string, b: string): number {
  const x = orderKey(a);
  const y = orderKey(b);
  return x < y ? -1 : x > y ? 1 : 0;
}

/** `current` with `incoming` added or replacing records of the same id, oldest first. */
function merge(
  current: SessionHistoryRecord[],
  incoming: readonly SessionHistoryRecord[]
): SessionHistoryRecord[] {
  const byId = new Map(current.map((record) => [record.id, record]));
  for (const record of incoming) byId.set(record.id, record);
  return [...byId.values()].toSorted((a, b) => compareIds(a.id, b.id));
}

export class History {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #entries = new Map<string, Entry>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    ctx.kernel.source("history", {
      // The stream ends with the last view (a view back within the second keeps it).
      evictAfterMs: STREAM_GRACE_MS,
      start: (topic) => {
        const target = targetOf(topic);
        this.#live.run(topic, this.#stream(target));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        const entry = this.#entries.get(keyOf(targetOf(topic)));
        if (entry) this.#set(entry, { streamStatus: "closed" });
      },
      compute: (topic): Value => ({ ok: this.#entry(targetOf(topic)).value }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing of one account's histories is shown for another.
      this.#entries.clear();
      for (const topic of ctx.kernel.store.liveTopics()) {
        if (topic.topic !== "history") continue;
        this.#live.stop(topic);
        ctx.kernel.store.invalidate(topic);
        this.#live.run(topic, this.#stream(targetOf(topic)));
      }
    });
    ctx.kernel.calls({
      "history.load": {
        run: (p) => {
          const target = targetOf(p as Record<string, unknown> | null);
          const mode = (p as { mode?: unknown }).mode;
          if (mode !== "preview" && mode !== "latest" && mode !== "older")
            return Effect.fail(CoreError.invalid("mode is preview, latest or older"));
          return this.#load(target, mode).pipe(Effect.as(null));
        },
      },
    });
  }

  #topic(target: Target): Topic {
    return {
      topic: "history",
      group: target.group,
      conversation: target.conversation,
      participant: target.participant,
    };
  }

  #entry(target: Target): Entry {
    const key = keyOf(target);
    let entry = this.#entries.get(key);
    if (entry) return entry;
    if (this.#entries.size >= MAX_KEPT) {
      const shown = new Set(
        this.#ctx.kernel.store
          .liveTopics()
          .filter((t) => t.topic === "history")
          .map((t) => keyOf(targetOf(t)))
      );
      const victim = [...this.#entries].find(
        ([k, item]) => !item.pending && !shown.has(k)
      );
      if (!victim) throw new CoreError("busy", "too many session histories are open");
      this.#entries.delete(victim[0]);
    }
    entry = {
      target,
      value: empty(target),
      pending: null,
      checkpoint: null,
      ledgerHead: null,
    };
    this.#entries.set(key, entry);
    return entry;
  }

  /** Changes what the history shows; a change that changes nothing sends nothing. */
  #set(entry: Entry, patch: Partial<SessionHistoryValue>): void {
    const current = entry.value;
    if (
      (Object.keys(patch) as (keyof SessionHistoryValue)[]).every((k) =>
        Object.is(patch[k], current[k])
      )
    )
      return;
    entry.value = { ...current, ...patch };
    if (this.#entries.get(keyOf(entry.target)) === entry)
      this.#ctx.kernel.store.invalidate(this.#topic(entry.target));
  }

  #load(target: Target, mode: Mode): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
      const entry = this.#entry(target);
      if (entry.pending) {
        yield* entry.pending;
        // Asks that came while a page was read share it; the latest page after a preview is still to read.
        if (mode !== "latest" || entry.value.loaded === "detail") return;
        return yield* this.#load(target, mode);
      }
      const shown = entry.value;
      if (mode === "preview" && shown.loaded !== "none") return;
      if (mode === "older" && (!shown.hasMore || shown.loaded !== "detail")) return;
      const before = mode === "older" ? shown.nextBefore : null;
      // Set before anything else runs: an ask that comes while this page is read waits for it.
      const done = yield* Deferred.make<void>();
      const pending = Deferred.await(done);
      entry.pending = pending;
      yield* this.#page(account, entry, mode, before).pipe(
        Effect.ignore,
        Effect.ensuring(
          Effect.suspend(() => {
            if (entry.pending === pending) entry.pending = null;
            return Deferred.succeed(done, undefined);
          })
        )
      );
    });
  }

  #page(
    account: Account,
    entry: Entry,
    mode: Mode,
    before: string | null
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    const { group, conversation, participant } = entry.target;
    const query = new URLSearchParams({ limit: mode === "preview" ? "3" : "50" });
    if (before) query.set("before", before);
    const path = `${route`/v1/comma/groups/${group}/conversations/${conversation}/participants/${participant}/history`}?${query}`;
    this.#set(entry, { status: "loading", error: null });
    return ctx.api
      .request(account, "GET", path, historyPageSchema, undefined, PAGE_TIMEOUT_MS)
      .pipe(
        Effect.filterOrFail(
          (page) =>
            page.conversation_id === conversation &&
            page.participant_id === participant &&
            !(
              page.has_more &&
              (!page.next_before ||
                page.next_before === before ||
                page.records.length === 0)
            ),
          () =>
            new CoreError(
              "bad_response",
              "a page of another history, or no way past it"
            )
        ),
        Effect.result,
        Effect.map((result) => {
          // An answer for an account another took the place of, or a history let go, shows nowhere.
          if (account.closed || this.#entries.get(keyOf(entry.target)) !== entry)
            return;
          if (Result.isFailure(result)) {
            this.#set(entry, {
              status: "error",
              error: result.failure.status === 403 ? "forbidden" : "unavailable",
            });
            return;
          }
          const page = result.success;
          const shown = entry.value;
          entry.ledgerHead ??= page.records.at(-1)?.id ?? "0";
          const head = entry.ledgerHead;
          // Reading the latest page again keeps the cursor of the older pages already read.
          const keepCursor = !before && shown.loaded === "detail";
          this.#set(entry, {
            records: merge(
              merge(shown.records, page.records),
              shown.recentRecords.filter((record) => compareIds(record.id, head) > 0)
            ),
            loaded: mode === "preview" ? "preview" : "detail",
            hasMore: keepCursor ? shown.hasMore : page.has_more,
            nextBefore: keepCursor ? shown.nextBefore : (page.next_before ?? null),
            status: "ready",
            error: null,
          });
        })
      );
  }

  /** The live stream while the history is shown: each connection, then a wait, until the topic stops. */
  #stream(target: Target): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = ctx.session.current();
      if (!account) return;
      let attempt = 0;
      for (;;) {
        const entry = this.#entry(target);
        this.#set(entry, {
          streamStatus: attempt === 0 ? "connecting" : "reconnecting",
        });
        const connected = yield* Effect.result(
          this.#connect(account, entry, () => {
            attempt = 0;
          }).pipe(
            Effect.timeoutOrElse({ duration: CONNECTION_MS, orElse: () => Effect.void })
          )
        );
        if (account.closed) return;
        void connected;
        this.#set(this.#entry(target), { streamStatus: "reconnecting" });
        yield* Effect.sleep(Math.min(10_000, 1_000 * 2 ** attempt));
        attempt++;
      }
    });
  }

  #connect(
    account: Account,
    entry: Entry,
    onFrame: () => void
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    const { group, conversation, participant } = entry.target;
    return Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const query = entry.checkpoint
          ? `?${new URLSearchParams({ after: entry.checkpoint })}`
          : "";
        const body = yield* ctx.api.stream(
          account,
          `${route`/v1/comma/groups/${group}/conversations/${conversation}/participants/${participant}/history/events`}${query}`
        );
        yield* readEvents(body, (value, event) =>
          Effect.gen({ self: this }, function* () {
            if (event !== "history") return;
            const parsed = historyFrameSchema.safeParse(value);
            if (!parsed.success)
              return yield* Effect.fail(
                new CoreError("bad_response", "a frame outside the history's contract")
              );
            const frame = parsed.data;
            if (
              frame.conversation_id !== conversation ||
              frame.participant_id !== participant
            )
              return yield* Effect.fail(
                new CoreError("bad_response", "a frame of another history")
              );
            if (account.closed || this.#entries.get(keyOf(entry.target)) !== entry)
              return;
            onFrame();
            this.#apply(entry, frame);
          })
        );
      })
    );
  }

  #apply(entry: Entry, frame: ReturnType<typeof historyFrameSchema.parse>): void {
    const shown = entry.value;
    if (frame.phase === "checkpoint") entry.checkpoint = frame.checkpoint;
    const head = entry.ledgerHead;
    const now = this.#ctx.now();
    this.#set(entry, {
      records: merge(
        shown.records,
        frame.phase === "update"
          ? frame.records
          : head === null
            ? []
            : frame.records.filter((record) => compareIds(record.id, head) > 0)
      ),
      recentRecords: merge(shown.recentRecords, frame.records).filter(
        (record) =>
          (record.execution?.observed_at_ms ?? record.timestamp_ms ?? 0) >=
          frame.server_time_ms - RECENT_MS
      ),
      liveRecords: frame.live_records,
      // One clock anchor per connection: jitter between heartbeats must not move a fixed three-minute axis.
      clockOffsetMs:
        shown.streamStatus === "live"
          ? shown.clockOffsetMs
          : frame.server_time_ms - now,
      streamStatus: "live",
    });
  }
}
