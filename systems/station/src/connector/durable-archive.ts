// A Workload's durable archive. Out, over the connection: Salix asks a parked station to export its root as a zstd tar
// straight into object storage (`archive_export`, through the signed part URLs Salix gives), follows it
// (`archive_status`) and may cancel it (`archive_cancel`). Back, before any station runs: the start of a Workload's
// Container names the archive its disk is (`SALIX_RESTORE_ARCHIVE`: one signed URL, of the manifest of its parts), and the
// image unpacks it onto the empty disk before it starts the station (`restoreBeforeStart`), so a station only ever
// starts on its own disk. The station's own databases are not copied live: the export carries consistent snapshots in
// their places, and a restore puts them there. The station's runtime state (ops/files.ts `runtimeDir`: what is true of
// one run on one boot of one machine) is no part of the disk's archive: an export leaves it out, and a restore drops
// it from an archive made before exports did. Export state and the restore's receipt are kept on disk: a lost reply
// or a restart answers the same operation again, and `archive_status` says which archive the disk was restored from.
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, sep } from "node:path";
import { Readable, Writable } from "node:stream";
import { setTimeout as wait } from "node:timers/promises";
import { Effect, Exit } from "effect";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type ArchiveHooks, MIGRATION_BYTE_LIMIT, restoreTar, writeTarTrees } from "./archive.ts";

export const ARCHIVE_PART_BYTES = 4 * 1024 * 1024;
export const ARCHIVE_MAX_PARTS = 1024;
export const ARCHIVE_COMPRESSED_LIMIT = 4 * 1024 * 1024 * 1024;
const TRANSFER_CONCURRENCY = 8;
const OPERATION = /^[a-zA-Z0-9_-]{1,128}$/;

export type SignedTransfer = { put_url: string; get_url: string };
export type SignedPart = { get_url: string; bytes: number };

/** The station's own state in an archive: files never copied live, and their consistent snapshots. */
export type ArchiveState = {
  /** Absolute paths of live files (databases and their journals) the export leaves out. */
  live(): string[];
  /** Absolute paths of the station's runtime state: the export leaves them out, with all that is under them. */
  runtime(): string[];
  /** Snapshots to add, by their path relative to the root; made now, removed by the caller's `done`. */
  snapshots(): Promise<{ entries: Array<{ name: string; file: string }>; done(): void }>;
  /** How many sessions the station holds (reported with an export). */
  sessions(): number;
};

export type ArchiveOptions = {
  root: string;
  dir: string;
  state: ArchiveState;
  /** Whether a URL is a signed object storage URL this station may use. */
  allowedUrl(url: string): boolean;
  /** Whether the station is parked (export needs it). */
  parked(): boolean;
  fork(effect: Effect.Effect<void>): void;
  nowMs(): number;
  /** Waits `ms` on the connector's clock (a part's retry backoff); rejects when `signal` aborts. */
  sleep(ms: number, signal: AbortSignal): Promise<void>;
};

type ExportState = {
  operation: string;
  phase: "preparing" | "exported" | "failed" | "cancelled";
  scope: string;
  format: "tar_zst";
  bytes: number;
  packed_bytes: number;
  uploaded_bytes: number;
  sessions: number;
  started_at: number;
  progress_at: number;
  /** Why a failed export failed, for Salix's log. */
  error?: string;
};

/**
 * How long a restore took: milliseconds from its start to when the manifest was read, the first part arrived, the last
 * part arrived, every entry was in place, the root was synced, and the receipt was written.
 */
export type RestoreTimings = { manifest_ms: number; first_byte_ms: number; downloaded_ms: number; written_ms: number; synced_ms: number; total_ms: number };

/** The restore's receipt. A restored one says what was put in place and how long it took (read by Salix's log only). */
type ImportState = { operation: string; phase: "restoring" | "restored" | "failed"; bytes: number; error?: string; entries?: number; files?: number; timings?: RestoreTimings };

/** Signed URLs Salix gives: object storage over https, with a signature and nothing else. */
export function signedStorageUrl(hostSuffix = ".r2.cloudflarestorage.com") {
  return (raw: string) => {
    try {
      const url = new URL(raw);
      // Tests name a local store: plain http on 127.0.0.1, any port.
      if (hostSuffix === "127.0.0.1") return url.protocol === "http:" && url.hostname === "127.0.0.1" && url.search.length > 1;
      return url.protocol === "https:" && !url.username && !url.password && !url.hash && !url.port && url.hostname.endsWith(hostSuffix) && url.search.length > 1;
    } catch {
      return false;
    }
  };
}

const failure = (message: string) => new Error(message);
const under = (path: string, dir: string) => path === dir || path.startsWith(`${dir}/`);

/** `path` as an archive of `root` names it (relative, with `/`), or null when it is not under the root. */
export function archiveName(root: string, path: string): string | null {
  const rel = relative(root, path);
  return rel && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel) ? rel.split(sep).join("/") : null;
}
const read = <T>(path: string): T | null => {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
  }
};
const save = (path: string, value: unknown) => {
  writeFileSync(`${path}.tmp`, JSON.stringify(value), { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
};

const PART_ATTEMPTS = 5;
/** Waits on the connector's clock; rejects when `signal` aborts. */
type Sleep = (ms: number, signal: AbortSignal) => Promise<void>;
const backoff = (sleep: Sleep, attempt: number, signal: AbortSignal) => sleep(250 * 2 ** attempt, signal);

/**
 * PUTs a part with If-None-Match. A 412, 429, 5xx, timeout or network error is settled by reading the part back:
 * the same bytes are done, different bytes conflict, a missing part is PUT again after a backoff.
 */
async function putPart(transfer: SignedTransfer, part: Buffer, signal: AbortSignal, sleep: Sleep): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(transfer.put_url, { method: "PUT", body: new Uint8Array(part), headers: { "if-none-match": "*" }, redirect: "manual", signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]) });
      await response.body?.cancel();
      if (response.ok) return;
      if (response.status !== 412 && response.status !== 429 && response.status < 500) throw failure("signed archive upload rejected");
    } catch (error) {
      if (signal.aborted) throw error;
      if ((error as Error).message === "signed archive upload rejected") throw error;
    }
    const existing = await getPart(transfer.get_url, part.length, signal, sleep, true);
    if (existing) {
      if (!existing.equals(part)) throw failure("signed archive part conflict");
      return;
    }
    if (attempt + 1 >= PART_ATTEMPTS) throw failure("signed archive upload failed");
    await backoff(sleep, attempt, signal);
  }
}

/** A part's bytes, retrying 429, 5xx and network errors; with `missingOk`, null when the part is not there. */
async function getPart(url: string, expected: number, signal: AbortSignal, sleep: Sleep): Promise<Buffer>;
async function getPart(url: string, expected: number, signal: AbortSignal, sleep: Sleep, missingOk: true): Promise<Buffer | null>;
async function getPart(url: string, expected: number, signal: AbortSignal, sleep: Sleep, missingOk = false): Promise<Buffer | null> {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(url, { redirect: "manual", signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]) });
      if (response.status === 200) {
        const body = Buffer.from(await response.arrayBuffer());
        if (body.length !== expected) throw failure("signed archive part size mismatch");
        return body;
      }
      await response.body?.cancel();
      if (missingOk && response.status === 404) return null;
      if (attempt + 1 >= PART_ATTEMPTS || (response.status !== 429 && response.status < 500)) throw failure("signed archive read failed");
    } catch (error) {
      if (signal.aborted || attempt + 1 >= PART_ATTEMPTS || /^signed archive (part size mismatch|read failed)$/.test((error as Error).message)) throw error;
    }
    await backoff(sleep, attempt, signal);
  }
}

/** The compressed stream, cut into 4 MiB parts uploaded in order of their URLs, at most eight at once. */
function uploadWriter(transfers: SignedTransfer[], signal: AbortSignal, sleep: Sleep) {
  let buffer: Buffer[] = [];
  let buffered = 0;
  let index = 0;
  let uploaded = 0;
  let written = 0;
  const inflight = new Set<Promise<void>>();
  let failed: Error | null = null;
  const dispatch = async (part: Buffer) => {
    if (index >= transfers.length) throw failure("archive exceeds signed upload part count");
    while (inflight.size >= TRANSFER_CONCURRENCY) await Promise.race(inflight);
    if (failed) throw failed;
    const transfer = transfers[index++];
    const task: Promise<void> = putPart(transfer, part, signal, sleep).then(
      () => void (uploaded += part.length),
      (error: Error) => void (failed ??= error),
    );
    const tracked = task.finally(() => inflight.delete(tracked));
    inflight.add(tracked);
  };
  const stream = new Writable({
    write(chunk: Buffer, _encoding, done) {
      written += chunk.length;
      if (written > ARCHIVE_COMPRESSED_LIMIT) return done(failure("archive exceeds compressed size limit"));
      buffer.push(chunk);
      buffered += chunk.length;
      (async () => {
        while (buffered >= ARCHIVE_PART_BYTES) {
          const all = Buffer.concat(buffer);
          buffer = [all.subarray(ARCHIVE_PART_BYTES)];
          buffered = all.length - ARCHIVE_PART_BYTES;
          await dispatch(Buffer.from(all.subarray(0, ARCHIVE_PART_BYTES)));
        }
      })().then(() => done(failed ?? undefined), (error) => done(error));
    },
    final(done) {
      (async () => {
        if (buffered > 0) await dispatch(Buffer.concat(buffer));
        buffer = [];
        buffered = 0;
        await Promise.all(inflight);
        if (failed) throw failed;
        if (uploaded !== written) throw failure("archive upload incomplete");
      })().then(() => done(), (error) => done(error));
    },
  });
  return { stream, progress: () => ({ written, uploaded }) };
}

/** The archive read back from its parts, in order, fetching up to eight ahead; `arrived(n)` as the nth part arrives. */
function partsReader(parts: SignedPart[], signal: AbortSignal, sleep: Sleep, arrived: (count: number) => void = () => {}): Readable {
  let next = 0;
  let count = 0;
  const ahead: Array<Promise<Buffer>> = [];
  const fill = () => {
    while (ahead.length < TRANSFER_CONCURRENCY && next < parts.length) {
      const part = parts[next++];
      const fetching = getPart(part.get_url, part.bytes, signal, sleep);
      fetching.then(() => arrived(++count), () => {});
      ahead.push(fetching);
    }
  };
  return new Readable({
    read() {
      fill();
      const head = ahead.shift();
      if (!head) return void this.push(null);
      head.then(
        (body) => {
          fill();
          this.push(body);
        },
        (error) => this.destroy(error),
      );
    },
  });
}

export function makeDurableArchive(options: ArchiveOptions) {
  mkdirSync(options.dir, { recursive: true, mode: 0o700 });
  const ownDir = realpathSync(options.dir);
  const canonical = (path: string) => {
    try {
      return realpathSync(path);
    } catch {
      return path;
    }
  };
  const exportPath = join(options.dir, "export.json");
  const importPath = join(options.dir, "import.json");
  let running: { operation: string; abort: AbortController; progress: () => { written: number; uploaded: number } } | null = null;

  const response = (state: ExportState) => {
    if (running?.operation === state.operation && state.phase === "preparing") {
      const progress = running.progress();
      return { ...state, packed_bytes: progress.written, uploaded_bytes: progress.uploaded };
    }
    return state;
  };

  const exportArchive = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.suspend((): Effect.Effect<Record<string, unknown>, Error> => {
      const operation = String(params.operation ?? "");
      if (!OPERATION.test(operation)) return Effect.fail(failure("invalid archive operation"));
      const scope = params.scope === undefined ? "full" : String(params.scope);
      if (scope !== "full") return Effect.fail(failure("invalid archive scope"));
      const previous = read<ExportState>(exportPath);
      if (previous?.operation === operation && (previous.phase === "preparing" || previous.phase === "exported")) return Effect.succeed(response(previous));
      if (previous?.phase === "preparing" && running) return Effect.fail(failure("another archive export is in progress"));
      if (!options.parked()) return Effect.fail(failure("managed archive requires quiescence"));
      const transfers = params.transfers;
      if (!Array.isArray(transfers) || transfers.length === 0 || transfers.length > ARCHIVE_MAX_PARTS) return Effect.fail(failure("invalid archive transfer list"));
      for (const transfer of transfers as SignedTransfer[]) {
        if (!options.allowedUrl(String(transfer?.put_url)) || !options.allowedUrl(String(transfer?.get_url))) return Effect.fail(failure("invalid signed archive upload URL"));
        const put = new URL(transfer.put_url);
        const get = new URL(transfer.get_url);
        if (put.host !== get.host || put.pathname !== get.pathname) return Effect.fail(failure("archive transfer targets differ"));
      }
      const now = options.nowMs();
      const state: ExportState = { operation, phase: "preparing", scope, format: "tar_zst", bytes: 0, packed_bytes: 0, uploaded_bytes: 0, sessions: options.state.sessions(), started_at: now, progress_at: now };
      save(exportPath, state);
      const abort = new AbortController();
      const upload = uploadWriter(transfers as SignedTransfer[], abort.signal, options.sleep);
      running = { operation, abort, progress: upload.progress };
      options.fork(
        Effect.gen(function* () {
          const snapshots = yield* Effect.tryPromise({ try: () => options.state.snapshots(), catch: (e) => e as Error });
          const live = new Set(options.state.live().map(canonical));
          const runtime = options.state.runtime().map(canonical);
          const hooks: ArchiveHooks = {
            exclude: (path) => live.has(path) || under(path, ownDir) || runtime.some((dir) => under(path, dir)),
            trailing: () => Effect.succeed(snapshots.entries),
            // The Workload's disk is all that is archived: a link out of it (into the image, say) leads nowhere after a
            // restore on another machine, and is not the station's data.
            outsideLink: (rel) => log.info("durable_archive", "a link out of the archived root is left out", { path: rel }),
          };
          const written = yield* Effect.exit(writeTarTrees(upload.stream, [{ source: options.root, prefix: "." }], { codec: "zstd", fileLimit: MIGRATION_BYTE_LIMIT, hooks, signal: abort.signal }));
          snapshots.done();
          const progress = upload.progress();
          const error = Exit.isFailure(written) ? String(written.cause) : progress.written === 0 ? "archive is empty" : progress.uploaded !== progress.written ? "archive upload incomplete" : undefined;
          const phase = abort.signal.aborted ? "cancelled" : error === undefined ? "exported" : "failed";
          save(exportPath, { ...state, phase, bytes: progress.written, packed_bytes: progress.written, uploaded_bytes: progress.uploaded, progress_at: options.nowMs(), ...(phase === "failed" ? { error: error?.slice(0, 500) } : {}) });
        }).pipe(
          Effect.catch((error) => Effect.sync(() => save(exportPath, { ...state, phase: "failed", progress_at: options.nowMs(), error: String(error).slice(0, 500) }))),
          Effect.ensuring(Effect.sync(() => (running = null))),
        ),
      );
      return Effect.succeed({ operation, phase: "preparing" });
    });

  const status = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.suspend((): Effect.Effect<Record<string, unknown>, Error> => {
      const operation = String(params.operation ?? "");
      const imported = read<ImportState>(importPath);
      if (params.kind === "import") return imported?.operation === operation ? Effect.succeed(imported) : Effect.fail(failure("archive import unavailable"));
      const state = read<ExportState>(exportPath);
      if (state?.operation !== operation) return Effect.fail(failure("archive export unavailable"));
      // A station restarted mid-export has no export running: that one failed.
      if (state.phase === "preparing" && running?.operation !== operation) return Effect.succeed({ ...state, phase: "failed", error: "station restarted during the export" });
      return Effect.succeed(response(state));
    });

  const cancel = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.sync(() => {
      const operation = String(params.operation ?? "");
      if (running?.operation === operation) running.abort.abort();
      const state = read<ExportState>(exportPath);
      if (state?.operation === operation && state.phase === "exported") return { operation, phase: "exported" };
      if (state?.operation === operation && running === null) save(exportPath, { ...state, phase: "cancelled", progress_at: options.nowMs() });
      return { operation, phase: running?.operation === operation ? "cancelling" : "cancelled" };
    });

  return { exportArchive, status, cancel, close: () => running?.abort.abort() };
}

export type DurableArchive = ReturnType<typeof makeDurableArchive>;

/** Where the archive state of a station whose state root is `stateRoot` is kept: `export.json`, and the restore's receipt `import.json`. */
export const archiveStateDir = (stateRoot: string) => join(stateRoot, "durable-archive");

/** The most a start's restore may be, as its environment carries it: it is the same small size for every archive. */
export const RESTORE_VALUE_LIMIT = 8 * 1024;
/** The most an archive's manifest may be: every part's signed URL, of the most parts. */
const MANIFEST_LIMIT = 2 * 1024 * 1024;

export type Restore = { operation: string; bytes: number; manifest_url: string };

/**
 * What a Container's start names to restore (`SALIX_RESTORE_ARCHIVE`): base64 of the JSON `{operation, bytes,
 * manifest_url}`. The manifest is an object next to the archive's parts, read through that one signed URL.
 */
export function decodeRestore(value: string, allowedUrl: (url: string) => boolean): Restore {
  if (value.length > RESTORE_VALUE_LIMIT || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw failure("invalid restore instruction");
  let params: Record<string, unknown>;
  try {
    params = JSON.parse(Buffer.from(value, "base64").toString("utf8"));
  } catch {
    throw failure("invalid restore instruction");
  }
  const operation = String(params?.operation ?? "");
  if (!OPERATION.test(operation)) throw failure("invalid archive operation");
  const bytes = Number(params.bytes);
  if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > ARCHIVE_COMPRESSED_LIMIT) throw failure("invalid streaming archive");
  const manifest_url = String(params.manifest_url ?? "");
  if (!allowedUrl(manifest_url)) throw failure("invalid archive manifest URL");
  return { operation, bytes, manifest_url };
}

/** The archive's parts as its manifest lists them (`{operation, bytes, parts}`): the archive the start named, whole. */
export function manifestParts(body: string, restore: Restore, allowedUrl: (url: string) => boolean): SignedPart[] {
  let manifest: Record<string, unknown>;
  try {
    manifest = JSON.parse(body);
  } catch {
    throw failure("invalid archive manifest");
  }
  if (manifest?.operation !== restore.operation || manifest.bytes !== restore.bytes) throw failure("archive manifest names another archive");
  const parts = manifest.parts as SignedPart[];
  if (!Array.isArray(parts) || parts.length === 0 || parts.length > ARCHIVE_MAX_PARTS) throw failure("invalid streaming archive");
  let expected = 0;
  for (const [index, part] of parts.entries()) {
    const remaining = restore.bytes - index * ARCHIVE_PART_BYTES;
    if (remaining <= 0 || part?.bytes !== Math.min(ARCHIVE_PART_BYTES, remaining) || !allowedUrl(String(part.get_url))) throw failure("invalid streaming archive part");
    expected += part.bytes;
  }
  if (expected !== restore.bytes) throw failure("streaming archive size mismatch");
  return parts.map((part) => ({ get_url: part.get_url, bytes: part.bytes }));
}

/** One sync of the filesystem `root` is on: Linux's syncfs (`sync -f`); elsewhere `sync` syncs every filesystem. */
const syncFilesystem = (root: string) => new Promise<void>((resolve, reject) => void execFile("sync", ["-f", root], (error) => (error ? reject(error) : resolve())));

/** The manifest's text, retrying 429, 5xx and network errors as a part's read does. */
async function getManifest(url: string, signal: AbortSignal, sleep: Sleep): Promise<string> {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(url, { redirect: "manual", signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]) });
      if (response.status === 200) {
        const body = Buffer.from(await response.arrayBuffer());
        if (body.length > MANIFEST_LIMIT) throw failure("archive manifest too large");
        return body.toString("utf8");
      }
      await response.body?.cancel();
      if (attempt + 1 >= PART_ATTEMPTS || (response.status !== 429 && response.status < 500)) throw failure("archive manifest read failed");
    } catch (error) {
      if (signal.aborted || attempt + 1 >= PART_ATTEMPTS || /^archive manifest (too large|read failed)$/.test((error as Error).message)) throw error;
    }
    await backoff(sleep, attempt, signal);
  }
}

/**
 * Unpacks the archive a Container's start named onto `root`, before any station runs there: nothing is seeded yet, and
 * the archive's entries (the databases' snapshots among them) take their places. `runtime` names, as the archive does,
 * where the station that will start keeps its runtime state: what an archive holds there (one made before exports left
 * it out) is another machine's and is not restored. The receipt in `dir` says what the disk was restored from; the
 * same operation answers again, and a disk that began another restore, or did not finish this one, is not a disk to
 * start a station on. No file is synced as it is written: the disk is new, and one whose restore failed is replaced, so
 * the root is synced once (`sync`), after every entry is in place and before the receipt says `restored`. `now` (ms)
 * times the restore's steps for the receipt.
 */
export function restoreBeforeStart(options: { root: string; dir: string; restore: string; allowedUrl(url: string): boolean; runtime?: string[]; sleep?: Sleep; sync?: (root: string) => Promise<void>; now?: () => number }): Effect.Effect<ImportState, Error> {
  return Effect.gen(function* () {
    const now = options.now ?? wall.now;
    const started = now();
    const since = () => now() - started;
    const restore = yield* Effect.try({ try: () => decodeRestore(options.restore, options.allowedUrl), catch: (e) => e as Error });
    const { operation, bytes } = restore;
    const runtime = options.runtime ?? [];
    mkdirSync(options.root, { recursive: true });
    mkdirSync(options.dir, { recursive: true, mode: 0o700 });
    const importPath = join(options.dir, "import.json");
    const previous = read<ImportState>(importPath);
    if (previous) {
      if (previous.operation === operation && previous.phase === "restored") return previous;
      return yield* Effect.fail(failure(previous.operation !== operation ? "restore operation changed" : "partial restore requires a new disk"));
    }
    const abort = new AbortController();
    const sleep = options.sleep ?? ((ms, signal) => wait(ms, undefined, { signal }));
    // Nothing is on the disk until the manifest is read and names this archive.
    const parts = yield* Effect.tryPromise({
      try: async () => manifestParts(await getManifest(restore.manifest_url, abort.signal, sleep), restore, options.allowedUrl),
      catch: (e) => e as Error,
    });
    const manifest_ms = since();
    let first_byte_ms = 0;
    let downloaded_ms = 0;
    const arrived = (count: number) => {
      if (count === 1) first_byte_ms = since();
      if (count === parts.length) downloaded_ms = since();
    };
    save(importPath, { operation, phase: "restoring", bytes } satisfies ImportState);
    const restored = yield* Effect.exit(
      Effect.gen(function* () {
        const count = yield* restoreTar(partsReader(parts, abort.signal, sleep, arrived), options.root, { codec: "zstd", fileLimit: MIGRATION_BYTE_LIMIT, hooks: { leaveOut: (name) => runtime.some((dir) => under(name, dir)) } });
        const written_ms = since();
        yield* Effect.tryPromise({ try: () => (options.sync ?? syncFilesystem)(options.root), catch: (e) => e as Error });
        return { ...count, written_ms, synced_ms: since() };
      }).pipe(Effect.onInterrupt(() => Effect.sync(() => abort.abort()))),
    );
    if (Exit.isFailure(restored)) {
      const error = String(restored.cause);
      save(importPath, { operation, phase: "failed", bytes, error: error.slice(0, 500) } satisfies ImportState);
      return yield* Effect.fail(failure(`streaming restore failed: ${error.slice(0, 200)}`));
    }
    const { entries, files, written_ms, synced_ms } = restored.value;
    const done: ImportState = { operation, phase: "restored", bytes, entries, files, timings: { manifest_ms, first_byte_ms, downloaded_ms, written_ms, synced_ms, total_ms: since() } };
    save(importPath, done);
    return done;
  });
}
