import { createHash, randomBytes } from "node:crypto";
import { constants, type BigIntStats, type Dir, type Stats } from "node:fs";
import {
  chmod,
  type FileHandle,
  link,
  lstat,
  mkdir,
  open,
  opendir,
  rename,
  rm,
} from "node:fs/promises";
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  join,
  parse,
  resolve,
} from "node:path";

export const LOCAL_FILE_REF_VERSION = 1;
export const LOCAL_FILE_INDEX_VERSION = 2;
export const LOCAL_FILE_MAX_BYTES = 512 * 1024 * 1024;
const LOCAL_FILE_PREVIEW_SOURCE_MAX_BYTES = 32 * 1024 * 1024;
export const LOCAL_FILE_DRAFT_TTL_MS = 24 * 60 * 60 * 1_000;
export const LOCAL_FILE_BOUND_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
export const LOCAL_FILE_REGISTERED_TTL_MS =
  LOCAL_FILE_DRAFT_TTL_MS + LOCAL_FILE_BOUND_TTL_MS;
export const LOCAL_FILE_ORPHAN_GRACE_MS = 60 * 60 * 1_000;
export const LOCAL_FILE_CHUNK_BYTES = 256 * 1024;
const LOCAL_FILE_STARTUP_CLEANUP_RETRY_MS = 60_000;

const LOCAL_FILE_REF_PATTERN = /^lfi1_[A-Za-z0-9_-]{43}$/;
let temporarySequence = 0;

export type LocalFileSnapshot = Readonly<{
  localFileRef: string;
  mediaType: string;
  name: string;
  size: number;
}>;

export type BoundedLocalFileSource = Readonly<{
  bytes: Buffer;
  name: string;
  size: number;
}>;

type LocalFileIndexRecordBase = {
  created_at_ms: number;
  display_name: string;
  local_file_ref: string;
  media_type: string;
  object_id: string;
  sha256: string;
  size: number;
  state: "bound" | "draft" | "registered" | "revoked";
};

type LocalFileIndexRecordV1 = LocalFileIndexRecordBase & {
  version: 1;
};

type LocalFileIndexRecordV2 = LocalFileIndexRecordBase & {
  owner_user_id: string;
  version: 2;
};

type LocalFileIndexRecord = LocalFileIndexRecordV1 | LocalFileIndexRecordV2;

type SnapshotStoreOptions = {
  maxBytes?: number;
  now?: () => number;
  randomBytes?: (size: number) => Buffer;
  rootDir: string;
  startupCleanupFileOperations?: StartupCleanupFileOperations;
};

type CleanupDirectoryKind = "entries" | "objects" | "temporaries";
type StartupCleanupDirectoryKind = Exclude<CleanupDirectoryKind, "entries">;

type StartupCleanupFileOperations = Readonly<{
  lstat(path: string): Promise<Stats>;
  rm(path: string): Promise<void>;
}>;

type StartupCleanupRetryState = {
  restartPending: boolean;
  scanHadFailure: boolean;
};

type StartupCleanupWindow = {
  names: string[];
  scanComplete: boolean;
};

type StartupCleanupYield = (signal: AbortSignal) => Promise<void>;

export type LocalFileStartupCleanup = Readonly<{
  close(): Promise<void>;
}>;

/**
 * Electron Main's one-way local-file intake boundary.
 *
 * A host path admitted to Local-file import is consumed only by snapshot();
 * upload-class images use the separate bounded, non-indexing source reader
 * below. Returned values and persisted index records are ref-only; they carry
 * no host path, device, Connector run, or generation. V2 records privately
 * bind a stable owner for local preview admission, but public snapshot metadata
 * remains ownerless. A ref is never rebound. Connector remote reads open only
 * the managed object named by this record.
 * Modeled in tla/salix/LocalFileImport.tla.
 */
export class LocalFileSnapshotStore {
  readonly #activeCleanupOperations = new Set<Promise<void>>();
  readonly #cleanupDirectories = new Map<CleanupDirectoryKind, Dir>();
  readonly #cleanupScanLocks: Promise<void>[] = [];
  readonly #entriesDir: string;
  readonly #maxBytes: number;
  readonly #now: () => number;
  readonly #objectsDir: string;
  readonly #randomBytes: (size: number) => Buffer;
  readonly #recordLifecycleLocks = new Map<string, Promise<void>>();
  readonly #rootDir: string;
  readonly #startupCleanupKindLocks = new Map<
    StartupCleanupDirectoryKind,
    Promise<void>
  >();
  readonly #startupCleanupRetries = new Map<
    StartupCleanupDirectoryKind,
    StartupCleanupRetryState
  >();
  readonly #startupCleanupFileOperations: StartupCleanupFileOperations;
  readonly #tmpDir: string;
  #cleanupAdmissionSealed = false;
  #closePromise: Promise<void> | undefined;

  private constructor(options: SnapshotStoreOptions) {
    this.#rootDir = options.rootDir;
    this.#entriesDir = join(options.rootDir, "entries");
    this.#objectsDir = join(options.rootDir, "objects");
    this.#tmpDir = join(options.rootDir, "tmp");
    this.#maxBytes = options.maxBytes ?? LOCAL_FILE_MAX_BYTES;
    this.#now = options.now ?? Date.now;
    this.#randomBytes = options.randomBytes ?? randomBytes;
    this.#startupCleanupFileOperations = options.startupCleanupFileOperations ?? {
      lstat,
      rm,
    };
  }

  static async open(options: SnapshotStoreOptions) {
    const store = new LocalFileSnapshotStore(options);
    await store.#ensureManagedRoot();
    return store;
  }

  async snapshot(sourcePath: string, ownerUserId: string): Promise<LocalFileSnapshot> {
    if (!validOwnerUserId(ownerUserId)) {
      throw new LocalFileSnapshotError(
        "local_file_unavailable",
        "Local snapshot owner is unavailable."
      );
    }
    const ref = this.#newRef();
    const objectId = ref.slice("lfi1_".length);
    const attempt = `${process.pid}.${temporarySequence++}`;
    const temporaryObject = join(this.#tmpDir, `${objectId}.${attempt}.object.tmp`);
    const temporaryEntry = join(this.#tmpDir, `${objectId}.${attempt}.entry.tmp`);
    const objectPath = this.#objectPath(objectId);
    const entryPath = this.#entryPath(objectId);
    let source: FileHandle | undefined;
    let target: Awaited<ReturnType<typeof open>> | undefined;
    let objectCreated = false;
    let entryCreated = false;

    try {
      const verifiedSource = await openVerifiedLocalFileSource(
        sourcePath,
        this.#maxBytes
      );
      source = verifiedSource.source;
      const sourceStat = verifiedSource.stat;

      target = await open(
        temporaryObject,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
        0o600
      );
      const hash = createHash("sha256");
      const buffer = Buffer.allocUnsafe(
        Math.min(LOCAL_FILE_CHUNK_BYTES, this.#maxBytes + 1)
      );
      let offset = 0;

      while (true) {
        const { bytesRead } = await source.read(buffer, 0, buffer.length, offset);
        if (bytesRead === 0) break;
        offset += bytesRead;
        if (offset > this.#maxBytes) {
          throw new LocalFileSnapshotError(
            "local_file_too_large",
            "The selected file is too large."
          );
        }
        hash.update(buffer.subarray(0, bytesRead));
        await writeAll(target, buffer, bytesRead, offset - bytesRead);
      }

      const finalSourceStat = await source.stat({ bigint: true });
      if (!sameSourceSnapshot(sourceStat, finalSourceStat, offset)) {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "The selected file changed while it was being snapshotted."
        );
      }

      await target.sync();
      await target.close();
      target = undefined;
      // link(2) provides create-if-absent semantics. Unlike rename(2), it can
      // never overwrite an object that is already bound to a ref.
      await link(temporaryObject, objectPath);
      objectCreated = true;
      await rm(temporaryObject, { force: true });
      await syncDirectory(this.#objectsDir);

      const displayName = sanitizeLocalFileDisplayName(basename(sourcePath));
      const record: LocalFileIndexRecordV2 = {
        created_at_ms: this.#now(),
        display_name: displayName,
        local_file_ref: ref,
        media_type: mediaTypeForName(displayName),
        object_id: objectId,
        owner_user_id: ownerUserId,
        sha256: hash.digest("hex"),
        size: offset,
        state: "draft",
        version: LOCAL_FILE_INDEX_VERSION,
      };

      const entryHandle = await open(
        temporaryEntry,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
        0o600
      );
      try {
        await entryHandle.writeFile(JSON.stringify(record));
        await entryHandle.sync();
      } finally {
        await entryHandle.close();
      }
      await link(temporaryEntry, entryPath);
      entryCreated = true;
      await rm(temporaryEntry, { force: true });
      await syncDirectory(this.#entriesDir);

      return Object.freeze({
        localFileRef: ref,
        mediaType: record.media_type,
        name: displayName,
        size: offset,
      });
    } catch (error) {
      await Promise.all([
        rm(temporaryObject, { force: true }),
        rm(temporaryEntry, { force: true }),
      ]);
      // An object without a committed entry is an inert orphan. Only remove
      // files that this attempt actually created: collision failures must not
      // delete a pre-existing ref binding.
      if (entryCreated) await rm(entryPath, { force: true });
      if (objectCreated) await rm(objectPath, { force: true });
      throw normalizeSnapshotError(error);
    } finally {
      await source?.close();
      await target?.close();
    }
  }

  async releaseDraft(localFileRef: string) {
    return this.#withRecordLifecycleLock(localFileRef, async () => {
      const record = await this.#readRecord(localFileRef);
      if (record.state !== "draft") return false;
      await this.#removeManagedSnapshot(record);
      return true;
    });
  }

  /**
   * Persist the only allowed transition after the authenticated server has
   * accepted this ref's route. Resetting the local timestamp starts a bounded
   * eight-day ambiguity window; an unbound server route remains limited to 24
   * hours, so the extra local retention grants no read authority. The
   * ref/object identity and presentation metadata remain byte-for-byte fixed.
   */
  async markRegistered(localFileRef: string) {
    return this.#withRecordLifecycleLock(localFileRef, async () => {
      const record = await this.#readRecord(localFileRef);
      if (record.state === "registered" || record.state === "bound") return false;
      if (record.state !== "draft") {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "Local snapshot is unavailable."
        );
      }

      const object = await open(
        this.#objectPath(record.object_id),
        constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)
      ).catch(() => {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "Local snapshot is unavailable."
        );
      });
      try {
        const info = await object.stat();
        if (!info.isFile() || info.size !== record.size) {
          throw new LocalFileSnapshotError(
            "local_file_corrupt",
            "Local snapshot is corrupt."
          );
        }
      } finally {
        await object.close();
      }

      await this.#replaceRecord({
        ...record,
        created_at_ms: this.#now(),
        state: "registered",
      });
      return true;
    });
  }

  /**
   * Start the seven-day local retention window only after the canonical send
   * has succeeded or been reconciled. Message creation time is not the server
   * binding clock: an idempotent reservation can be retried before the route
   * binds. Main therefore starts from canonical observation time, capped at
   * the registration timestamp plus the server's 24-hour maximum bind window.
   * The resulting local deadline cannot precede the live server route or
   * extend past the existing eight-day registered ambiguity bound.
   */
  async markBound(localFileRef: string, _committedAtMs?: number) {
    return this.#withRecordLifecycleLock(localFileRef, async () => {
      const record = await this.#readRecord(localFileRef);
      if (record.state === "bound") return false;
      if (record.state !== "registered") {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "Local snapshot is unavailable."
        );
      }
      const now = this.#now();
      const retentionStartedAt = Math.min(
        now,
        record.created_at_ms + LOCAL_FILE_DRAFT_TTL_MS
      );
      await this.#replaceRecord({
        ...record,
        created_at_ms: retentionStartedAt,
        state: "bound",
      });
      return true;
    });
  }

  cleanupExpiredDrafts(options: { limit?: number; ttlMs?: number } = {}) {
    return this.#withCleanupAdmission(() => this.#cleanupExpiredDrafts(options));
  }

  async #cleanupExpiredDrafts({
    limit = 1_000,
    ttlMs = LOCAL_FILE_DRAFT_TTL_MS,
  }: {
    limit?: number;
    ttlMs?: number;
  } = {}) {
    const removalLimit = Math.max(0, Math.min(10_000, limit));
    const { names } = await this.#nextCleanupWindow(
      "entries",
      this.#entriesDir,
      removalLimit
    );
    let removed = 0;
    for (const name of names) {
      if (removed >= removalLimit) break;
      if (!/^[A-Za-z0-9_-]{43}\.json$/.test(name)) continue;
      try {
        const record = await this.#readRecord(`lfi1_${name.slice(0, -5)}`);
        if (record.state === "draft" && record.created_at_ms + ttlMs <= this.#now()) {
          if (await this.#removeExpiredSnapshot(record, ttlMs)) removed += 1;
        }
      } catch {
        // Corrupt entries are never interpreted into an object path. A future
        // bounded repair pass may quarantine them; intake stays fail closed.
      }
    }
    return removed;
  }

  /**
   * Bounded retention cleanup for local lifecycle states. Draft snapshots have
   * a 24-hour window, registered-but-unbound snapshots have an eight-day local
   * ambiguity window, and canonical-bound snapshots have seven-day retention. An
   * already-open descriptor may finish, but no later read can reopen an
   * unlinked object. The directory cursor bounds each pass while guaranteeing
   * stable records beyond one window are reached by later passes.
   */
  cleanupExpiredSnapshots(
    options: {
      boundTtlMs?: number;
      draftTtlMs?: number;
      limit?: number;
      registeredTtlMs?: number;
    } = {}
  ) {
    return this.#withCleanupAdmission(() => this.#cleanupExpiredSnapshots(options));
  }

  async #cleanupExpiredSnapshots({
    boundTtlMs = LOCAL_FILE_BOUND_TTL_MS,
    draftTtlMs = LOCAL_FILE_DRAFT_TTL_MS,
    limit = 1_000,
    registeredTtlMs = LOCAL_FILE_REGISTERED_TTL_MS,
  }: {
    boundTtlMs?: number;
    draftTtlMs?: number;
    limit?: number;
    registeredTtlMs?: number;
  } = {}) {
    const removalLimit = Math.max(0, Math.min(10_000, limit));
    const { names } = await this.#nextCleanupWindow(
      "entries",
      this.#entriesDir,
      removalLimit
    );
    let removed = 0;
    for (const name of names) {
      if (removed >= removalLimit) break;
      if (!/^[A-Za-z0-9_-]{43}\.json$/.test(name)) continue;
      try {
        const record = await this.#readRecord(`lfi1_${name.slice(0, -5)}`);
        const ttlMs =
          record.state === "draft"
            ? draftTtlMs
            : record.state === "registered"
              ? registeredTtlMs
              : record.state === "bound"
                ? boundTtlMs
                : undefined;
        if (ttlMs !== undefined && record.created_at_ms + ttlMs <= this.#now()) {
          if (await this.#removeExpiredSnapshot(record, ttlMs)) removed += 1;
        }
      } catch {
        // Never infer an object path from corrupt or unknown index data.
      }
    }
    return removed;
  }

  /**
   * Bounded startup repair for crash windows that occur before an index entry
   * commits. Only strict managed names older than the grace are eligible;
   * indexed objects and unknown files are never inferred or removed.
   */
  cleanupStartupArtifacts(
    options: {
      graceMs?: number;
      limit?: number;
      scanObjects?: boolean;
      scanTemporaries?: boolean;
    } = {}
  ) {
    return this.#withCleanupAdmission(() => this.#cleanupStartupArtifacts(options));
  }

  async #cleanupStartupArtifacts({
    graceMs = LOCAL_FILE_ORPHAN_GRACE_MS,
    limit = 1_000,
    scanObjects = true,
    scanTemporaries = true,
  }: {
    graceMs?: number;
    limit?: number;
    scanObjects?: boolean;
    scanTemporaries?: boolean;
  } = {}) {
    const boundedLimit = Math.max(0, Math.min(10_000, limit));
    const cutoff = this.#now() - Math.max(0, graceMs);
    const temporaries = scanTemporaries
      ? await this.#withStartupCleanupKindLock("temporaries", async () => {
          const window = await this.#nextStartupCleanupWindow(
            "temporaries",
            this.#tmpDir,
            boundedLimit
          );
          let removed = 0;
          let retryRequired = false;
          for (const name of window.names) {
            if (
              !/^[A-Za-z0-9_-]{43}\.[0-9]+\.[0-9]+\.(?:entry|object)\.tmp$/.test(name)
            ) {
              continue;
            }
            const outcome = await removeOldManagedFile(
              join(this.#tmpDir, name),
              cutoff,
              this.#startupCleanupFileOperations
            );
            if (outcome === "removed") {
              removed += 1;
            } else if (outcome === "retry") {
              retryRequired = true;
            }
          }
          const scanComplete = this.#settleStartupCleanupWindow(
            "temporaries",
            window,
            retryRequired
          );
          if (removed > 0) await syncDirectory(this.#tmpDir);
          return { removed, scanComplete };
        })
      : { removed: 0, scanComplete: true };

    const objects = scanObjects
      ? await this.#withStartupCleanupKindLock("objects", async () => {
          const window = await this.#nextStartupCleanupWindow(
            "objects",
            this.#objectsDir,
            boundedLimit
          );
          let removed = 0;
          let retryRequired = false;
          for (const objectId of window.names) {
            if (!/^[A-Za-z0-9_-]{43}$/.test(objectId)) continue;
            try {
              await this.#startupCleanupFileOperations.lstat(this.#entryPath(objectId));
              continue;
            } catch (error) {
              if ((error as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                retryRequired = true;
                continue;
              }
            }
            const outcome = await removeOldManagedFile(
              this.#objectPath(objectId),
              cutoff,
              this.#startupCleanupFileOperations
            );
            if (outcome === "removed") {
              removed += 1;
            } else if (outcome === "retry") {
              retryRequired = true;
            }
          }
          const scanComplete = this.#settleStartupCleanupWindow(
            "objects",
            window,
            retryRequired
          );
          if (removed > 0) await syncDirectory(this.#objectsDir);
          return { removed, scanComplete };
        })
      : { removed: 0, scanComplete: true };

    return {
      objectsRemoved: objects.removed,
      objectsScanComplete: objects.scanComplete,
      scanComplete: objects.scanComplete && temporaries.scanComplete,
      temporariesRemoved: temporaries.removed,
      temporariesScanComplete: temporaries.scanComplete,
    };
  }

  /**
   * Drain every startup-repair window without extending the startup critical
   * path. Each batch yields to Main's event loop; transient directory errors
   * remain scheduled and retry on a cancellable bounded backoff.
   */
  startStartupArtifactCleanup({
    limit = 1_000,
    retryAfterError = waitToRetryStartupCleanup,
    yieldBetweenBatches = yieldToEventLoop,
  }: {
    limit?: number;
    retryAfterError?: StartupCleanupYield;
    yieldBetweenBatches?: StartupCleanupYield;
  } = {}): LocalFileStartupCleanup {
    if (this.#cleanupAdmissionSealed) throw cleanupUnavailableDuringShutdown();
    const controller = new AbortController();
    const boundedLimit = Math.max(1, Math.min(10_000, limit));
    const completion = this.#drainStartupArtifacts({
      limit: boundedLimit,
      retryAfterError,
      signal: controller.signal,
      yieldBetweenBatches,
    }).catch(() => undefined);
    return Object.freeze({
      close: async () => {
        controller.abort();
        await completion;
      },
    });
  }

  close() {
    this.#cleanupAdmissionSealed = true;
    this.#closePromise ??= this.#finishClose();
    return this.#closePromise;
  }

  async #finishClose() {
    await Promise.all(this.#activeCleanupOperations);
    await this.#withStartupCleanupKindLock("temporaries", () =>
      this.#withStartupCleanupKindLock("objects", () =>
        this.#withCleanupScanLock(async () => {
          const directories = [...this.#cleanupDirectories.values()];
          this.#cleanupDirectories.clear();
          this.#startupCleanupRetries.clear();
          await Promise.all(
            directories.map((directory) => directory.close().catch(() => undefined))
          );
        })
      )
    );
  }

  /** Test/diagnostic helper that still resolves only a managed ref. */
  async readSnapshot(localFileRef: string) {
    const record = await this.#readRecord(localFileRef);
    return this.#readVerifiedSnapshot(record);
  }

  /** Main-only, owner-bound image source for the renderer preview capability. */
  async readPreviewSource(
    localFileRef: string,
    ownerUserId: string,
    signal?: AbortSignal
  ) {
    return this.#withRecordLifecycleLock(localFileRef, async () => {
      throwIfPreviewAborted(signal);
      const record = await this.#readRecord(localFileRef);
      if (
        record.version !== LOCAL_FILE_INDEX_VERSION ||
        !validOwnerUserId(ownerUserId) ||
        record.owner_user_id !== ownerUserId ||
        !previewLifecycleIsLive(record, this.#now())
      ) {
        throw previewUnavailable();
      }
      if (
        !["image/jpeg", "image/png"].includes(record.media_type) ||
        record.size > LOCAL_FILE_PREVIEW_SOURCE_MAX_BYTES
      ) {
        throw new LocalFileSnapshotError(
          "local_file_unsupported",
          "Local snapshot cannot be previewed."
        );
      }
      const bytes = await this.#readVerifiedPreviewSnapshot(record, signal);
      return Object.freeze({ bytes, mediaType: record.media_type });
    });
  }

  async #readVerifiedPreviewSnapshot(
    record: LocalFileIndexRecordV2,
    signal?: AbortSignal
  ) {
    throwIfPreviewAborted(signal);
    const object = await open(
      this.#objectPath(record.object_id),
      constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)
    ).catch(() => {
      throw previewUnavailable();
    });
    try {
      throwIfPreviewAborted(signal);
      const info = await object.stat();
      if (
        !info.isFile() ||
        info.size !== record.size ||
        info.size > LOCAL_FILE_PREVIEW_SOURCE_MAX_BYTES
      ) {
        throw new LocalFileSnapshotError(
          "local_file_corrupt",
          "Local snapshot is corrupt."
        );
      }

      const bytes = Buffer.allocUnsafe(record.size);
      const hash = createHash("sha256");
      let offset = 0;
      while (offset < record.size) {
        throwIfPreviewAborted(signal);
        const length = Math.min(LOCAL_FILE_CHUNK_BYTES, record.size - offset);
        const { bytesRead } = await object.read(bytes, offset, length, offset);
        if (bytesRead <= 0) {
          throw new LocalFileSnapshotError(
            "local_file_corrupt",
            "Local snapshot is corrupt."
          );
        }
        hash.update(bytes.subarray(offset, offset + bytesRead));
        offset += bytesRead;
      }
      throwIfPreviewAborted(signal);
      if (offset !== record.size || hash.digest("hex") !== record.sha256) {
        throw new LocalFileSnapshotError(
          "local_file_corrupt",
          "Local snapshot is corrupt."
        );
      }
      return bytes;
    } finally {
      await object.close();
    }
  }

  async #readVerifiedSnapshot(record: LocalFileIndexRecord) {
    const object = await open(
      this.#objectPath(record.object_id),
      constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)
    ).catch(() => {
      throw new LocalFileSnapshotError(
        "local_file_unavailable",
        "Local snapshot is unavailable."
      );
    });
    let bytes: Buffer;
    try {
      const info = await object.stat();
      if (!info.isFile() || info.size !== record.size) {
        throw new LocalFileSnapshotError(
          "local_file_corrupt",
          "Local snapshot is corrupt."
        );
      }
      bytes = await object.readFile();
    } finally {
      await object.close();
    }
    const actualHash = createHash("sha256").update(bytes).digest("hex");
    if (bytes.byteLength !== record.size || actualHash !== record.sha256) {
      throw new LocalFileSnapshotError(
        "local_file_corrupt",
        "Local snapshot is corrupt."
      );
    }
    return bytes;
  }

  async #ensureManagedRoot() {
    for (const directory of [
      this.#rootDir,
      this.#entriesDir,
      this.#objectsDir,
      this.#tmpDir,
    ]) {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const info = await lstat(directory);
      if (!info.isDirectory() || info.isSymbolicLink()) {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "Local snapshot storage is unavailable."
        );
      }
      await chmod(directory, 0o700);
    }
  }

  #newRef() {
    const token = this.#randomBytes(32).toString("base64url");
    const ref = `lfi1_${token}`;
    if (!LOCAL_FILE_REF_PATTERN.test(ref)) {
      throw new LocalFileSnapshotError(
        "local_file_unavailable",
        "Unable to allocate a local attachment reference."
      );
    }
    return ref;
  }

  async #readRecord(localFileRef: string): Promise<LocalFileIndexRecord> {
    if (!LOCAL_FILE_REF_PATTERN.test(localFileRef)) {
      throw new LocalFileSnapshotError(
        "invalid_local_file_ref",
        "Invalid local attachment."
      );
    }
    const objectId = localFileRef.slice("lfi1_".length);
    let parsed: unknown;
    try {
      const entry = await open(
        this.#entryPath(objectId),
        constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)
      );
      try {
        const info = await entry.stat();
        if (!info.isFile() || info.size <= 0 || info.size > 16 * 1024) {
          throw new LocalFileSnapshotError(
            "local_file_corrupt",
            "Local snapshot is corrupt."
          );
        }
        parsed = JSON.parse(await entry.readFile("utf8"));
      } finally {
        await entry.close();
      }
    } catch (error) {
      if (error instanceof LocalFileSnapshotError) throw error;
      if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        throw new LocalFileSnapshotError(
          "local_file_unavailable",
          "Local snapshot is unavailable."
        );
      }
      throw new LocalFileSnapshotError(
        "local_file_corrupt",
        "Local snapshot is corrupt."
      );
    }
    if (!validRecord(parsed, localFileRef, objectId)) {
      throw new LocalFileSnapshotError(
        "local_file_corrupt",
        "Local snapshot is corrupt."
      );
    }
    return parsed;
  }

  #entryPath(objectId: string) {
    return join(this.#entriesDir, `${requireObjectId(objectId)}.json`);
  }

  #objectPath(objectId: string) {
    return join(this.#objectsDir, requireObjectId(objectId));
  }

  async #removeManagedSnapshot(record: LocalFileIndexRecord) {
    await rm(this.#entryPath(record.object_id), { force: true });
    await rm(this.#objectPath(record.object_id), { force: true });
  }

  async #nextCleanupWindow(
    kind: CleanupDirectoryKind,
    directoryPath: string,
    limit: number
  ) {
    if (limit <= 0) return { names: [], scanComplete: false };
    return this.#withCleanupScanLock(async () => {
      let directory = this.#cleanupDirectories.get(kind);
      try {
        if (!directory) {
          directory = await opendir(directoryPath);
          this.#cleanupDirectories.set(kind, directory);
        }
        const names: string[] = [];
        let scanComplete = false;
        while (names.length < limit) {
          const entry = await directory.read();
          if (!entry) {
            this.#cleanupDirectories.delete(kind);
            await directory.close();
            scanComplete = true;
            break;
          }
          names.push(entry.name);
        }
        return { names, scanComplete };
      } catch (error) {
        if (directory && this.#cleanupDirectories.get(kind) === directory) {
          this.#cleanupDirectories.delete(kind);
        }
        await directory?.close().catch(() => undefined);
        throw error;
      }
    });
  }

  async #nextStartupCleanupWindow(
    kind: StartupCleanupDirectoryKind,
    directoryPath: string,
    limit: number
  ): Promise<StartupCleanupWindow> {
    const retryState = this.#startupCleanupRetries.get(kind);
    const window = await this.#nextCleanupWindow(kind, directoryPath, limit);
    if (limit > 0 && retryState?.restartPending) {
      retryState.restartPending = false;
    }
    return window;
  }

  #settleStartupCleanupWindow(
    kind: StartupCleanupDirectoryKind,
    window: StartupCleanupWindow,
    retryRequired: boolean
  ) {
    const retryState = this.#startupCleanupRetries.get(kind) ?? {
      restartPending: false,
      scanHadFailure: false,
    };
    retryState.scanHadFailure ||= retryRequired;
    if (!window.scanComplete) {
      if (retryState.scanHadFailure) this.#startupCleanupRetries.set(kind, retryState);
      return false;
    }
    if (retryState.scanHadFailure) {
      retryState.restartPending = true;
      retryState.scanHadFailure = false;
      this.#startupCleanupRetries.set(kind, retryState);
      return false;
    }
    this.#startupCleanupRetries.delete(kind);
    return true;
  }

  async #drainStartupArtifacts({
    limit,
    retryAfterError,
    signal,
    yieldBetweenBatches,
  }: {
    limit: number;
    retryAfterError: StartupCleanupYield;
    signal: AbortSignal;
    yieldBetweenBatches: StartupCleanupYield;
  }) {
    let scanObjects = true;
    let scanTemporaries = true;
    await yieldBetweenBatches(signal);
    while (
      !signal.aborted &&
      !this.#cleanupAdmissionSealed &&
      (scanObjects || scanTemporaries)
    ) {
      let result: Awaited<ReturnType<typeof this.cleanupStartupArtifacts>>;
      try {
        result = await this.cleanupStartupArtifacts({
          limit,
          scanObjects,
          scanTemporaries,
        });
      } catch {
        if (signal.aborted || this.#cleanupAdmissionSealed) return;
        await retryAfterError(signal);
        continue;
      }
      if (result.objectsScanComplete) scanObjects = false;
      if (result.temporariesScanComplete) scanTemporaries = false;
      if (
        signal.aborted ||
        this.#cleanupAdmissionSealed ||
        (!scanObjects && !scanTemporaries)
      ) {
        return;
      }
      if (
        (scanObjects && this.#startupCleanupRetryPending("objects")) ||
        (scanTemporaries && this.#startupCleanupRetryPending("temporaries"))
      ) {
        await retryAfterError(signal);
      } else {
        await yieldBetweenBatches(signal);
      }
    }
  }

  async #removeExpiredSnapshot(expected: LocalFileIndexRecord, ttlMs: number) {
    return this.#withRecordLifecycleLock(expected.local_file_ref, async () => {
      const current = await this.#readRecord(expected.local_file_ref);
      if (
        !sameLifecycleRecord(current, expected) ||
        current.created_at_ms + ttlMs > this.#now()
      ) {
        return false;
      }
      await this.#removeManagedSnapshot(current);
      return true;
    });
  }

  async #replaceRecord(record: LocalFileIndexRecord) {
    const attempt = `${process.pid}.${temporarySequence++}`;
    const temporaryEntry = join(
      this.#tmpDir,
      `${record.object_id}.${attempt}.entry.tmp`
    );
    const entry = await open(
      temporaryEntry,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
      0o600
    );
    try {
      await entry.writeFile(JSON.stringify(record));
      await entry.sync();
    } finally {
      await entry.close();
    }
    try {
      // Lifecycle transitions never change ref, object id, hash, size,
      // presentation metadata, or object bytes.
      await rename(temporaryEntry, this.#entryPath(record.object_id));
      await syncDirectory(this.#entriesDir);
    } finally {
      await rm(temporaryEntry, { force: true });
    }
  }

  async #withRecordLifecycleLock<T>(
    localFileRef: string,
    action: () => Promise<T>
  ): Promise<T> {
    const predecessor =
      this.#recordLifecycleLocks.get(localFileRef) ?? Promise.resolve();
    let release!: () => void;
    const turn = new Promise<void>((resolveTurn) => {
      release = resolveTurn;
    });
    const tail = predecessor.then(() => turn);
    this.#recordLifecycleLocks.set(localFileRef, tail);
    await predecessor;
    try {
      return await action();
    } finally {
      release();
      if (this.#recordLifecycleLocks.get(localFileRef) === tail) {
        this.#recordLifecycleLocks.delete(localFileRef);
      }
    }
  }

  #withCleanupAdmission<T>(action: () => Promise<T>): Promise<T> {
    if (this.#cleanupAdmissionSealed) {
      return Promise.reject(cleanupUnavailableDuringShutdown());
    }
    let finish!: () => void;
    const completion = new Promise<void>((resolveCompletion) => {
      finish = resolveCompletion;
    });
    this.#activeCleanupOperations.add(completion);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      this.#activeCleanupOperations.delete(completion);
      finish();
    };
    try {
      return action().finally(release);
    } catch (error) {
      release();
      return Promise.reject(error);
    }
  }

  async #withCleanupScanLock<T>(action: () => Promise<T>): Promise<T> {
    const predecessor = this.#cleanupScanLocks.at(-1) ?? Promise.resolve();
    let release!: () => void;
    const turn = new Promise<void>((resolveTurn) => {
      release = resolveTurn;
    });
    this.#cleanupScanLocks.push(turn);
    await predecessor;
    try {
      return await action();
    } finally {
      release();
      this.#cleanupScanLocks.shift();
    }
  }

  #startupCleanupRetryPending(kind: StartupCleanupDirectoryKind) {
    return this.#startupCleanupRetries.get(kind)?.restartPending === true;
  }

  async #withStartupCleanupKindLock<T>(
    kind: StartupCleanupDirectoryKind,
    action: () => Promise<T>
  ): Promise<T> {
    const predecessor = this.#startupCleanupKindLocks.get(kind) ?? Promise.resolve();
    let release!: () => void;
    const turn = new Promise<void>((resolveTurn) => {
      release = resolveTurn;
    });
    const tail = predecessor.then(() => turn);
    this.#startupCleanupKindLocks.set(kind, tail);
    await predecessor;
    try {
      return await action();
    } finally {
      release();
      if (this.#startupCleanupKindLocks.get(kind) === tail) {
        this.#startupCleanupKindLocks.delete(kind);
      }
    }
  }
}

export class LocalFileSnapshotError extends Error {
  constructor(
    readonly errorClass:
      | "invalid_local_file_ref"
      | "local_file_corrupt"
      | "local_file_too_large"
      | "local_file_unavailable"
      | "local_file_unsupported",
    message: string
  ) {
    super(message);
    this.name = "LocalFileSnapshotError";
  }
}

function cleanupUnavailableDuringShutdown() {
  return new LocalFileSnapshotError(
    "local_file_unavailable",
    "Local snapshot cleanup is unavailable during shutdown."
  );
}

function requireObjectId(value: string) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new LocalFileSnapshotError(
      "local_file_corrupt",
      "Local snapshot is corrupt."
    );
  }
  return value;
}

function validRecord(
  value: unknown,
  ref: string,
  objectId: string
): value is LocalFileIndexRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Partial<LocalFileIndexRecord> & Record<string, unknown>;
  if (
    record.local_file_ref === ref &&
    record.object_id === objectId &&
    Number.isSafeInteger(record.created_at_ms) &&
    (record.created_at_ms ?? 0) > 0 &&
    typeof record.display_name === "string" &&
    record.display_name.length > 0 &&
    Buffer.byteLength(record.display_name, "utf8") <= 255 &&
    !containsForbiddenDisplayNameCharacter(record.display_name) &&
    typeof record.media_type === "string" &&
    record.media_type.length > 0 &&
    Buffer.byteLength(record.media_type, "utf8") <= 255 &&
    typeof record.size === "number" &&
    Number.isSafeInteger(record.size) &&
    record.size >= 0 &&
    record.size <= LOCAL_FILE_MAX_BYTES &&
    typeof record.sha256 === "string" &&
    /^[a-f0-9]{64}$/.test(record.sha256) &&
    ["bound", "draft", "registered", "revoked"].includes(record.state ?? "")
  ) {
    if (record.version === 1) {
      return hasExactKeys(record, LOCAL_FILE_INDEX_V1_KEYS);
    }
    if (record.version === LOCAL_FILE_INDEX_VERSION) {
      return (
        hasExactKeys(record, LOCAL_FILE_INDEX_V2_KEYS) &&
        validOwnerUserId(record.owner_user_id)
      );
    }
  }
  return false;
}

function sameLifecycleRecord(
  current: LocalFileIndexRecord,
  expected: LocalFileIndexRecord
) {
  return (
    sameRecordOwnerAndVersion(current, expected) &&
    current.local_file_ref === expected.local_file_ref &&
    current.object_id === expected.object_id &&
    current.sha256 === expected.sha256 &&
    current.size === expected.size &&
    current.state === expected.state &&
    current.created_at_ms === expected.created_at_ms
  );
}

const LOCAL_FILE_INDEX_V1_KEYS = Object.freeze([
  "created_at_ms",
  "display_name",
  "local_file_ref",
  "media_type",
  "object_id",
  "sha256",
  "size",
  "state",
  "version",
]);

const LOCAL_FILE_INDEX_V2_KEYS = Object.freeze([
  ...LOCAL_FILE_INDEX_V1_KEYS,
  "owner_user_id",
]);

function hasExactKeys(
  record: Record<string, unknown>,
  expectedKeys: readonly string[]
) {
  const keys = Object.keys(record);
  return (
    keys.length === expectedKeys.length &&
    keys.every((key) => expectedKeys.includes(key))
  );
}

function validOwnerUserId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    Buffer.byteLength(value, "utf8") <= 160 &&
    !["\0", "\r", "\n"].some((character) => value.includes(character))
  );
}

function sameRecordOwnerAndVersion(
  current: LocalFileIndexRecord,
  expected: LocalFileIndexRecord
) {
  if (current.version !== expected.version) return false;
  if (current.version === LOCAL_FILE_INDEX_VERSION) {
    return (
      expected.version === LOCAL_FILE_INDEX_VERSION &&
      current.owner_user_id === expected.owner_user_id
    );
  }
  return expected.version === 1;
}

function previewLifecycleIsLive(record: LocalFileIndexRecordV2, now: number) {
  const ttlMs =
    record.state === "draft"
      ? LOCAL_FILE_DRAFT_TTL_MS
      : record.state === "registered"
        ? LOCAL_FILE_REGISTERED_TTL_MS
        : record.state === "bound"
          ? LOCAL_FILE_BOUND_TTL_MS
          : undefined;
  return ttlMs !== undefined && record.created_at_ms > now - ttlMs;
}

function throwIfPreviewAborted(signal: AbortSignal | undefined) {
  if (signal?.aborted) throw previewUnavailable();
}

function previewUnavailable() {
  return new LocalFileSnapshotError(
    "local_file_unavailable",
    "Local snapshot is unavailable."
  );
}

function containsForbiddenDisplayNameCharacter(value: string) {
  return ["\u0000", "\r", "\n", "/", "\\"].some((character) =>
    value.includes(character)
  );
}

export function sanitizeLocalFileDisplayName(value: string) {
  const sanitized = ["\u0000", "\r", "\n", "/", "\\"]
    .reduce((result, character) => result.replaceAll(character, ""), value)
    .trim();
  if (!sanitized) return "Local file";
  // NTFS names may carry unpaired surrogates, which strict RFC-8259 JSON
  // decoders downstream reject; substitute U+FFFD at the same 3-byte UTF-8
  // cost. Equivalent to String#toWellFormed, which the pinned ES2023 lib
  // does not yet expose.
  const wellFormed = sanitized.replace(
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g,
    "�"
  );
  let bytes = 0;
  let truncated = "";
  for (const codePoint of wellFormed) {
    const codePointBytes = Buffer.byteLength(codePoint, "utf8");
    if (bytes + codePointBytes > 255) break;
    truncated += codePoint;
    bytes += codePointBytes;
  }
  return truncated || "Local file";
}

function mediaTypeForName(name: string) {
  switch (extname(name).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".pdf":
      return "application/pdf";
    case ".json":
      return "application/json";
    case ".txt":
    case ".md":
      return "text/plain";
    case ".wav":
      return "audio/wav";
    case ".m4a":
      return "audio/mp4";
    default:
      return "application/octet-stream";
  }
}

/**
 * Main-only bounded source intake for upload-class attachments. The host path
 * is consumed here and never becomes an LFI ref, managed object, or index row.
 * The size preflight and bounded read use the same O_NOFOLLOW descriptor, with
 * at most maxBytes + 1 bytes read before an oversize rejection.
 */
export async function readBoundedLocalFileSource(
  sourcePath: string,
  maxBytes: number
): Promise<BoundedLocalFileSource> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new LocalFileSnapshotError(
      "local_file_unavailable",
      "The selected file is unavailable."
    );
  }

  let source: FileHandle | undefined;
  try {
    const verifiedSource = await openVerifiedLocalFileSource(sourcePath, maxBytes);
    source = verifiedSource.source;
    const chunks: Buffer[] = [];
    let offset = 0;

    while (offset <= maxBytes) {
      const readLength = Math.min(LOCAL_FILE_CHUNK_BYTES, maxBytes + 1 - offset);
      const chunk = Buffer.allocUnsafe(readLength);
      const { bytesRead } = await source.read(chunk, 0, readLength, offset);
      if (bytesRead === 0) break;
      chunks.push(
        bytesRead === chunk.byteLength ? chunk : chunk.subarray(0, bytesRead)
      );
      offset += bytesRead;
    }

    if (offset > maxBytes) {
      throw new LocalFileSnapshotError(
        "local_file_too_large",
        "The selected file is too large."
      );
    }

    const finalSourceStat = await source.stat({ bigint: true });
    if (!sameSourceSnapshot(verifiedSource.stat, finalSourceStat, offset)) {
      throw new LocalFileSnapshotError(
        "local_file_unavailable",
        "The selected file changed while it was being read."
      );
    }

    return Object.freeze({
      bytes: Buffer.concat(chunks, offset),
      name: sanitizeLocalFileDisplayName(basename(sourcePath)),
      size: offset,
    });
  } catch (error) {
    throw normalizeSnapshotError(error);
  } finally {
    await source?.close();
  }
}

async function openVerifiedLocalFileSource(
  sourcePath: string,
  maxBytes: number
): Promise<{ source: FileHandle; stat: BigIntStats }> {
  requireLocalFileSourcePath(sourcePath);
  await rejectSymlinkAncestors(sourcePath);

  let selectedIdentity: BigIntStats;
  try {
    selectedIdentity = await lstat(sourcePath, { bigint: true });
  } catch {
    throw new LocalFileSnapshotError(
      "local_file_unavailable",
      "The selected file is unavailable."
    );
  }
  if (!selectedIdentity.isFile() || selectedIdentity.isSymbolicLink()) {
    throw new LocalFileSnapshotError(
      "local_file_unsupported",
      "Only regular files are supported."
    );
  }
  if (selectedIdentity.size > BigInt(maxBytes)) {
    throw new LocalFileSnapshotError(
      "local_file_too_large",
      "The selected file is too large."
    );
  }

  let source: FileHandle | undefined;
  try {
    source = await open(sourcePath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const sourceStat = await source.stat({ bigint: true });
    if (
      !sourceStat.isFile() ||
      sourceStat.dev !== selectedIdentity.dev ||
      sourceStat.ino !== selectedIdentity.ino
    ) {
      throw new LocalFileSnapshotError(
        "local_file_unsupported",
        "Only regular files are supported."
      );
    }
    if (sourceStat.size > BigInt(maxBytes)) {
      throw new LocalFileSnapshotError(
        "local_file_too_large",
        "The selected file is too large."
      );
    }
    return { source, stat: sourceStat };
  } catch (error) {
    await source?.close();
    throw error;
  }
}

function requireLocalFileSourcePath(sourcePath: string) {
  if (
    typeof sourcePath !== "string" ||
    sourcePath.length === 0 ||
    sourcePath.length > 32_768 ||
    !isAbsolute(sourcePath) ||
    sourcePath.includes("\0") ||
    sourcePath.includes("\r") ||
    sourcePath.includes("\n")
  ) {
    throw new LocalFileSnapshotError("invalid_local_file_ref", "A file is required.");
  }
}

async function syncDirectory(path: string) {
  const handle = await open(path, constants.O_RDONLY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function writeAll(
  target: Awaited<ReturnType<typeof open>>,
  buffer: Buffer,
  length: number,
  position: number
) {
  let written = 0;
  while (written < length) {
    const result = await target.write(
      buffer,
      written,
      length - written,
      position + written
    );
    if (result.bytesWritten <= 0) {
      throw new Error("Snapshot write made no progress.");
    }
    written += result.bytesWritten;
  }
}

function yieldToEventLoop(signal: AbortSignal) {
  if (signal.aborted) return Promise.resolve();
  return new Promise<void>((resolveYield) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      resolveYield();
    };
    const immediate = setImmediate(finish);
    const onAbort = () => {
      clearImmediate(immediate);
      finish();
    };
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) onAbort();
  });
}

function waitToRetryStartupCleanup(signal: AbortSignal) {
  if (signal.aborted) return Promise.resolve();
  return new Promise<void>((resolveWait) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      signal.removeEventListener("abort", finish);
      resolveWait();
    };
    const timeout = setTimeout(finish, LOCAL_FILE_STARTUP_CLEANUP_RETRY_MS);
    timeout.unref();
    signal.addEventListener("abort", finish, { once: true });
    if (signal.aborted) finish();
  });
}

function sameSourceSnapshot(
  before: BigIntStats,
  after: BigIntStats,
  bytesRead: number
) {
  return (
    after.isFile() &&
    before.dev === after.dev &&
    before.ino === after.ino &&
    before.mode === after.mode &&
    before.size === after.size &&
    before.size === BigInt(bytesRead) &&
    before.mtimeNs === after.mtimeNs &&
    before.ctimeNs === after.ctimeNs
  );
}

async function removeOldManagedFile(
  path: string,
  cutoffMs: number,
  fileOperations: StartupCleanupFileOperations
) {
  try {
    const info = await fileOperations.lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.mtimeMs > cutoffMs)
      return "settled" as const;
    await fileOperations.rm(path);
    return "removed" as const;
  } catch (error) {
    return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT"
      ? ("settled" as const)
      : ("retry" as const);
  }
}

async function rejectSymlinkAncestors(sourcePath: string) {
  const absolute = resolve(sourcePath);
  const root = parse(absolute).root;
  const components: string[] = [];
  let current = dirname(absolute);
  while (current !== root) {
    components.push(current);
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  components.push(root);

  for (const directory of components.toReversed()) {
    let info: Awaited<ReturnType<typeof lstat>>;
    try {
      info = await lstat(directory);
    } catch {
      throw new LocalFileSnapshotError(
        "local_file_unavailable",
        "The selected file is unavailable."
      );
    }
    if (!info.isDirectory() || info.isSymbolicLink()) {
      throw new LocalFileSnapshotError(
        "local_file_unsupported",
        "Symbolic links are not supported."
      );
    }
  }
}

function normalizeSnapshotError(error: unknown) {
  if (error instanceof LocalFileSnapshotError) return error;
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  if (code === "ELOOP") {
    return new LocalFileSnapshotError(
      "local_file_unsupported",
      "Symbolic links are not supported."
    );
  }
  return new LocalFileSnapshotError(
    "local_file_unavailable",
    "The selected file could not be snapshotted."
  );
}
