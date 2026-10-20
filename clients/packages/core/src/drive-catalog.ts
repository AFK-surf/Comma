// Drive search on the desktop: an index of this installation's Drive files (the local node's metadata, every space,
// newest first) that `driveSearch` topics read. Only metadata: no file is read or changed here.
//
// One worker fiber, alive while a `driveSearch` topic is shown, takes its wakes (the 20 s period, the node's changes
// settled for 150 ms, a retry) one at a time and builds when a wake calls for it: builds never overlap, and a change
// that comes during a build wakes it again after. Its timing is the core's Clock (a TestClock in tests).
//
// Bounds: one build at a time, each within 60 s (a failed or late build keeps the last complete index); a build reads
// one page of 500 entries at a time and yields between pages and every few thousand steps of sorting and indexing.
// Builds run only while a `driveSearch` topic is shown: when the first is, every 20 s after, and 150 ms after the node
// last said it changed (after a failure, only on a change or `driveSearch.retry`). An answer scans at most 2048
// candidates for each 5 items its limit asks: a sparse match says `more` rather than nothing, and a larger limit scans on.
import {
  CoreError,
  topicKey,
  type Scoped,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Duration, Effect, Queue, Stream } from "effect";
import type { DriveCatalogItem, DriveSearchValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { LocalDrivePorts, LocalDriveState } from "./host.ts";

const REFRESH_MS = 20_000;
const SETTLE_MS = 150;
const STARTING_POLL_MS = 500;
const BUILD_BUDGET_MS = 60_000;
const PAGE_SIZE = 500;
const SCAN_PER_FIVE = 2048;
const MAX_LIMIT = 500;
const YIELD_EVERY = 2048;

interface Index {
  rows: DriveCatalogItem[];
  text: string[];
  postings: Map<string, Uint32Array>;
}
const emptyIndex = (): Index => ({ rows: [], text: [], postings: new Map() });
const normalize = (value: string) => value.trim().toLowerCase();

function grams(value: string, length: number): Set<string> {
  const result = new Set<string>();
  for (let i = 0; i <= value.length - length; i++)
    result.add(value.slice(i, i + length));
  return result;
}

const compare = (a: DriveCatalogItem, b: DriveCatalogItem) =>
  b.entry.mtimeMs - a.entry.mtimeMs ||
  a.spaceId.localeCompare(b.spaceId) ||
  a.entry.path.localeCompare(b.entry.path);

const sameRow = (a: DriveCatalogItem, b: DriveCatalogItem) =>
  a.spaceName === b.spaceName &&
  a.entry.contentRoot === b.entry.contentRoot &&
  a.entry.mtimeMs === b.entry.mtimeMs &&
  a.entry.origin === b.entry.origin &&
  a.entry.size === b.entry.size &&
  a.entry.versions === b.entry.versions;

const unavailable = (reason: string | undefined) =>
  new CoreError("unavailable", reason || "Drive is unavailable. Try again.");
const asCore = (e: { message: string }) => new CoreError("unavailable", e.message);

const timedOut = () =>
  new CoreError("timeout", "Drive file loading timed out. Try again.");

/** Answers `driveSearch` and `driveSearch.retry`. */
/** What wakes the index's worker: the period (and the first show), the node's settled changes, a person's retry. */
type Wake = "tick" | "change" | "retry";

/** Answers `driveSearch` and `driveSearch.retry`. */
export class DriveCatalog {
  readonly #ctx: Ctx;
  readonly #drive: LocalDrivePorts | undefined;
  // What topics show. Only the worker (one fiber) writes these, between builds: no build sees them change.
  #index = emptyIndex();
  #status: DriveSearchValue["status"];
  #reason: string | undefined;
  #revision = 0;
  /** When the last build began (the core's time). */
  #lastBuild = Number.NEGATIVE_INFINITY;
  /** The node changed since the last build began; told by the node at any time, cleared when a build begins. */
  #dirty = true;
  /** The worker's inputs while it runs (none while nothing shows Drive search). */
  #worker: {
    scope: Scoped;
    changes: Queue.Queue<void>;
    retries: Queue.Queue<void>;
  } | null = null;
  readonly #shown = new Set<string>();

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#drive = ctx.host.localDrive;
    this.#status = this.#drive ? "loading" : "unavailable";
    ctx.kernel.source("driveSearch", {
      start: (topic) => this.#show(topic),
      stop: (topic) => this.#hide(topic),
      compute: (topic) => this.#answer(topic),
    });
    ctx.kernel.calls({
      "driveSearch.retry": {
        run: () =>
          Effect.sync(() => {
            if (this.#worker) Queue.offerUnsafe(this.#worker.retries, undefined);
            return null;
          }),
      },
    });
    this.#drive?.onChange(() => {
      this.#dirty = true;
      if (this.#worker) Queue.offerUnsafe(this.#worker.changes, undefined);
    });
  }

  #show(topic: Topic): void {
    const drive = this.#drive;
    if (!drive) return;
    this.#shown.add(topicKey(topic));
    if (this.#worker) return;
    const { runner } = this.#ctx;
    const scope = runner.child();
    const changes = Effect.runSync(Queue.unbounded<void>());
    const retries = Effect.runSync(Queue.unbounded<void>());
    this.#worker = { scope, changes, retries };
    // One fiber takes every wake in turn, so builds never overlap; a wake that finds nothing to do does nothing.
    const wakes = Stream.mergeAll(
      [
        Stream.tick(Duration.millis(REFRESH_MS)).pipe(Stream.map((): Wake => "tick")),
        Stream.fromQueue(changes).pipe(
          Stream.debounce(Duration.millis(SETTLE_MS)),
          Stream.map((): Wake => "change")
        ),
        Stream.fromQueue(retries).pipe(Stream.map((): Wake => "retry")),
      ],
      { concurrency: "unbounded" }
    );
    runner.fork(
      wakes.pipe(Stream.runForEach((wake) => this.#wake(drive, wake))),
      scope
    );
  }

  #hide(topic: Topic): void {
    this.#shown.delete(topicKey(topic));
    if (this.#shown.size > 0 || !this.#worker) return;
    // Nothing shows Drive search: the worker stops, a build under way with it (the index stays as it was).
    this.#ctx.runner.close(this.#worker.scope);
    this.#worker = null;
  }

  /** Builds when `wake` calls for it: a retry or a change always; the period when the index is stale and not failing. */
  #wake(drive: LocalDrivePorts, wake: Wake): Effect.Effect<void> {
    return Effect.suspend(() => {
      const stale =
        this.#dirty ||
        (this.#status !== "error" && this.#ctx.now() - this.#lastBuild >= REFRESH_MS);
      if (wake === "tick" && !stale) return Effect.void;
      this.#dirty = false;
      this.#lastBuild = this.#ctx.now();
      if (this.#status !== "ready") this.#setStatus("loading");
      return this.#read(drive).pipe(
        Effect.timeoutOrElse({
          duration: Duration.millis(BUILD_BUDGET_MS),
          orElse: () => Effect.fail(timedOut()),
        }),
        Effect.match({
          onSuccess: (index) => {
            if (index !== this.#index) {
              this.#index = index;
              this.#revision += 1;
            }
            this.#setStatus("ready");
          },
          onFailure: (error) => this.#setStatus("error", error.message),
        })
      );
    });
  }

  #setStatus(status: DriveSearchValue["status"], reason?: string): void {
    this.#status = status;
    this.#reason = reason;
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "driveSearch") store.invalidate(topic);
  }

  #read(drive: LocalDrivePorts): Effect.Effect<Index, CoreError> {
    return Effect.gen({ self: this }, function* () {
      let state: LocalDriveState = yield* drive.state.pipe(Effect.mapError(asCore));
      while (state.status === "starting") {
        yield* Effect.sleep(Duration.millis(STARTING_POLL_MS));
        state = yield* drive.state.pipe(Effect.mapError(asCore));
      }
      if (state.status !== "ready")
        return yield* Effect.fail(unavailable(state.reason));
      const rows = new Map<string, DriveCatalogItem>();
      for (const space of state.spaces) {
        const spaceName =
          space.label || (space.id === state.defaultSpace ? "Drive" : space.id);
        let cursor = "";
        do {
          const page = yield* drive
            .list({
              space: space.id,
              policy: "newest",
              limit: PAGE_SIZE,
              ...(cursor ? { cursor } : {}),
            })
            .pipe(Effect.mapError(asCore));
          for (const entry of page.entries)
            if (entry.kind === "file")
              rows.set(JSON.stringify([space.id, entry.path]), {
                spaceId: space.id,
                spaceName,
                entry,
              });
          if (page.nextCursor && page.nextCursor === cursor)
            return yield* Effect.fail(
              new CoreError("unavailable", "Drive listing did not advance. Try again.")
            );
          cursor = page.nextCursor;
          yield* this.#ctx.host.yieldTurn;
        } while (cursor);
      }
      const previous = this.#index;
      if (this.#revision > 0 && rows.size === previous.rows.length) {
        const unchanged = previous.rows.every((row) => {
          const next = rows.get(JSON.stringify([row.spaceId, row.entry.path]));
          return next !== undefined && sameRow(row, next);
        });
        if (unchanged) return previous;
      }
      return yield* buildIndex([...rows.values()], this.#ctx.host.yieldTurn);
    });
  }

  #answer(topic: Topic): Value {
    const limit = Math.min(
      MAX_LIMIT,
      Math.max(1, Number.parseInt(String(topic.limit), 10) || 1)
    );
    const query = normalize(typeof topic.query === "string" ? topic.query : "");
    const index = this.#index;
    let candidates: Uint32Array | undefined;
    if (query)
      for (const gram of grams(query, Math.min(3, query.length))) {
        const posting = index.postings.get(gram) ?? new Uint32Array();
        if (!candidates || posting.length < candidates.length) candidates = posting;
      }
    const count = candidates?.length ?? index.rows.length;
    const items: DriveCatalogItem[] = [];
    let offset = 0;
    let scanned = 0;
    const scanLimit = SCAN_PER_FIVE * Math.ceil(limit / 5);
    while (offset < count && items.length < limit && scanned++ < scanLimit) {
      const id = candidates ? candidates[offset]! : offset;
      offset++;
      if (!query || index.text[id]!.includes(query)) items.push(index.rows[id]!);
    }
    const value: DriveSearchValue = {
      status: this.#status,
      ...(this.#reason ? { reason: this.#reason } : {}),
      revision: this.#revision,
      items,
      more: offset < count,
    };
    return { ok: value };
  }
}

/** Sorts the rows newest first and indexes their text by 1-, 2- and 3-character grams (short and CJK queries). */
function buildIndex(
  unsorted: DriveCatalogItem[],
  yieldTurn: Effect.Effect<void>
): Effect.Effect<Index> {
  return Effect.gen(function* () {
    let steps = 0;
    const step = function* () {
      if (++steps % YIELD_EVERY === 0) yield* yieldTurn;
    };
    // A merge sort that yields: a large catalog does not hold the core's thread.
    let sorted = unsorted;
    for (let width = 1; width < sorted.length; width *= 2) {
      const next: DriveCatalogItem[] = [];
      for (let start = 0; start < sorted.length; start += 2 * width) {
        let left = start;
        let right = Math.min(start + width, sorted.length);
        const leftEnd = right;
        const rightEnd = Math.min(start + 2 * width, sorted.length);
        while (left < leftEnd || right < rightEnd) {
          next.push(
            right >= rightEnd ||
              (left < leftEnd && compare(sorted[left]!, sorted[right]!) <= 0)
              ? sorted[left++]!
              : sorted[right++]!
          );
          yield* step();
        }
      }
      sorted = next;
    }
    const out = emptyIndex();
    out.rows = sorted;
    const postings = new Map<string, number[]>();
    for (let id = 0; id < sorted.length; id++) {
      const row = sorted[id]!;
      const text = normalize(
        `${row.entry.path}\n${row.spaceName} / ${row.entry.path.replaceAll("/", " / ")}`
      );
      out.text.push(text);
      for (let length = 1; length <= 3; length++)
        for (const gram of grams(text, length)) {
          const posting = postings.get(gram);
          if (posting) posting.push(id);
          else postings.set(gram, [id]);
        }
      yield* step();
    }
    for (const [gram, ids] of postings) {
      out.postings.set(gram, Uint32Array.from(ids));
      yield* step();
    }
    return out;
  });
}
