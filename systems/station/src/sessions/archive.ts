// Cold storage for owned session workspaces and runtime transcripts (the Rust station's archive.rs). The caller holds the
// room's lock and has stopped its actor. Originals are removed only after a complete, checksummed archive has been read
// back.
//
// The files are the Rust's, byte for byte in format, so either station restores what the other packed: a workspace is
// `workspace.tar.zst` in its room (a GNU tar as the tar crate writes it, zstd level 3 with a checksum), a transcript
// `<file>.jsonl.zst` beside where it was; the same temporaries (`.writing`, `.restoring`, `workspace.retiring`,
// `workspace.restored-old`), the same `archive.lock` and `<file>.jsonl.archive-lock`, the same `workspace-locks.json`
// and the git worktree `locked` files with the same marker.
//
// Everything streams (the zstd work runs on libuv's pool, the file reads and writes are async): packing a large
// workspace never holds the main thread for long.
//
// The lock: Node has no flock; the native addon's (native/mesh/src/local.rs) is taken, as the Rust takes it. Without the
// addon (tests), the lock files are made where the Rust makes them but the lock itself is held within
// this process (one station at a time works on a data directory; only an overlap at a handover would see both).
import { loadMesh } from "../mesh/native.ts";
import { execFile } from "node:child_process";
import { type Dirent, existsSync, readdirSync } from "node:fs";
import {
  chmod,
  copyFile,
  lstat,
  link,
  mkdir,
  open,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  stat,
  unlink,
  utimes,
} from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { segments } from "../ops/paths.ts";
import { link as symlinkOrStandIn } from "../ops/links.ts";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { constants, createZstdCompress, createZstdDecompress } from "node:zlib";
import { platform } from "../platform/index.ts";

// ── paths ──────────────────────────────────────────────────────────────────────────────────────────────────────────

/// Path::with_extension: the file name's extension (after its last dot, not a leading one) replaced, or added.
export function withExtension(path: string, ext: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return join(dirname(path), ext === "" ? stem : `${stem}.${ext}`);
}

/// Path::extension.
const extension = (path: string): string | null => {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1) : null;
};

export const workspaceArchive = (room: string) => join(room, "workspace.tar.zst");

/// Where a file is once put away.
export const packed = (path: string) => `${path}.zst`;

/// The raw path stays the stable identity for readers and their offsets, even while its bytes are compressed.
export const storage = (path: string) => (existsSync(path) ? path : packed(path));

// ── the lock ───────────────────────────────────────────────────────────────────────────────────────────────────────

const held = new Map<string, Promise<void>>();

let addon: ((path: string) => Promise<{ release(): void }>) | null | undefined;
function nativeLock() {
  if (addon === undefined) {
    try {
      const mesh = loadMesh();
      addon = (path: string) => mesh.fileLock(path);
    } catch {
      addon = null;
    }
  }
  return addon;
}

/// file_lock: the lock file made (0600, never truncated) and the lock taken, in turn with whoever else in this process
/// asked for it. The returned function lets it go.
async function fileLock(path: string): Promise<() => void> {
  const before = held.get(path) ?? Promise.resolve();
  let release!: () => void;
  const mine = new Promise<void>((resolve) => (release = resolve));
  const tail = before.then(() => mine);
  held.set(path, tail);
  const done = () => {
    release();
    if (held.get(path) === tail) held.delete(path);
  };
  await before;
  try {
    // Across processes too (a handover's two, a Rust station's), with the native addon's flock, when it is there.
    const native = nativeLock();
    if (native === null) {
      await (await open(path, "a", 0o600)).close();
      return done;
    }
    const held = await native(path);
    return () => {
      held.release();
      done();
    };
  } catch (error) {
    done();
    throw error;
  }
}

/// A room's lock (`archive.lock` in it): held while its workspace is packed, restored, read from its archive or deleted.
export const lock = (room: string) => fileLock(join(room, "archive.lock"));

/// `f` run under a room's lock.
export async function withLock<T>(room: string, f: () => Promise<T>): Promise<T> {
  const release = await lock(room);
  try {
    return await f();
  } finally {
    release();
  }
}

// ── zstd ───────────────────────────────────────────────────────────────────────────────────────────────────────────

/// zstd level 3 with a checksum, as the Rust's encoder.
const compressor = () =>
  createZstdCompress({ params: { [constants.ZSTD_c_compressionLevel]: 3, [constants.ZSTD_c_checksumFlag]: 1 } });

/// A file's bytes decompressed, as they come: its frames whole (a cut stream fails, as the Rust's decoder's "incomplete
/// frame"; Node's decompressor ends quietly at a cut), their checksums verified.
function unzstd(path: string): Readable {
  return Readable.from(
    (async function* () {
      await wholeFrames(path);
      const raw = Readable.from(chunksOf(path));
      const out = createZstdDecompress();
      raw.on("error", (e) => out.destroy(e));
      raw.pipe(out);
      try {
        for await (const chunk of out) yield chunk as Buffer;
      } finally {
        raw.destroy();
        out.destroy();
      }
    })(),
    { objectMode: false },
  );
}

/// Walks a zstd file's frames by their headers (RFC 8878: frame header, block headers, checksum; skippable frames
/// skipped), failing unless each one is there whole.
async function wholeFrames(path: string): Promise<void> {
  const file = await open(path, "r");
  try {
    const size = (await file.stat()).size;
    const bytes = async (at: number, n: number) => {
      const buf = Buffer.alloc(n);
      const { bytesRead } = await file.read(buf, 0, n, at);
      if (bytesRead < n) throw new Error(`${path}: incomplete zstd frame`);
      return buf;
    };
    if (size === 0) throw new Error(`${path}: no zstd frame`);
    for (let at = 0; at < size; ) {
      const magic = (await bytes(at, 4)).readUInt32LE(0);
      if ((magic & 0xfffffff0) >>> 0 === 0x184d2a50) {
        at += 8 + (await bytes(at + 4, 4)).readUInt32LE(0);
        if (at > size) throw new Error(`${path}: incomplete zstd frame`);
        continue;
      }
      if (magic !== 0xfd2fb528) throw new Error(`${path}: not a zstd frame`);
      const descriptor = (await bytes(at + 4, 1))[0]!;
      const sizeFlag = descriptor >> 6;
      const single = (descriptor >> 5) & 1;
      const checksummed = (descriptor >> 2) & 1;
      const dictionary = [0, 1, 2, 4][descriptor & 3]!;
      const contentSize = sizeFlag === 0 ? single : [0, 2, 4, 8][sizeFlag]!;
      at += 5 + (single ? 0 : 1) + dictionary + contentSize;
      for (;;) {
        const head = await bytes(at, 3);
        const block = head[0]! | (head[1]! << 8) | (head[2]! << 16);
        const type = (block >> 1) & 3;
        if (type === 3) throw new Error(`${path}: reserved zstd block type`);
        at += 3 + (type === 1 ? 1 : block >>> 3);
        if (block & 1) break;
      }
      if (checksummed) at += 4;
      if (at > size) throw new Error(`${path}: incomplete zstd frame`);
    }
  } finally {
    await file.close();
  }
}

const CHUNK = 256 * 1024;

/// A file read in chunks, up to `limit` bytes (all of it by default).
async function* chunksOf(path: string, limit = Infinity): AsyncGenerator<Buffer> {
  const file = await open(path, "r");
  try {
    let left = limit;
    while (left > 0) {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK, left));
      const { bytesRead } = await file.read(buf, 0, buf.length, null);
      if (bytesRead === 0) return;
      left -= bytesRead;
      yield buf.subarray(0, bytesRead);
    }
  } finally {
    await file.close();
  }
}

/// encoder + finish + sync_all: `source` compressed into `path` (made 0600), on disk before this returns.
async function compressInto(path: string, source: AsyncIterable<Buffer>): Promise<void> {
  const file = await open(path, "w", 0o600);
  try {
    await file.chmod(0o600);
    await pipeline(Readable.from(source), compressor(), async (compressed: AsyncIterable<Buffer>) => {
      for await (const chunk of compressed) await writeAll(file, chunk);
    });
    await file.sync();
  } finally {
    await file.close();
  }
}

async function writeAll(file: import("node:fs/promises").FileHandle, chunk: Buffer) {
  for (let at = 0; at < chunk.length; ) at += (await file.write(chunk, at, chunk.length - at)).bytesWritten;
}

/// Reads everything left, for its checksum.
async function drain(stream: AsyncIterable<Buffer>) {
  for await (const _ of stream);
}

/// A directory's entries made durable (File::open(dir).sync_all()), where a directory syncs (on Windows Node's is
/// refused, EPERM: NTFS journals a directory's entries itself).
async function syncDir(dir: string) {
  if (!platform.syncsDirectories) return;
  const handle = await open(dir, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

const exists = async (path: string) => {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
};
const lstatOrNull = async (path: string) => {
  try {
    return await lstat(path);
  } catch {
    return null;
  }
};

// ── transcripts ────────────────────────────────────────────────────────────────────────────────────────────────────

/// Compress a transcript in place, leaving its filename discoverable as <original>.zst. Retry after a crash safely: an
/// original still there always wins over the old compressed copy.
export const packFile = (path: string) => packFileIf(path, () => true);

export async function packFileIf(path: string, ready: () => boolean): Promise<void> {
  const release = await fileLock(withExtension(path, "jsonl.archive-lock"));
  try {
    if (!(await lstatOrNull(path))?.isFile()) {
      if (await exists(packed(path))) await drain(unzstd(packed(path)));
      return;
    }
    const dest = packed(path);
    const temp = withExtension(dest, "zst.writing");
    try {
      await compressInto(temp, chunksOf(path));
      await sameBytes(unzstd(temp), path);
      if (!ready()) return;
      await rename(temp, dest);
      await syncDir(dirname(dest));
      await unlink(path);
    } finally {
      await rm(temp, { force: true });
    }
  } finally {
    release();
  }
}

/// The decompressed copy is the file, byte for byte.
async function sameBytes(copy: AsyncIterable<Buffer>, path: string) {
  const file = await open(path, "r");
  try {
    let at = 0;
    for await (const chunk of copy) {
      const mine = Buffer.allocUnsafe(chunk.length);
      let got = 0;
      while (got < chunk.length) {
        const { bytesRead } = await file.read(mine, got, chunk.length - got, at + got);
        if (bytesRead === 0) break;
        got += bytesRead;
      }
      if (got < chunk.length) throw new Error("transcript shortened while archiving");
      if (!mine.equals(chunk)) throw new Error(`transcript changed while archiving ${path}`);
      at += chunk.length;
    }
    const { bytesRead } = await file.read(Buffer.alloc(1), 0, 1, at);
    if (bytesRead !== 0) throw new Error(`transcript changed while archiving ${path}`);
  } finally {
    await file.close();
  }
}

export async function restoreFile(path: string): Promise<void> {
  const release = await fileLock(withExtension(path, "jsonl.archive-lock"));
  try {
    const source = packed(path);
    if (!(await exists(source))) return;
    if (await exists(path)) return; // Never overwrite a runtime's newer transcript.
    const temp = withExtension(path, "jsonl.restoring");
    try {
      const file = await open(temp, "w", 0o600);
      try {
        for await (const chunk of unzstd(source)) await writeAll(file, chunk);
        await file.sync();
      } finally {
        await file.close();
      }
      await rename(temp, path);
      await syncDir(dirname(path));
      await unlink(source);
    } finally {
      await rm(temp, { force: true });
    }
  } finally {
    release();
  }
}

/// Logical JSONL names, including files whose raw bytes have been put away. Never follow directory symlinks.
export function jsonlFiles(dir: string, out: string[]) {
  if (!existsSync(dir)) return;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) jsonlFiles(path, out);
    else if (entry.isFile()) {
      const logical = extension(path) === "zst" ? withExtension(path, "") : path;
      if (extension(logical) === "jsonl" && !out.includes(logical)) out.push(logical);
    }
  }
}

// ── git worktrees ──────────────────────────────────────────────────────────────────────────────────────────────────

async function lockWorktrees(dir: string, marker: string, locks: string[]): Promise<void> {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.name === ".git") {
      if (!entry.isFile()) continue;
      const said = (await readFile(path, "utf8")).trim();
      if (!said.startsWith("gitdir: ")) continue;
      const gitdir = await realpath(resolve(dir, said.slice("gitdir: ".length)));
      const locked = join(gitdir, "locked");
      let file;
      try {
        file = await open(locked, "wx");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        const there = await readFile(locked, "utf8").catch(() => null);
        if (there === marker && !locks.includes(locked)) locks.push(locked);
        continue;
      }
      try {
        await writeAll(file, Buffer.from(marker));
        await file.sync();
      } finally {
        await file.close();
      }
      locks.push(locked);
    } else if (entry.isDirectory()) {
      await lockWorktrees(path, marker, locks);
    }
  }
}

const markerOf = (room: string) => `still.fail archived workspace: ${room}\n`;

export async function unlockWorktrees(room: string): Promise<void> {
  const path = join(room, "workspace-locks.json");
  if (!(await exists(path))) return;
  const locks = JSON.parse(await readFile(path, "utf8")) as string[];
  for (const locked of locks) {
    if ((await readFile(locked, "utf8").catch(() => null)) === markerOf(room)) await unlink(locked);
  }
  await unlink(path);
}

// ── workspaces ─────────────────────────────────────────────────────────────────────────────────────────────────────

/// Every path under `dir` with its size and modification time, symlinks not followed.
async function snapshot(dir: string, files: Map<string, string>): Promise<void> {
  for (const name of await readdir(dir)) {
    const path = join(dir, name);
    const meta = await lstat(path, { bigint: true });
    files.set(path, `${meta.size}:${meta.mtimeNs}`);
    if (meta.isDirectory()) await snapshot(path, files);
  }
}

const sameMap = (a: Map<string, string>, b: Map<string, string>) => a.size === b.size && [...a].every(([k, v]) => b.get(k) === v);

export const packWorkspace = (room: string) => packWorkspaceIf(room, () => true);

export async function packWorkspaceIf(room: string, ready: () => boolean): Promise<void> {
  const archive = workspaceArchive(room);
  if (await exists(archive)) return;
  const workspace = join(room, "workspace");
  if (!(await stat(workspace).catch(() => null))?.isDirectory()) return;
  const temp = join(room, "workspace.tar.zst.writing");
  try {
    const locksPath = join(room, "workspace-locks.json");
    const locks: string[] = (await exists(locksPath)) ? JSON.parse(await readFile(locksPath, "utf8")) : [];
    // Keep registered worktrees out of `git worktree prune` while their .git files are inside the archive.
    let locked: unknown = null;
    await lockWorktrees(workspace, markerOf(room), locks).catch((e) => (locked = e ?? new Error("worktrees not locked")));
    const saved = await open(locksPath, "w");
    try {
      await writeAll(saved, Buffer.from(JSON.stringify(locks)));
      await saved.sync();
    } finally {
      await saved.close();
    }
    if (locked !== null) throw locked;
    const before = new Map<string, string>();
    await snapshot(workspace, before);
    await compressInto(temp, tarOf(workspace));
    // Read all entries, including the end of the zstd stream/checksum, before touching any originals.
    const check = unzstd(temp);
    try {
      const bytes = new ByteReader(check[Symbol.asyncIterator]());
      for await (const entry of tarEntries(bytes)) await entry.skip();
      await bytes.drain();
    } finally {
      check.destroy();
    }
    const after = new Map<string, string>();
    await snapshot(workspace, after);
    if (!sameMap(before, after)) throw new Error("workspace changed while archiving; originals kept");
    if (!ready()) {
      await unlockWorktrees(room);
      return;
    }
    await rename(temp, archive);
    await syncDir(room);
    const retiring = join(room, "workspace.retiring");
    if (await exists(retiring)) throw new Error("an earlier workspace retirement needs restoration");
    await rename(workspace, retiring);
    await mkdir(workspace);
    await chmod(workspace, (await stat(retiring)).mode & 0o7777);
    await rm(retiring, { recursive: true });
  } finally {
    await rm(temp, { force: true });
  }
}

/// Links the machine refused while the restored tree was being made (Windows without the privilege): by their path in
/// it, their target as written. Made once the tree is at its final path (restoreWorkspace), where what stands in for
/// them (a junction's absolute target, a copy) stays right; a path written again later is no longer one.
type Refused = Map<string, string>;

/// Copy files created since the snapshot into the restored tree. Originals stay intact until the final swap, so an
/// interrupted/failed restoration can be retried without discarding new files or the archive.
async function overlay(source: string, dest: string, refused: Refused): Promise<void> {
  for (const entry of await readdir(source, { withFileTypes: true })) {
    const from = join(source, entry.name);
    const into = join(dest, entry.name);
    const there = await lstatOrNull(into);
    refused.delete(into);
    if (entry.isDirectory()) {
      if (there && !there.isDirectory()) throw new Error(`restore path conflict: ${into}`);
      await mkdir(into, { recursive: true });
      await overlay(from, into, refused);
    } else {
      if (there?.isDirectory()) throw new Error(`restore path conflict: ${into}`);
      if (there) await unlink(into);
      if (entry.isSymbolicLink()) {
        const target = await readlink(from);
        if ((await symlinkOrStandIn(target, into, {})) === "refused") refused.set(into, target);
      } else if (entry.isFile()) await copyFile(from, into);
      else throw new Error(`cannot restore special file ${from}`);
    }
  }
}

const isDir = async (path: string) => (await stat(path).catch(() => null))?.isDirectory() ?? false;

export async function restoreWorkspace(room: string): Promise<void> {
  const archive = workspaceArchive(room);
  if (!(await exists(archive))) return unlockWorktrees(room);
  const stage = join(room, "workspace.restoring");
  if (await exists(stage)) await rm(stage, { recursive: true });
  await mkdir(stage);
  await chmod(stage, 0o700);
  const stream = unzstd(archive);
  const refused: Refused = new Map();
  try {
    const bytes = new ByteReader(stream[Symbol.asyncIterator]());
    await unpack(tarEntries(bytes), stage, refused);
    await bytes.drain();
  } catch (error) {
    throw new Error(`restoring the archived workspace: ${(error as Error).message}`, { cause: error });
  } finally {
    stream.destroy();
  }
  const workspace = join(room, "workspace");
  const retiring = join(room, "workspace.retiring");
  const old = join(room, "workspace.restored-old");
  for (const live of [retiring, old, workspace]) {
    if (await isDir(live)) await overlay(live, stage, refused);
  }
  if (await exists(old)) await rm(old, { recursive: true });
  if (await exists(workspace)) await rename(workspace, old);
  await rename(stage, workspace);
  // The links refused on the way, at their final path now: a junction or a copy stands in (a target that is not
  // there, a dangling link, leaves nothing to stand in for: the link is not restored).
  for (const [path, target] of refused) {
    const at = join(workspace, relative(stage, path));
    if (!(await lstatOrNull(at))) await symlinkOrStandIn(target, at, { junction: true, copy: true });
  }
  await syncDir(room);
  // Everything is now back at its original path. Any interrupted deletion is harmless on the next restore.
  if (await exists(retiring)) await rm(retiring, { recursive: true });
  if (await exists(old)) await rm(old, { recursive: true });
  await unlink(archive);
  await unlockWorktrees(room);
}

/// An archived attachment is read directly from the tar stream, without inflating the whole workspace on disk.
/// `relative`: its path in the workspace.
export async function workspaceFile(room: string, relative: string): Promise<Buffer | null> {
  const archive = workspaceArchive(room);
  if (!(await exists(archive))) return null;
  // The archive's names are `/`-separated; a path from Windows has `\` too.
  const wanted = segments(relative).filter((p) => p !== "" && p !== ".");
  const stream = unzstd(archive);
  try {
    const bytes = new ByteReader(stream[Symbol.asyncIterator]());
    for await (const entry of tarEntries(bytes)) {
      const parts = entry.parts.filter((p) => p !== "/");
      if (entry.parts[0] !== "/" && parts.length === wanted.length && parts.every((p, i) => p === wanted[i]) && entry.kind === "file") {
        const out: Buffer[] = [];
        for await (const chunk of entry.body()) out.push(chunk);
        return Buffer.concat(out);
      }
    }
    return null;
  } finally {
    stream.destroy();
  }
}

// ── tar, as the tar crate writes and reads it ──────────────────────────────────────────────────────────────────────

const BLOCK = 512;

/// A number into a header field: octal, zero-padded, NUL-ended; past what that holds, GNU's base-256.
function numberInto(header: Buffer, at: number, len: number, value: number | bigint) {
  const n = BigInt(value);
  const octal = n.toString(8);
  if (n >= 0n && octal.length <= len - 1) {
    header.write(octal.padStart(len - 1, "0"), at, "latin1");
    header[at + len - 1] = 0;
    return;
  }
  let rest = n < 0n ? 0n : n;
  for (let i = len - 1; i >= 1; i--) {
    header[at + i] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  header[at] = 0x80;
}

/// A field's number: octal (spaces and NULs around it), or base-256 when its first byte's high bit is set.
function numberFrom(field: Buffer): number {
  if (field[0]! & 0x80) {
    let n = BigInt(field[0]! & 0x7f);
    for (const b of field.subarray(1)) n = n * 256n + BigInt(b);
    return Number(n);
  }
  const nul = field.indexOf(0);
  const text = (nul < 0 ? field : field.subarray(0, nul)).toString("latin1").trim();
  if (text === "") return 0;
  if (!/^[0-7]+$/.test(text)) throw new Error(`numeric field was not a number: ${text}`);
  return parseInt(text, 8);
}

const checksum = (header: Buffer) => {
  let sum = 8 * 32;
  for (let i = 0; i < BLOCK; i++) if (i < 148 || i >= 156) sum += header[i]!;
  return sum;
};

type Meta = { mode: number; uid: number; gid: number; mtime: number; size: number };

/// Header::new_gnu with its metadata (HeaderMode::Complete) and checksum.
function gnuHeader(name: Buffer, kind: string, meta: Meta, linkName?: Buffer, device?: [bigint, bigint]): Buffer {
  const h = Buffer.alloc(BLOCK);
  name.copy(h, 0, 0, Math.min(100, name.length));
  numberInto(h, 100, 8, meta.mode);
  numberInto(h, 108, 8, meta.uid);
  numberInto(h, 116, 8, meta.gid);
  numberInto(h, 124, 12, meta.size);
  numberInto(h, 136, 12, meta.mtime);
  h[156] = kind.charCodeAt(0);
  if (linkName) linkName.copy(h, 157, 0, Math.min(100, linkName.length));
  h.write("ustar ", 257, "latin1");
  h.write(" \0", 263, "latin1");
  if (device) {
    numberInto(h, 329, 8, device[0]);
    numberInto(h, 337, 8, device[1]);
  }
  h.fill(0x20, 148, 156);
  numberInto(h, 148, 8, checksum(h));
  return h;
}

const padding = (size: number) => Buffer.alloc((BLOCK - (size % BLOCK)) % BLOCK);

/// prepare_header: a GNU long name ('L') or long link name ('K') entry, for what does not fit 100 bytes.
function* longEntry(kind: "L" | "K", value: Buffer): Generator<Buffer> {
  const data = Buffer.concat([value, Buffer.alloc(1)]);
  yield gnuHeader(Buffer.from("././@LongLink"), kind, { mode: 0o644, uid: 0, gid: 0, mtime: 0, size: data.length });
  yield data;
  yield padding(data.length);
}

/// The first 100 bytes of a name, cut back to whole UTF-8 characters (set_truncated_path_for_gnu_header).
function truncated(name: Buffer): Buffer {
  let end = Math.min(100, name.length);
  while (end > 0 && end < name.length && (name[end]! & 0xc0) === 0x80) end--;
  return name.subarray(0, end);
}

/// Builder::append_dir_all(".", dir) with follow_symlinks(false), then finish: `./` for the directory itself, then
/// everything under it as `a/b` (directories before what is in them), symlinks as links, special files as headers.
async function* tarOf(dir: string): AsyncGenerator<Buffer> {
  const stack: [string, string][] = [[dir, ""]];
  while (stack.length > 0) {
    const [path, rel] = stack.pop()!;
    const meta = await lstat(path, { bigint: true });
    const name = Buffer.from(rel === "" ? "./" : rel, "utf8");
    const common = (size: number): Meta => ({
      mode: Number(meta.mode),
      uid: Number(meta.uid),
      gid: Number(meta.gid),
      mtime: Math.max(0, Number(meta.mtimeMs / 1000n)),
      size,
    });
    const head = function* (kind: string, size: number, linkName?: Buffer, device?: [bigint, bigint]) {
      if (name.length > 100) yield* longEntry("L", name);
      if (linkName && linkName.length > 100) yield* longEntry("K", linkName);
      yield gnuHeader(name.length > 100 ? truncated(name) : name, kind, common(size), linkName && linkName.length > 100 ? truncated(linkName) : linkName, device);
    };
    if (meta.isDirectory()) {
      const children: Dirent[] = await readdir(path, { withFileTypes: true });
      for (const child of children) stack.push([join(path, child.name), rel === "" ? child.name : `${rel}/${child.name}`]);
      yield* head("5", 0);
    } else if (meta.isSymbolicLink()) {
      yield* head("2", 0, Buffer.from(await readlink(path), "utf8"));
    } else if (meta.isFile()) {
      const size = Number(meta.size);
      yield* head("0", size);
      let sent = 0;
      for await (const chunk of chunksOf(path, size)) {
        sent += chunk.length;
        yield chunk;
      }
      if (sent !== size) throw new Error(`${path} changed while archiving`);
      yield padding(size);
    } else if (meta.isSocket()) {
      throw new Error(`${path}: socket can not be archived`);
    } else {
      const kind = meta.isFIFO() ? "6" : meta.isCharacterDevice() ? "3" : meta.isBlockDevice() ? "4" : null;
      if (kind === null) throw new Error(`${path} has unknown file type`);
      const dev = meta.rdev;
      const major = ((dev >> 32n) & 0xfffff000n) | ((dev >> 8n) & 0x00000fffn);
      const minor = ((dev >> 12n) & 0xffffff00n) | (dev & 0x000000ffn);
      yield* head(kind, 0, undefined, [major, minor]);
    }
  }
  yield Buffer.alloc(2 * BLOCK);
}

/// Bytes pulled from a stream as they are needed.
class ByteReader {
  private chunks: Buffer[] = [];
  private have = 0;
  private ended = false;
  private readonly source: AsyncIterator<Buffer>;
  constructor(source: AsyncIterator<Buffer>) {
    this.source = source;
  }

  private async more(): Promise<boolean> {
    if (this.ended) return false;
    const next = await this.source.next();
    if (next.done) {
      this.ended = true;
      return false;
    }
    if (next.value.length > 0) {
      this.chunks.push(next.value);
      this.have += next.value.length;
    }
    return true;
  }

  /// Exactly `n` bytes; null at the very end, an error when it ends partway.
  async exact(n: number): Promise<Buffer | null> {
    while (this.have < n) {
      if (!(await this.more())) {
        if (this.have === 0) return null;
        throw new Error("unexpected end of archive");
      }
    }
    const out = Buffer.allocUnsafe(n);
    for (let at = 0; at < n; ) {
      const first = this.chunks[0]!;
      const take = Math.min(first.length, n - at);
      first.copy(out, at, 0, take);
      at += take;
      this.consume(take);
    }
    return out;
  }

  /// The next `n` bytes as they come; an error when it ends first.
  async *take(n: number): AsyncGenerator<Buffer> {
    while (n > 0) {
      if (this.have === 0 && !(await this.more())) throw new Error("unexpected end of archive");
      if (this.have === 0) continue;
      const first = this.chunks[0]!;
      const take = Math.min(first.length, n);
      const part = first.subarray(0, take);
      this.consume(take);
      n -= take;
      yield part;
    }
  }

  async skip(n: number) {
    for await (const _ of this.take(n));
  }

  /// Everything left read (the end of the zstd stream and its checksum).
  async drain() {
    this.chunks = [];
    this.have = 0;
    while (await this.more()) {
      this.chunks = [];
      this.have = 0;
    }
  }

  private consume(n: number) {
    const first = this.chunks[0]!;
    if (n === first.length) this.chunks.shift();
    else this.chunks[0] = first.subarray(n);
    this.have -= n;
  }
}

type EntryKind = "file" | "dir" | "symlink" | "hardlink" | "char" | "block" | "fifo" | "other";

type Entry = {
  /// The path's components ("." left out; a leading "/" when it had one).
  parts: string[];
  kind: EntryKind;
  mode: number;
  mtime: number;
  size: number;
  linkName: string | null;
  /// Its bytes, as they come (once).
  body(): AsyncGenerator<Buffer>;
  skip(): Promise<void>;
};

const nulEnded = (b: Buffer) => {
  const nul = b.indexOf(0);
  return nul < 0 ? b : b.subarray(0, nul);
};

const partsOf = (raw: Buffer): string[] => {
  const text = raw.toString("utf8");
  const parts = text.split("/").filter((p) => p !== "" && p !== ".");
  return text.startsWith("/") ? ["/", ...parts] : parts;
};

/// pax records ("<length> <key>=<value>\n") by key.
function paxRecords(data: Buffer): Map<string, Buffer> {
  const out = new Map<string, Buffer>();
  for (let rest = data; rest.length > 0; ) {
    const space = rest.indexOf(0x20);
    const len = space < 0 ? NaN : parseInt(rest.subarray(0, space).toString("latin1"), 10);
    if (!(len > space + 1) || len > rest.length) break;
    const record = rest.subarray(space + 1, len - 1);
    rest = rest.subarray(len);
    const eq = record.indexOf(0x3d);
    if (eq >= 0) out.set(record.subarray(0, eq).toString("latin1"), record.subarray(eq + 1));
  }
  return out;
}

/// Archive::entries: each entry named by the GNU long name or pax path before it, else its name (with the ustar prefix
/// for a ustar header); headers' checksums checked; the archive ends at a zero block. An entry's body not read is
/// skipped when the next is asked for.
async function* tarEntries(bytes: ByteReader): AsyncGenerator<Entry> {
  let longName: Buffer | null = null;
  let longLink: Buffer | null = null;
  let pax: Map<string, Buffer> | null = null;
  for (;;) {
    const h = await bytes.exact(BLOCK);
    if (h === null || h.every((x) => x === 0)) return;
    const sum = numberFrom(h.subarray(148, 156));
    if (sum !== checksum(h)) throw new Error("archive header checksum mismatch");
    const type = String.fromCharCode(h[156]!);
    let size = numberFrom(h.subarray(124, 136));
    const paxSize = pax?.get("size");
    if (paxSize !== undefined && type !== "x" && type !== "g" && type !== "L" && type !== "K") size = Number(paxSize.toString("latin1"));
    const pad = (BLOCK - (size % BLOCK)) % BLOCK;
    const read = async () => {
      const out: Buffer[] = [];
      for await (const chunk of bytes.take(size)) out.push(chunk);
      await bytes.skip(pad);
      return Buffer.concat(out);
    };
    if (type === "L") {
      longName = nulEnded(await read());
      continue;
    }
    if (type === "K") {
      longLink = nulEnded(await read());
      continue;
    }
    if (type === "x") {
      pax = paxRecords(await read());
      continue;
    }
    if (type === "g") {
      await read();
      continue;
    }
    const ustar = h.subarray(257, 263).toString("latin1") === "ustar\0";
    const prefix = ustar ? nulEnded(h.subarray(345, 500)) : Buffer.alloc(0);
    const name = nulEnded(h.subarray(0, 100));
    const raw = longName ?? pax?.get("path") ?? (prefix.length > 0 ? Buffer.concat([prefix, Buffer.from("/"), name]) : name);
    const link = longLink ?? pax?.get("linkpath") ?? nulEnded(h.subarray(157, 257));
    longName = longLink = pax = null;
    const kind: EntryKind =
      type === "0" || type === "\0" || type === "7"
        ? "file"
        : type === "5"
          ? "dir"
          : type === "2"
            ? "symlink"
            : type === "1"
              ? "hardlink"
              : type === "3"
                ? "char"
                : type === "4"
                  ? "block"
                  : type === "6"
                    ? "fifo"
                    : "other";
    let left = size;
    let padLeft = pad;
    const entry: Entry = {
      parts: partsOf(raw),
      kind,
      mode: numberFrom(h.subarray(100, 108)),
      mtime: numberFrom(h.subarray(136, 148)),
      size,
      linkName: kind === "symlink" || kind === "hardlink" ? link.toString("utf8") : null,
      async *body() {
        for await (const chunk of bytes.take(left)) {
          left -= chunk.length;
          yield chunk;
        }
      },
      async skip() {
        await bytes.skip(left);
        left = 0;
        await bytes.skip(padLeft);
        padLeft = 0;
      },
    };
    yield entry;
    await entry.skip();
  }
}

const execFileP = promisify(execFile);

/// Archive::unpack with preserve_permissions: entries with `..` skipped, a leading `/` dropped, nothing written through
/// a symlink out of `dest`; directories made last, deepest first, with their modes; files with their modes and
/// modification times.
async function unpack(entries: AsyncGenerator<Entry>, dest: string, refused: Refused): Promise<void> {
  const root = await realpath(dest);
  const dirs: { path: string; key: string; mode: number }[] = [];
  const inside = async (dir: string) => {
    const real = await realpath(dir);
    if (real !== root && !real.startsWith(root.endsWith(sep) ? root : `${root}${sep}`)) throw new Error(`trying to unpack outside of destination path: ${root}`);
  };
  for await (const entry of entries) {
    const parts = entry.parts.filter((p) => p !== "/");
    if (parts.length === 0 || parts.includes("..")) continue;
    const path = join(dest, ...parts);
    if (entry.kind === "dir") {
      dirs.push({ path, key: parts.join("/"), mode: entry.mode });
      continue;
    }
    if (entry.kind === "other") continue;
    await mkdir(dirname(path), { recursive: true });
    await inside(dirname(path));
    const replace = async <T>(make: () => Promise<T>): Promise<T> => {
      try {
        return await make();
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        await unlink(path);
        return make();
      }
    };
    if (entry.kind === "file") {
      const file = await replace(() => open(path, "wx", 0o600));
      try {
        for await (const chunk of entry.body()) await writeAll(file, chunk);
      } finally {
        await file.close();
      }
      const mtime = entry.mtime === 0 ? 1 : entry.mtime;
      await utimes(path, mtime, mtime);
      await chmod(path, entry.mode & 0o7777);
    } else if (entry.kind === "symlink") {
      await replace(async () => {
        if ((await symlinkOrStandIn(entry.linkName!, path, {})) === "refused") refused.set(path, entry.linkName!);
      });
    } else if (entry.kind === "hardlink") {
      const target = entry.linkName!.split("/").filter((p) => p !== "" && p !== ".");
      if (target.includes("..")) throw new Error(`hard link outside of destination path: ${entry.linkName}`);
      const from = join(dest, ...target);
      await inside(dirname(from));
      await replace(() => link(from, path));
    } else if (entry.kind === "fifo") {
      await replace(() => execFileP("mkfifo", ["-m", (entry.mode & 0o7777).toString(8), path]));
    } else {
      throw new Error(`cannot unpack a device file: ${parts.join("/")}`);
    }
  }
  dirs.sort((a, b) => Buffer.compare(Buffer.from(b.key), Buffer.from(a.key)));
  for (const dir of dirs) {
    const there = await lstatOrNull(dir.path);
    if (there && !there.isDirectory()) throw new Error(`${dir.key} is not a directory in the archive's tree`);
    if (!there) {
      await mkdir(dirname(dir.path), { recursive: true });
      await inside(dirname(dir.path));
      await mkdir(dir.path);
    }
    await chmod(dir.path, dir.mode & 0o7777);
  }
}
