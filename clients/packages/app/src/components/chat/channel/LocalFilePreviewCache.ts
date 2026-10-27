import type { ChatImagePreviewRef, LocalFilePreview } from "@comma/core/chat";

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
  /** Other keys this entry answers for (`alias`), dropped with it. */
  aliases: Set<string>;
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
 *
 * One image can be named by two refs over that handoff: a draft upload is
 * previewed from the bytes the core holds, and the message it is sent in reads
 * it by the path it uploaded to. `alias` joins the second name to the entry
 * the first already holds, so the handoff shares the URL instead of reading
 * the image again.
 */
export class LocalFilePreviewCache {
  readonly #entries = new Map<string, PreviewEntry>();
  /** An alias key, and the key of the held entry it is served by. */
  readonly #aliases = new Map<string, string>();
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
    const existing = this.#entries.get(key) ?? this.#readyAliasedEntry(key);
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
      aliases: new Set(),
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

  /**
   * `previewRef` names the image `ofPreviewRef` is held as: acquisitions of
   * it share that entry once it is ready, while it lives. Nothing is loaded
   * here; without a held entry (never acquired, or retired since) nothing is
   * kept, and a later acquisition of `previewRef` loads it on its own. A load
   * still to come is not joined: its ref can stop answering (an upload's bytes
   * are let go once its message takes it) while `previewRef` still does, so
   * an acquisition before the entry is ready loads `previewRef` itself.
   */
  alias(previewRef: ChatImagePreviewRef, ofPreviewRef: ChatImagePreviewRef) {
    if (this.#disposed) return;
    const key = imagePreviewRefKey(previewRef);
    const targetKey = imagePreviewRefKey(ofPreviewRef);
    if (key === targetKey || this.#entries.has(key)) return;
    const target = this.#entries.get(targetKey);
    if (!target) return;
    const previousTargetKey = this.#aliases.get(key);
    if (previousTargetKey === targetKey) return;
    if (previousTargetKey !== undefined) {
      this.#entries.get(previousTargetKey)?.aliases.delete(key);
    }
    this.#aliases.set(key, targetKey);
    target.aliases.add(key);
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#queue = [];
    this.#aliases.clear();

    const entries = [...this.#entries.values()];
    this.#entries.clear();
    this.#pendingEntries = 0;
    for (const entry of entries) {
      entry.aliases.clear();
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

  /**
   * The ready entry an alias key is served by. One still loading serves it
   * not (yet); a stale alias is dropped.
   */
  #readyAliasedEntry(key: string) {
    const targetKey = this.#aliases.get(key);
    if (targetKey === undefined) return undefined;
    const target = this.#entries.get(targetKey);
    if (target) return target.state === "ready" ? target : undefined;
    this.#aliases.delete(key);
    return undefined;
  }

  #forget(entry: PreviewEntry) {
    this.#entries.delete(entry.key);
    for (const alias of entry.aliases) {
      if (this.#aliases.get(alias) === entry.key) this.#aliases.delete(alias);
    }
    entry.aliases.clear();
  }

  #retireUnavailable(entry: PreviewEntry) {
    if (this.#entries.get(entry.key) === entry) {
      this.#pendingEntries -= 1;
      this.#forget(entry);
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

      this.#forget(entry);
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
    this.#forget(entry);
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
  if (ref.kind === "attachment")
    return ["attachment", ref.messageId, ref.index, ref.fileName].join(":");
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
