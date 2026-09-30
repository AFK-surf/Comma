import type {
  ChatImagePreviewRef,
  LocalFilePreview,
} from "../../../components/chat/model/conversationChannel";

const MAX_CONCURRENT_LOCAL_FILE_PREVIEW_LOADS = 4;
const MAX_PENDING_LOCAL_FILE_PREVIEWS = 50;

type LocalFilePreviewLoader = (
  previewRef: ChatImagePreviewRef
) => Promise<Uint8Array | undefined>;

type PreviewWaiter = {
  onAbort: () => void;
  resolve(preview: LocalFilePreview | undefined): void;
  signal: AbortSignal | undefined;
};

type PreviewEntry = {
  key: string;
  leaseCount: number;
  previewRef: ChatImagePreviewRef;
  retirement: number;
  state: "queued" | "loading" | "ready" | "retired";
  url: string | undefined;
  waiters: Set<PreviewWaiter>;
};

/**
 * Renderer-owned, session-local presentation cache for bounded PNG previews.
 *
 * Acquisition work is bounded independently of mounted presentations: fifty
 * pending sources and four native loads. Ready URLs belong to their consumers;
 * they must not deny a later image just because earlier images remain mounted.
 * Entries are single-flighted only while they have pending or active consumers.
 * The last release retires the URL in a microtask so a Composer attachment can
 * hand the same preview to its pending/canonical message in one React commit.
 * There is no idle or negative cache: the next later acquisition returns to
 * Main, where owner and lifecycle authorization is evaluated again.
 */
export class LocalFilePreviewCache {
  readonly #entries = new Map<string, PreviewEntry>();
  readonly #load: LocalFilePreviewLoader;
  #activeLoads = 0;
  #pendingEntries = 0;
  #disposed = false;
  #queue: PreviewEntry[] = [];

  constructor({ load }: { load: LocalFilePreviewLoader }) {
    this.#load = load;
  }

  acquire(
    previewRef: ChatImagePreviewRef,
    signal?: AbortSignal
  ): Promise<LocalFilePreview | undefined> {
    if (this.#disposed || signal?.aborted) return Promise.resolve(undefined);

    const key = imagePreviewRefKey(previewRef);
    const existing = this.#entries.get(key);
    if (existing?.state === "ready") {
      // Invalidate any last-release microtask that has not run yet.
      existing.retirement += 1;
      return Promise.resolve(this.#createLease(existing));
    }
    if (existing?.state === "queued" || existing?.state === "loading") {
      return this.#waitForEntry(existing, signal);
    }

    if (this.#pendingEntries >= MAX_PENDING_LOCAL_FILE_PREVIEWS) {
      return Promise.resolve(undefined);
    }

    const entry: PreviewEntry = {
      key,
      leaseCount: 0,
      previewRef,
      retirement: 0,
      state: "queued",
      url: undefined,
      waiters: new Set(),
    };
    this.#pendingEntries += 1;
    this.#entries.set(key, entry);
    this.#queue.push(entry);
    const preview = this.#waitForEntry(entry, signal);
    this.#pump();
    return preview;
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#queue = [];

    const entries = [...this.#entries.values()];
    this.#entries.clear();
    this.#pendingEntries = 0;
    for (const entry of entries) {
      entry.retirement += 1;
      if (entry.url) this.#revoke(entry.url);
      entry.url = undefined;
      entry.state = "retired";
      this.#resolveWaiters(entry, undefined);
    }
  }

  #createLease(entry: PreviewEntry): LocalFilePreview {
    const url = entry.url;
    if (!url) {
      throw new Error("A ready local-file preview must own an object URL.");
    }
    entry.leaseCount += 1;
    let released = false;
    return {
      release: () => {
        if (released) return;
        released = true;
        this.#release(entry);
      },
      url,
    };
  }

  #finishLoad(entry: PreviewEntry, bytes: Uint8Array | undefined) {
    this.#activeLoads = Math.max(0, this.#activeLoads - 1);

    if (
      this.#disposed ||
      this.#entries.get(entry.key) !== entry ||
      entry.state !== "loading"
    ) {
      this.#resolveWaiters(entry, undefined);
      this.#pump();
      return;
    }

    if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) {
      this.#retireUnavailable(entry);
      this.#pump();
      return;
    }

    // Every consumer may have left while the non-cancellable native call was
    // already active. Do not create a blob URL for a result nobody owns.
    if (entry.waiters.size === 0 && entry.leaseCount === 0) {
      this.#retireUnavailable(entry);
      this.#pump();
      return;
    }

    let url: string;
    try {
      url = URL.createObjectURL(
        new Blob([Uint8Array.from(bytes)], { type: previewMediaType(bytes) })
      );
    } catch {
      this.#retireUnavailable(entry);
      this.#pump();
      return;
    }

    this.#pendingEntries -= 1;
    entry.state = "ready";
    entry.url = url;
    const waiters = [...entry.waiters];
    entry.waiters.clear();
    for (const waiter of waiters) {
      waiter.signal?.removeEventListener("abort", waiter.onAbort);
      waiter.resolve(this.#createLease(entry));
    }
    if (entry.leaseCount === 0) this.#scheduleRetirement(entry);
    this.#pump();
  }

  #pump() {
    if (this.#disposed) return;

    while (
      this.#activeLoads < MAX_CONCURRENT_LOCAL_FILE_PREVIEW_LOADS &&
      this.#queue.length > 0
    ) {
      const entry = this.#queue.shift();
      if (
        !entry ||
        entry.state !== "queued" ||
        this.#entries.get(entry.key) !== entry
      ) {
        continue;
      }

      entry.state = "loading";
      this.#activeLoads += 1;
      let result: Promise<Uint8Array | undefined>;
      try {
        result = Promise.resolve(this.#load(entry.previewRef));
      } catch {
        result = Promise.resolve(undefined);
      }
      void result.then(
        (bytes) => this.#finishLoad(entry, bytes),
        () => this.#finishLoad(entry, undefined)
      );
    }
  }

  #release(entry: PreviewEntry) {
    if (entry.leaseCount > 0) entry.leaseCount -= 1;
    if (
      !this.#disposed &&
      entry.leaseCount === 0 &&
      entry.state === "ready" &&
      this.#entries.get(entry.key) === entry
    ) {
      this.#scheduleRetirement(entry);
    }
  }

  #resolveWaiters(entry: PreviewEntry, preview: LocalFilePreview | undefined) {
    const waiters = [...entry.waiters];
    entry.waiters.clear();
    for (const waiter of waiters) {
      waiter.signal?.removeEventListener("abort", waiter.onAbort);
      waiter.resolve(preview);
    }
  }

  #retireUnavailable(entry: PreviewEntry) {
    if (this.#entries.get(entry.key) === entry) {
      this.#pendingEntries -= 1;
      this.#entries.delete(entry.key);
    }
    entry.state = "retired";
    this.#resolveWaiters(entry, undefined);
  }

  #scheduleRetirement(entry: PreviewEntry) {
    const retirement = ++entry.retirement;
    queueMicrotask(() => {
      if (
        this.#disposed ||
        entry.retirement !== retirement ||
        entry.leaseCount !== 0 ||
        entry.state !== "ready" ||
        this.#entries.get(entry.key) !== entry
      ) {
        return;
      }

      this.#entries.delete(entry.key);
      entry.state = "retired";
      const url = entry.url;
      entry.url = undefined;
      if (url) this.#revoke(url);
    });
  }

  #revoke(url: string) {
    try {
      URL.revokeObjectURL(url);
    } catch {
      // The cache is already retired even if the host refuses URL cleanup.
    }
  }

  #waitForEntry(entry: PreviewEntry, signal?: AbortSignal) {
    return new Promise<LocalFilePreview | undefined>((resolve) => {
      if (signal?.aborted) {
        resolve(undefined);
        this.#retireUnusedQueuedEntry(entry);
        return;
      }
      const waiter: PreviewWaiter = {
        onAbort: () => {
          if (!entry.waiters.delete(waiter)) return;
          signal?.removeEventListener("abort", waiter.onAbort);
          resolve(undefined);
          this.#retireUnusedQueuedEntry(entry);
        },
        resolve,
        signal,
      };
      entry.waiters.add(waiter);
      signal?.addEventListener("abort", waiter.onAbort, { once: true });
    });
  }

  #retireUnusedQueuedEntry(entry: PreviewEntry) {
    if (
      entry.state !== "queued" ||
      entry.waiters.size !== 0 ||
      entry.leaseCount !== 0 ||
      this.#entries.get(entry.key) !== entry
    ) {
      return;
    }
    this.#pendingEntries -= 1;
    this.#entries.delete(entry.key);
    entry.state = "retired";
    const queueIndex = this.#queue.indexOf(entry);
    if (queueIndex >= 0) this.#queue.splice(queueIndex, 1);
  }
}

/**
 * Main re-encodes the sources it can decode as PNG and passes GIF and WebP
 * through untouched, so the signature decides which media type the object
 * URL carries.
 */
function previewMediaType(bytes: Uint8Array) {
  if (
    bytes.length >= 6 &&
    bytes[0] === 0x47 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46
  ) {
    return "image/gif";
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return "image/webp";
  }
  return "image/png";
}

function imagePreviewRefKey(ref: ChatImagePreviewRef) {
  if (typeof ref === "string") return `string:${ref}`;
  return [
    "agent-blob",
    ref.agentId,
    ref.blobRef.uuid,
    ref.blobRef.hash,
    ref.blobRef.size,
    ref.fileName,
    ref.mediaType,
  ].join(":");
}
