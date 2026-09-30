import { setImmediate as yieldTurn, setTimeout as delay } from "node:timers/promises";
import type {
  DriveCatalogItem,
  DriveCatalogQueryInput,
  DriveCatalogQueryResult,
  DriveCatalogState,
} from "@comma/native-bridge";
import type { SynchronicityProvider } from "./index";

const REFRESH_MS = 20_000;
const BUILD_BUDGET_MS = 60_000;
const PAGE_SIZE = 500;
const QUERY_SCAN_LIMIT = 2048;
// The index is only metadata. A failed build keeps the previous complete index.
// No durable node data or file contents are changed by this owner.
interface Index {
  rows: DriveCatalogItem[];
  text: string[];
  postings: Map<string, Uint32Array>;
}
const emptyIndex = (): Index => ({ rows: [], text: [], postings: new Map() });
const normalize = (value: string) => value.trim().toLowerCase();
function grams(value: string, length: number) {
  const result = new Set<string>();
  for (let i = 0; i <= value.length - length; i++)
    result.add(value.slice(i, i + length));
  return result;
}
const compare = (a: DriveCatalogItem, b: DriveCatalogItem) =>
  b.entry.mtimeMs - a.entry.mtimeMs ||
  a.spaceId.localeCompare(b.spaceId) ||
  a.entry.path.localeCompare(b.entry.path);

/** One background metadata pipeline per installation, shared by all windows. */
export class DriveCatalogService {
  #index = emptyIndex();
  #state: DriveCatalogState = { revision: 0, status: "idle" };
  #running: Promise<void> | undefined;
  #pendingIO: Promise<unknown> | undefined;
  #lastAttempt = -Infinity;
  #lastDemand = -Infinity;
  #dirty = false;
  #closed = false;
  #timer: ReturnType<typeof setTimeout> | undefined;
  #unsubscribe: (() => void) | undefined;

  constructor(
    private readonly node: Pick<
      SynchronicityProvider,
      "state" | "list" | "subscribeChanges"
    >,
    private readonly publish: (state: DriveCatalogState) => void = () => {}
  ) {
    this.#unsubscribe = node.subscribeChanges?.(() => this.invalidate());
  }

  state = (_input?: void): DriveCatalogState => this.#state;

  query = (input: DriveCatalogQueryInput): DriveCatalogQueryResult => {
    this.#lastDemand = Date.now();
    if (
      !this.#closed &&
      !this.#running &&
      (this.#state.status === "idle" ||
        this.#dirty ||
        input.retry ||
        (input.refresh && Date.now() - this.#lastAttempt >= REFRESH_MS))
    )
      this.#refresh();
    const query = normalize(input.query);
    const cursor = input.cursor;
    const reset =
      !!cursor && (cursor.revision !== this.#state.revision || cursor.query !== query);
    let offset = !reset && cursor ? cursor.offset : 0;
    let candidates: Uint32Array | undefined;
    if (query) {
      for (const gram of grams(query, Math.min(3, query.length))) {
        const posting = this.#index.postings.get(gram) ?? new Uint32Array();
        if (!candidates || posting.length < candidates.length) candidates = posting;
      }
    }
    const count = candidates?.length ?? this.#index.rows.length;
    const items: DriveCatalogItem[] = [];
    let scanned = 0;
    while (
      offset < count &&
      items.length < input.limit &&
      scanned++ < QUERY_SCAN_LIMIT
    ) {
      const id = candidates ? candidates[offset]! : offset;
      offset++;
      if (!query || this.#index.text[id]!.includes(query))
        items.push(this.#index.rows[id]!);
    }
    return {
      state: this.#state,
      items,
      reset,
      ...(offset < count
        ? { nextCursor: { revision: this.#state.revision, offset, query } }
        : {}),
    };
  };

  invalidate() {
    this.#dirty = true;
    if (this.#closed || this.#timer || Date.now() - this.#lastDemand > REFRESH_MS)
      return;
    // Batch a burst of recording/transcript/upload commits into one refresh.
    this.#timer = setTimeout(() => {
      this.#timer = undefined;
      if (!this.#running) this.#refresh();
    }, 150);
    this.#timer.unref();
  }

  close() {
    this.#closed = true;
    this.#unsubscribe?.();
    if (this.#timer) clearTimeout(this.#timer);
  }

  #setState(state: DriveCatalogState) {
    if (this.#closed) return;
    this.#state = state;
    this.publish(state);
  }

  #refresh() {
    // A timed-out transport may still be unwinding. Never stack another
    // metadata pipeline on that call; the error stays actionable meanwhile.
    if (this.#pendingIO || this.#closed) return;
    this.#dirty = false;
    this.#lastAttempt = Date.now();
    this.#setState({ revision: this.#state.revision, status: "loading" });
    this.#running = this.#build()
      .then((index) => {
        if (this.#closed) return;
        const revision = this.#state.revision + (index !== this.#index ? 1 : 0);
        this.#index = index;
        this.#setState({ revision, status: "ready" });
      })
      .catch((error: unknown) => {
        this.#setState({
          revision: this.#state.revision,
          status: "error",
          reason:
            error instanceof Error
              ? error.message
              : "Drive could not load files. Try again.",
        });
      })
      .finally(() => {
        this.#running = undefined;
        // Only one follow-up for commits that arrived during the read.
        if (this.#dirty && !this.#closed && Date.now() - this.#lastDemand <= REFRESH_MS)
          this.invalidate();
      });
  }

  async #build(): Promise<Index> {
    const deadline = Date.now() + BUILD_BUDGET_MS;
    const budget = () => {
      if (this.#closed || Date.now() >= deadline)
        throw new Error("Drive file loading timed out. Try again.");
    };
    const read = async <T>(request: () => Promise<T> | T): Promise<T> => {
      budget();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const operation = Promise.resolve().then(request);
      this.#pendingIO = operation;
      const settled = () => {
        if (this.#pendingIO === operation) this.#pendingIO = undefined;
      };
      void operation.then(settled, settled);
      try {
        return await Promise.race([
          operation,
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(new Error("Drive file loading timed out. Try again.")),
              deadline - Date.now()
            );
            timer.unref();
          }),
        ]);
      } finally {
        if (timer) clearTimeout(timer);
      }
    };
    let state = await read(() => this.node.state());
    while (state.status === "starting") {
      await delay(500);
      budget();
      state = await read(() => this.node.state());
    }
    if (state.status !== "ready")
      throw new Error(state.reason || "Drive is unavailable. Try again.");
    const rows = new Map<string, DriveCatalogItem>();
    for (const space of state.spaces) {
      let cursor = "";
      do {
        budget();
        const page = await read(() =>
          this.node.list({
            space: space.id,
            policy: "newest",
            limit: PAGE_SIZE,
            ...(cursor ? { cursor } : {}),
          })
        );
        for (const entry of page.entries) {
          if (entry.kind === "file")
            rows.set(JSON.stringify([space.id, entry.path]), {
              spaceId: space.id,
              spaceName:
                space.label || (space.id === state.defaultSpace ? "Drive" : space.id),
              entry,
            });
        }
        if (page.nextCursor && page.nextCursor === cursor)
          throw new Error("Drive listing did not advance. Try again.");
        cursor = page.nextCursor;
        await yieldTurn();
      } while (cursor);
    }
    if (this.#state.revision > 0 && rows.size === this.#index.rows.length) {
      let unchanged = true;
      for (let i = 0; i < this.#index.rows.length; i++) {
        const previous = this.#index.rows[i]!;
        const next = rows.get(JSON.stringify([previous.spaceId, previous.entry.path]));
        if (
          !next ||
          next.spaceName !== previous.spaceName ||
          next.entry.contentRoot !== previous.entry.contentRoot ||
          next.entry.mtimeMs !== previous.entry.mtimeMs ||
          next.entry.origin !== previous.entry.origin ||
          next.entry.size !== previous.entry.size ||
          next.entry.versions !== previous.entry.versions
        ) {
          unchanged = false;
          break;
        }
        if (i % 500 === 0) {
          await yieldTurn();
          budget();
        }
      }
      if (unchanged) return this.#index;
    }
    // Cooperative merge sort: neither the final sort nor postings construction
    // monopolizes Electron Main as a large catalog completes.
    let sorted = [...rows.values()];
    for (let width = 1; width < sorted.length; width *= 2) {
      const next: DriveCatalogItem[] = [];
      for (let start = 0; start < sorted.length; start += 2 * width) {
        let left = start,
          right = Math.min(start + width, sorted.length);
        const leftEnd = right,
          rightEnd = Math.min(start + 2 * width, sorted.length);
        while (left < leftEnd || right < rightEnd) {
          next.push(
            right >= rightEnd ||
              (left < leftEnd && compare(sorted[left]!, sorted[right]!) <= 0)
              ? sorted[left++]!
              : sorted[right++]!
          );
          if (next.length % 2048 === 0) {
            await yieldTurn();
            budget();
          }
        }
      }
      sorted = next;
    }
    const index = emptyIndex();
    index.rows = sorted;
    const postings = new Map<string, number[]>();
    for (let id = 0; id < sorted.length; id++) {
      const row = sorted[id]!;
      const text = normalize(
        `${row.entry.path}\n${row.spaceName} / ${row.entry.path.replaceAll("/", " / ")}`
      );
      index.text.push(text);
      // One-, two-, and three-code-unit postings also support short and CJK
      // substring queries. Posting order is already global recency order.
      for (let length = 1; length <= 3; length++) {
        for (const gram of grams(text, length)) {
          const posting = postings.get(gram);
          if (posting) posting.push(id);
          else postings.set(gram, [id]);
        }
      }
      if (id % 128 === 0) {
        await yieldTurn();
        budget();
      }
    }
    let converted = 0;
    for (const [gram, ids] of postings) {
      index.postings.set(gram, Uint32Array.from(ids));
      postings.delete(gram);
      if (++converted % 128 === 0) {
        await yieldTurn();
        budget();
      }
    }
    return index;
  }
}
