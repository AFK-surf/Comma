// read_ref: a dedicated read-only transport for the desktop app's private local-file index (modeled in
// tla/salix/LocalFileImport.tla). It takes no path: the only possible target is the immutable object an opaque ref
// selects. The index directory is pinned when opened and children are opened relative to it without following links
// (the native addon's openat), so renaming or replacing the root's path cannot redirect a read.
import { createHash } from "node:crypto";
import { close as closeFd, constants, fstat as fstatFd, open as openFd, read as readFd, realpathSync, lstatSync, type Stats } from "node:fs";
import { isAbsolute, join, normalize, resolve } from "node:path";
import { promisify } from "node:util";
import { Effect } from "effect";
import { stationNative } from "./native.ts";
import { type Message, stringParam } from "./message.ts";
import type { Session } from "./session.ts";
import { platform } from "../platform/index.ts";

export const LOCAL_FILE_INDEX_VERSION = 2;
export const LOCAL_FILE_INDEX_RECORD_MAX_BYTES = 16 * 1024;
export const LOCAL_FILE_MAX_BYTES = 512 * 1024 * 1024;
export const LOCAL_FILE_CHUNK_BYTES = 256 * 1024;
export const LOCAL_FILE_STREAM_LEASE_MS = 60 * 1000;

const REF = /^lfi1_[A-Za-z0-9_-]{43}$/;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const HASH = /^[a-f0-9]{64}$/;

export class LocalFileRequestRejected extends Error {
  override readonly name = "LocalFileRequestRejected";
  constructor() {
    super("local attachment request rejected");
  }
}
export class LocalFileUnavailable extends Error {
  override readonly name = "LocalFileUnavailable";
  constructor() {
    super("local attachment unavailable");
  }
}
export class LocalFileCorrupt extends Error {
  override readonly name = "LocalFileCorrupt";
  constructor() {
    super("local attachment snapshot is corrupt");
  }
}

export type LocalFileIndexRecord = {
  createdAtMs: number;
  displayName: string;
  localFileRef: string;
  mediaType: string;
  objectId: string;
  ownerUserId: string;
  sha256: string;
  size: number;
  state: string;
  version: number;
};

const fstat = promisify(fstatFd);
const read = promisify(readFd);
const closeAsync = promisify(closeFd);
const openAsync = promisify(openFd);

// Where modes say nothing of who may read (Windows: an ACL does), the directory being the app's own is what keeps it.
const privateMode = (stats: Stats) => !platform.modesArePrivate || (stats.mode & 0o077) === 0;

/** An open file descriptor read through the pool; closed exactly once. */
class OpenFile {
  private closed = false;
  readonly fd: number;
  constructor(fd: number) {
    this.fd = fd;
  }
  stat() {
    return fstat(this.fd);
  }
  async readAt(buffer: Buffer, position: number): Promise<number> {
    let filled = 0;
    while (filled < buffer.length) {
      const { bytesRead } = await read(this.fd, buffer, filled, buffer.length - filled, position + filled);
      if (bytesRead === 0) break;
      filled += bytesRead;
    }
    return filled;
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    await closeAsync(this.fd).catch(() => {});
  }
}

export type PinnedLocalFileIndex = {
  readRecord(ref: string): Effect.Effect<LocalFileIndexRecord, Error>;
  /** The whole object (tests and small reads). */
  readObject(objectId: string): Effect.Effect<Buffer, Error>;
  openObject(objectId: string): Effect.Effect<OpenFile, Error>;
  close(): Effect.Effect<void>;
};

const attempt = <A>(f: () => Promise<A>, error: () => Error) => Effect.tryPromise({ try: f, catch: error });

/**
 * Opens the index root (its platform-owned ancestor aliases resolved once, then walked without following links), and
 * its entries/ and objects/ directories; every directory must be private.
 */
export function openPinnedLocalFileIndex(root: string): Effect.Effect<PinnedLocalFileIndex, Error> {
  return attempt(async () => {
    const absolute = resolve(root);
    if (!isAbsolute(absolute)) throw new LocalFileUnavailable();
    const before = lstatSync(absolute);
    if (!before.isDirectory() || before.isSymbolicLink()) throw new LocalFileUnavailable();
    const canonical = normalize(realpathSync(absolute));
    if (!platform.opensDirectories) return pinnedByIdentity(canonical, before);
    const native = stationNative();
    const fds: number[] = [];
    try {
      const rootFile = new OpenFile(native.openDirectoryNofollow(canonical));
      fds.push(rootFile.fd);
      const after = await rootFile.stat();
      if (after.dev !== before.dev || after.ino !== before.ino || !after.isDirectory() || !privateMode(after)) throw new LocalFileUnavailable();
      const entries = new OpenFile(native.openatNofollow(rootFile.fd, "entries", true));
      fds.push(entries.fd);
      const objects = new OpenFile(native.openatNofollow(rootFile.fd, "objects", true));
      fds.push(objects.fd);
      for (const dir of [entries, objects]) {
        const info = await dir.stat();
        if (!info.isDirectory() || !privateMode(info)) throw new LocalFileUnavailable();
      }
      const openChild = (dir: OpenFile, name: string) => attempt(async () => new OpenFile(native.openatNofollow(dir.fd, name, false)), () => new LocalFileUnavailable());
      const index: PinnedLocalFileIndex = {
        readRecord: (ref) => readRecordFrom(ref, (objectId) => openChild(entries, `${objectId}.json`)),
        openObject: (objectId) => (TOKEN.test(objectId) ? openChild(objects, objectId) : Effect.fail(new LocalFileRequestRejected())),
        readObject: (objectId) =>
          Effect.acquireUseRelease(
            index.openObject(objectId),
            (file) =>
              attempt(
                async () => {
                  const size = (await file.stat()).size;
                  const buffer = Buffer.alloc(size);
                  await file.readAt(buffer, 0);
                  return buffer;
                },
                () => new LocalFileUnavailable(),
              ),
            (file) => Effect.promise(() => file.close()),
          ),
        close: () => Effect.promise(async () => void (await Promise.all([rootFile, entries, objects].map((f) => f.close())))),
      };
      return index;
    } catch (error) {
      for (const fd of fds) closeFd(fd, () => {});
      throw error instanceof LocalFileUnavailable ? error : new LocalFileUnavailable();
    }
  }, () => new LocalFileUnavailable()).pipe(Effect.mapError((e) => (e instanceof Error ? e : new LocalFileUnavailable())));
}

/**
 * The index where no directory can be held open (Node on Windows): each directory pinned by its identity (dev, ino) as
 * first seen, a child opened by path only while its directory is still that one and the child is no link, and kept
 * only when the file opened is the one looked at. A rename and replace between the look and the open is refused, not
 * followed.
 */
function pinnedByIdentity(canonical: string, before: Stats): PinnedLocalFileIndex {
  const same = (a: Stats, b: Stats) => a.dev === b.dev && a.ino === b.ino;
  const pinDir = (path: string, expected?: Stats) => {
    const info = lstatSync(path);
    if (!info.isDirectory() || info.isSymbolicLink() || !privateMode(info) || (expected && !same(info, expected))) throw new LocalFileUnavailable();
    return { path, info };
  };
  const rootDir = pinDir(canonical, before);
  const entries = pinDir(join(canonical, "entries"));
  const objects = pinDir(join(canonical, "objects"));
  const openChild = (dir: { path: string; info: Stats }, name: string) =>
    attempt(async () => {
      if (name === "" || name === "." || name === ".." || /[\\/\0:]/.test(name)) throw new LocalFileUnavailable();
      pinDir(rootDir.path, rootDir.info);
      pinDir(dir.path, dir.info);
      const path = join(dir.path, name);
      const seen = lstatSync(path);
      if (seen.isSymbolicLink() || !seen.isFile()) throw new LocalFileUnavailable();
      const file = new OpenFile(await openAsync(path, constants.O_RDONLY));
      const opened = await file.stat().catch(() => null);
      if (!opened || !same(opened, seen)) {
        await file.close();
        throw new LocalFileUnavailable();
      }
      return file;
    }, () => new LocalFileUnavailable());
  const index: PinnedLocalFileIndex = {
    readRecord: (ref) => readRecordFrom(ref, (objectId) => openChild(entries, `${objectId}.json`)),
    openObject: (objectId) => (TOKEN.test(objectId) ? openChild(objects, objectId) : Effect.fail(new LocalFileRequestRejected())),
    readObject: (objectId) =>
      Effect.acquireUseRelease(
        index.openObject(objectId),
        (file) =>
          attempt(
            async () => {
              const size = (await file.stat()).size;
              const buffer = Buffer.alloc(size);
              await file.readAt(buffer, 0);
              return buffer;
            },
            () => new LocalFileUnavailable(),
          ),
        (file) => Effect.promise(() => file.close()),
      ),
    close: () => Effect.void,
  };
  return index;
}

function readRecordFrom(ref: string, openEntry: (objectId: string) => Effect.Effect<OpenFile, Error>): Effect.Effect<LocalFileIndexRecord, Error> {
  return Effect.gen(function* () {
    if (!REF.test(ref)) return yield* Effect.fail(new LocalFileRequestRejected());
    const objectId = ref.slice("lfi1_".length);
    if (!TOKEN.test(objectId)) return yield* Effect.fail(new LocalFileRequestRejected());
    const data = yield* Effect.acquireUseRelease(
      openEntry(objectId),
      (entry) =>
        attempt(
          async () => {
            const info = await entry.stat();
            if (!info.isFile() || !privateMode(info) || info.size <= 0 || info.size > LOCAL_FILE_INDEX_RECORD_MAX_BYTES) throw new LocalFileCorrupt();
            const buffer = Buffer.alloc(LOCAL_FILE_INDEX_RECORD_MAX_BYTES + 1);
            const n = await entry.readAt(buffer, 0);
            if (n > LOCAL_FILE_INDEX_RECORD_MAX_BYTES) throw new LocalFileCorrupt();
            return buffer.subarray(0, n).toString("utf8");
          },
          () => new LocalFileCorrupt(),
        ),
      (entry) => Effect.promise(() => entry.close()),
    );
    return yield* Effect.try({ try: () => parseRecord(data, ref, objectId), catch: () => new LocalFileCorrupt() });
  });
}

function parseRecord(data: string, ref: string, objectId: string): LocalFileIndexRecord {
  const raw = JSON.parse(data) as Record<string, unknown>;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new LocalFileCorrupt();
  const version = raw.version;
  if (version !== 1 && version !== 2) throw new LocalFileCorrupt();
  const keys = ["created_at_ms", "display_name", "local_file_ref", "media_type", "object_id", "sha256", "size", "state", "version"];
  if (version === 2) keys.push("owner_user_id");
  if (Object.keys(raw).length !== keys.length || keys.some((key) => !(key in raw))) throw new LocalFileCorrupt();
  const str = (key: string) => (typeof raw[key] === "string" ? (raw[key] as string) : (() => { throw new LocalFileCorrupt(); })());
  const int = (key: string) => (Number.isInteger(raw[key]) ? (raw[key] as number) : (() => { throw new LocalFileCorrupt(); })());
  const record: LocalFileIndexRecord = {
    createdAtMs: int("created_at_ms"),
    displayName: str("display_name"),
    localFileRef: str("local_file_ref"),
    mediaType: str("media_type"),
    objectId: str("object_id"),
    ownerUserId: version === 2 ? str("owner_user_id") : "",
    sha256: str("sha256"),
    size: int("size"),
    state: str("state"),
    version,
  };
  const validOwner = (value: string) => value !== "" && value.length <= 160 && !/[\0\r\n]/.test(value);
  if (
    record.localFileRef !== ref ||
    record.objectId !== objectId ||
    record.createdAtMs <= 0 ||
    record.size < 0 ||
    record.size > LOCAL_FILE_MAX_BYTES ||
    !record.displayName ||
    record.displayName.length > 255 ||
    !record.mediaType ||
    record.mediaType.length > 255 ||
    (version === 2 && !validOwner(record.ownerUserId)) ||
    !HASH.test(record.sha256) ||
    !["bound", "draft", "registered", "revoked"].includes(record.state)
  ) {
    throw new LocalFileCorrupt();
  }
  return record;
}

export function readLocalFileIndexRecord(root: string, ref: string): Effect.Effect<LocalFileIndexRecord, Error> {
  return Effect.acquireUseRelease(
    openPinnedLocalFileIndex(root),
    (index) => index.readRecord(ref),
    (index) => index.close(),
  );
}

export type LocalFileReadRequest = {
  ref: string;
  ownerUserId: string;
  stableDeviceId: string;
  connectorRunId: string;
  connectionGeneration: number;
  canonicalMessageId: string;
  expectedMaxBytes: number;
  streamLeaseMs: number;
};

const ALLOWED_PARAMS = ["canonical_message_id", "connection_generation", "connector_run_id", "expected_max_bytes", "local_file_ref", "owner_user_id", "stream_lease_ms", "stable_device_id"];

const exactInt = (value: unknown) => (typeof value === "number" && Number.isInteger(value) ? value : 0);

export function parseLocalFileReadRequest(params: Record<string, unknown>): LocalFileReadRequest {
  const keys = Object.keys(params);
  if (keys.length !== ALLOWED_PARAMS.length || keys.some((k) => !ALLOWED_PARAMS.includes(k))) throw new LocalFileRequestRejected();
  const request: LocalFileReadRequest = {
    ref: stringParam(params, "local_file_ref"),
    ownerUserId: stringParam(params, "owner_user_id"),
    stableDeviceId: stringParam(params, "stable_device_id"),
    connectorRunId: stringParam(params, "connector_run_id"),
    canonicalMessageId: stringParam(params, "canonical_message_id"),
    expectedMaxBytes: exactInt(params.expected_max_bytes),
    streamLeaseMs: exactInt(params.stream_lease_ms),
    connectionGeneration: exactInt(params.connection_generation),
  };
  if (
    !REF.test(request.ref) ||
    !request.ownerUserId ||
    !request.stableDeviceId ||
    !request.connectorRunId ||
    !request.canonicalMessageId ||
    request.canonicalMessageId.length > 160 ||
    request.connectionGeneration <= 0 ||
    request.expectedMaxBytes < 0 ||
    request.expectedMaxBytes > LOCAL_FILE_MAX_BYTES ||
    request.streamLeaseMs !== LOCAL_FILE_STREAM_LEASE_MS
  ) {
    throw new LocalFileRequestRejected();
  }
  return request;
}

/**
 * Streams the snapshot an exact live identity owns: verified before the first byte and again after the last; EOF is a
 * separate commit frame sent only when the delivered bytes match the record and the same connection still owns it.
 */
export function readRefFrames(options: {
  root: string;
  session: Session;
  id: string;
  params: Record<string, unknown>;
  identityCurrent: (session: Session, request: LocalFileReadRequest) => boolean;
}): Effect.Effect<Record<string, unknown>, Error> {
  const { session, id } = options;
  return Effect.gen(function* () {
    const request = yield* Effect.try({ try: () => parseLocalFileReadRequest(options.params), catch: () => new LocalFileRequestRejected() });
    if (!options.identityCurrent(session, request) || !options.root) return yield* Effect.fail(new LocalFileUnavailable());
    return yield* Effect.acquireUseRelease(
      openPinnedLocalFileIndex(options.root).pipe(Effect.mapError(() => new LocalFileUnavailable())),
      (index) =>
        Effect.gen(function* () {
          const record = yield* index.readRecord(request.ref);
          if (record.version === 2 && record.ownerUserId !== request.ownerUserId) return yield* Effect.fail(new LocalFileUnavailable());
          // A draft has no authenticated server route yet; only Main's post-registration transition makes it readable.
          if ((record.state !== "registered" && record.state !== "bound") || record.size > request.expectedMaxBytes) return yield* Effect.fail(new LocalFileUnavailable());
          return yield* Effect.acquireUseRelease(
            index.openObject(record.objectId).pipe(Effect.mapError(() => new LocalFileUnavailable())),
            (file) => streamObject(file, record, request, options),
            (file) => Effect.promise(() => file.close()),
          );
        }),
      (index) => index.close(),
    );
  });
}

function streamObject(
  file: OpenFile,
  record: LocalFileIndexRecord,
  request: LocalFileReadRequest,
  options: { session: Session; id: string; identityCurrent: (session: Session, request: LocalFileReadRequest) => boolean },
): Effect.Effect<Record<string, unknown>, Error> {
  const { session, id } = options;
  return Effect.gen(function* () {
    const info = yield* attempt(() => file.stat(), () => new LocalFileCorrupt());
    if (!info.isFile() || !privateMode(info) || info.size !== record.size || info.size > LOCAL_FILE_MAX_BYTES) return yield* Effect.fail(new LocalFileCorrupt());
    // Verify the whole snapshot before its first byte leaves; the receiver still commits only after the EOF frame.
    const verified = yield* attempt(() => hashFile(file, record.size), () => new LocalFileCorrupt());
    if (verified !== record.sha256) return yield* Effect.fail(new LocalFileCorrupt());
    const streamHash = createHash("sha256");
    let sent = 0;
    let seq = 0;
    while (sent < record.size) {
      const chunk = Buffer.alloc(Math.min(LOCAL_FILE_CHUNK_BYTES, record.size - sent));
      const n = yield* attempt(() => file.readAt(chunk, sent), () => new LocalFileCorrupt());
      if (n !== chunk.length) return yield* Effect.fail(new LocalFileCorrupt());
      sent += n;
      streamHash.update(chunk);
      seq++;
      const frame: Message = { id, type: "stream", stream: { channel: "data", data: chunk.toString("base64"), eof: false, seq } };
      yield* session.sendReadStreamFrame(id, seq, frame);
    }
    const actual = streamHash.digest("hex");
    if (sent !== record.size || actual !== record.sha256) return yield* Effect.fail(new LocalFileCorrupt());
    if (!options.identityCurrent(session, request)) return yield* Effect.fail(new LocalFileUnavailable());
    yield* session.send({ id, type: "stream", stream: { channel: "data", eof: true, seq: seq + 1 } });
    return { local_file_ref: request.ref, canonical_message_id: request.canonicalMessageId, size: sent, sha256: actual };
  });
}

async function hashFile(file: OpenFile, expectedSize: number): Promise<string> {
  const hash = createHash("sha256");
  const buffer = Buffer.alloc(1 << 20);
  let position = 0;
  while (position < expectedSize) {
    const want = Math.min(buffer.length, expectedSize - position);
    const n = await file.readAt(buffer.subarray(0, want), position);
    if (n !== want) throw new LocalFileCorrupt();
    hash.update(buffer.subarray(0, n));
    position += n;
  }
  const extra = Buffer.alloc(1);
  if ((await file.readAt(extra, position)) !== 0) throw new LocalFileCorrupt();
  return hash.digest("hex");
}
