// VM archives: a tree packed as tar (gzip or zstd) and restored into a root no station runs on (see `makeWay`). The archive keeps links that stay inside its trees, git metadata and user files, and
// skips regenerable caches; an external or dangling link fails it rather than being dropped. Restoring refuses paths
// that escape the root or cross a link, and sets links and directory modes last. It syncs nothing itself: its caller
// makes the whole root durable once, when every entry is in place (durable-archive.ts `restoreBeforeStart`). Sizes are
// bounded per file and in total.
import { closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readSync, readdirSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, unlinkSync, writeSync, chmodSync, type Dirent, type Stats } from "node:fs";
import { basename, dirname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { PassThrough, type Readable, type Writable } from "node:stream";
import { createGunzip, createGzip, createZstdCompress, createZstdDecompress, constants as zlib } from "node:zlib";
import { Effect } from "effect";
import { ARCHIVE_HOME_CACHE_DIRS, ARCHIVE_HOME_CACHE_FILES } from "./archive-caches.ts";

export const MAX_ARCHIVE_FILE = 32 * 1024 * 1024;
export const MIGRATION_BYTE_LIMIT = 16 * 1024 * 1024 * 1024;

export type ArchiveCodec = "gzip" | "zstd";
/** A source root and the archive prefix its entries go under. */
export type ArchiveTree = { source: string; prefix: string };

/** Universal regenerable directory names: generic ones (bin, obj, Library) are project-specific and stay. */
export const WORKSPACE_ARCHIVE_SKIP_DIRS = new Set([
  ".angular", ".expo", ".metro", ".turbo", ".next", ".nuxt", ".cache", ".elixir-tools", ".elixir_ls", ".lexical", ".xwin-cache", ".build",
  "DerivedData", "__pycache__", "__pypackages__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", ".pixi", ".ipynb_checkpoints",
  ".gradle", ".stack-work", "zig-cache", ".zig-cache", "cmake-build-debug", "cmake-build-release", ".godot-cache", ".dart_tool", ".parcel-cache",
  ".vite", ".svelte-kit", ".cxx", ".externalNativeBuild", ".kotlin", "CMakeFiles",
]);

/** What an archive owner adds: paths it keeps out, entries it writes first, and what it does with entries it owns. */
export type ArchiveHooks = {
  /** An absolute (canonical) path that never enters the archive as it is. */
  exclude?(path: string, isDirectory: boolean): boolean;
  /** Entries written before the trees (a scope projection). */
  leading?: Array<{ name: string; body: Buffer }>;
  /** Entries written after the trees, within the remaining expanded budget (a state snapshot): a body, or a file. */
  trailing?(remaining: number): Effect.Effect<Array<{ name: string; body?: Buffer; file?: string }>, Error>;
  /** A link that leads outside the trees is left out (named here), not a failure: what it leads to is not archived. */
  outsideLink?(rel: string): void;
};

export type RestoreHooks = {
  /** An entry the owner takes over (its body is handed to it, not written); a thrown error fails the restore. */
  take?(name: string, body: Buffer): boolean;
  /** Whether the owner takes an entry: consulted before its body is read. */
  owns?(name: string): boolean;
  /** An entry (by its path under the root) that is not restored: neither written nor an error. */
  leaveOut?(name: string): boolean;
  /** Refuses an entry (it would overwrite live state). */
  refuse?(target: string): string | null;
  /** After every entry is in place. */
  finish?(): Effect.Effect<void, Error>;
};

const fail = (message: string) => new Error(message);
const inPath = (path: string, root: string) => {
  const rel = relative(root, path);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
};
const toSlash = (path: string) => path.split(sep).join("/");

/** Whether an archive path is a regenerable cache under the VM's home or a session workspace. */
export function skipRegenerableArchiveCache(path: string, isDirectory: boolean, name: string): boolean {
  const clean = toSlash(normalize(path)).replace(/^\.\//, "");
  const home = ".salix/sprite-home/";
  const connectorHome = `${home}.local/share/salix/connector-home/`;
  for (const root of [home, connectorHome]) {
    if (!clean.startsWith(root)) continue;
    const rel = clean.slice(root.length);
    if (isDirectory && ARCHIVE_HOME_CACHE_DIRS.has(rel)) return true;
    if (!isDirectory && ARCHIVE_HOME_CACHE_FILES.has(rel)) return true;
  }
  if (!isDirectory) return false;
  const workspaces = `${connectorHome}.comma/workspaces/`;
  if (!clean.startsWith(workspaces)) return false;
  const parts = clean.slice(workspaces.length).split("/");
  if (parts.length < 2 || parts.slice(1).includes(".git")) return false;
  // Installation environments may hold local edits or user files.
  if ([".tox", ".nox", ".pixi", "__pypackages__"].includes(name)) return false;
  return WORKSPACE_ARCHIVE_SKIP_DIRS.has(name);
}

// Tar, ustar with PAX records for long names.

function octal(value: number, width: number): string {
  return `${value.toString(8).padStart(width - 1, "0")}\0`;
}

function header(name: string, type: string, options: { mode: number; size: number; mtime: number; linkname?: string; uid?: number; gid?: number }): Buffer {
  const block = Buffer.alloc(512);
  block.write(name, 0, 100, "utf8");
  block.write(octal(options.mode & 0o7777, 8), 100, "ascii");
  block.write(octal(options.uid ?? 0, 8), 108, "ascii");
  block.write(octal(options.gid ?? 0, 8), 116, "ascii");
  block.write(octal(options.size, 12), 124, "ascii");
  block.write(octal(Math.max(0, Math.floor(options.mtime)), 12), 136, "ascii");
  block.write("        ", 148, "ascii");
  block.write(type, 156, "ascii");
  if (options.linkname) block.write(options.linkname, 157, 100, "utf8");
  block.write("ustar\0", 257, "ascii");
  block.write("00", 263, "ascii");
  let sum = 0;
  for (const byte of block) sum += byte;
  block.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, "ascii");
  return block;
}

function paxRecord(key: string, value: string): string {
  const body = ` ${key}=${value}\n`;
  let length = Buffer.byteLength(body) + 1;
  while (Buffer.byteLength(`${length}${body}`) !== length) length = Buffer.byteLength(`${length}${body}`);
  return `${length}${body}`;
}

const padding = (size: number) => Buffer.alloc((512 - (size % 512)) % 512);

/** The blocks for one entry's header (with a PAX header first when a name does not fit). */
function entryHeader(name: string, type: string, options: { mode: number; size: number; mtime: number; linkname?: string; uid?: number; gid?: number }): Buffer[] {
  const records: string[] = [];
  if (Buffer.byteLength(name) > 100) records.push(paxRecord("path", name));
  if (options.linkname && Buffer.byteLength(options.linkname) > 100) records.push(paxRecord("linkpath", options.linkname));
  if (!records.length) return [header(name, type, options)];
  const pax = Buffer.from(records.join(""));
  const short = name.slice(0, 99);
  return [header(`PaxHeaders/${short}`.slice(0, 99), "x", { mode: 0o644, size: pax.length, mtime: options.mtime }), pax, padding(pax.length), header(short, type, { ...options, linkname: options.linkname?.slice(0, 99) })];
}

/** A writable sink that respects backpressure. */
function writer(stream: Writable) {
  return (chunk: Buffer): Effect.Effect<void, Error> =>
    Effect.callback<void, Error>((resume) => {
      if (stream.destroyed) return resume(Effect.fail(fail("archive stream closed")));
      const ok = stream.write(chunk, (error) => error && resume(Effect.fail(error)));
      if (ok) return resume(Effect.void);
      const onDrain = () => {
        stream.off("error", onError);
        resume(Effect.void);
      };
      const onError = (error: Error) => {
        stream.off("drain", onDrain);
        resume(Effect.fail(error));
      };
      stream.once("drain", onDrain);
      stream.once("error", onError);
    });
}

/** Where a link's target lands in the archive: resolved through existing parents, inside one of the trees. */
function archiveLinkTarget(path: string): string {
  try {
    return realpathSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  let link = readlinkSync(path);
  if (!isAbsolute(link)) link = join(dirname(path), link);
  // Resolve existing parents before mapping an absent target; a dangling intermediate link stays an error.
  let suffix = "";
  while (true) {
    try {
      return join(realpathSync(link), suffix);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      let exists = true;
      try {
        lstatSync(link);
      } catch {
        exists = false;
      }
      if (exists) throw error;
      suffix = join(link.slice(dirname(link).length + 1), suffix);
      link = dirname(link);
    }
  }
}

const OUTSIDE_ROOTS = "archive path is outside the selected source roots";

function treeDestination(trees: ArchiveTree[], path: string): string {
  for (const tree of trees) if (inPath(path, tree.source)) return join(tree.prefix, relative(tree.source, path));
  throw fail(OUTSIDE_ROOTS);
}

/** Writes `trees` as a compressed tar to `out`, then ends it. */
export function writeTarTrees(out: Writable, trees: ArchiveTree[], options: { codec: ArchiveCodec; fileLimit?: number; hooks?: ArchiveHooks; signal?: AbortSignal }): Effect.Effect<void, Error> {
  return Effect.gen(function* () {
    const fileLimit = options.fileLimit ?? MAX_ARCHIVE_FILE;
    const hooks = options.hooks ?? {};
    const resolved = yield* Effect.try({ try: () => trees.map((tree) => ({ source: realpathSync(tree.source), prefix: tree.prefix })), catch: (e) => e as Error });
    const compressor =
      options.codec === "gzip" ? createGzip() : createZstdCompress({ params: { [zlib.ZSTD_c_compressionLevel]: 1, [zlib.ZSTD_c_nbWorkers]: 0 } });
    compressor.pipe(out);
    const outError = new Promise<Error>((resolve) => {
      out.once("error", resolve);
      compressor.once("error", resolve);
    });
    const write = writer(compressor);
    const seen = new Set<string>();
    let expanded = 0;
    const aborted = () => options.signal?.aborted === true;

    const emit = (name: string, body: Buffer) =>
      Effect.gen(function* () {
        if (seen.has(name)) return yield* Effect.fail(fail("selected roots contain colliding archive paths"));
        seen.add(name);
        for (const block of entryHeader(name, "0", { mode: 0o600, size: body.length, mtime: 0 })) yield* write(block);
        yield* write(body);
        yield* write(padding(body.length));
      });

    for (const entry of hooks.leading ?? []) yield* emit(entry.name, entry.body);

    const visit = (tree: ArchiveTree, path: string, entry: Dirent | null): Effect.Effect<void, Error> =>
      Effect.gen(function* () {
        if (aborted()) return yield* Effect.fail(fail("archive cancelled"));
        const rel = relative(tree.source, path);
        const name = toSlash(join(tree.prefix, rel)).replace(/^\.\//, "");
        // A file a running process removed after its directory was read is gone, not an error (as GNU tar).
        const info: Stats | null = yield* Effect.try({ try: () => lstatOrNull(path), catch: (e) => e as Error });
        if (!info) return;
        const isDirectory = info.isDirectory();
        if (hooks.exclude?.(path, isDirectory)) return;
        if (entry && skipRegenerableArchiveCache(name, isDirectory, entry.name)) return;
        let linkname = "";
        if (info.isSymbolicLink()) {
          const destination = yield* Effect.try({ try: () => treeDestination(resolved, archiveLinkTarget(path)), catch: (e) => e as Error }).pipe(
            Effect.catch((error: Error) =>
              hooks.outsideLink && error.message === OUTSIDE_ROOTS
                ? Effect.sync(() => (hooks.outsideLink!(rel), null))
                : Effect.fail(new Error(`${error.message}: ${rel}`)),
            ),
          );
          if (destination === null) return;
          linkname = toSlash(relative(dirname(join(tree.prefix, rel)), destination));
        } else if (!isDirectory && !info.isFile()) {
          // A socket, pipe or device is a running process's endpoint, not data: nothing to carry to another machine.
          if (info.isSocket() || info.isFIFO() || info.isBlockDevice() || info.isCharacterDevice()) return;
          return yield* Effect.fail(fail(`unsupported archive entry: ${rel}`));
        }
        if (info.isFile()) {
          if (info.size > fileLimit) return yield* Effect.fail(fail(`archive file too large: ${rel}`));
          if (info.size > MIGRATION_BYTE_LIMIT - expanded) return yield* Effect.fail(fail("archive expanded size exceeds limit"));
          expanded += info.size;
        }
        if (seen.has(name)) return yield* Effect.fail(fail("selected roots contain colliding archive paths"));
        seen.add(name);
        const mode = info.mode & 0o7777;
        const mtime = info.mtimeMs / 1000;
        if (isDirectory) {
          for (const block of entryHeader(`${name}/`, "5", { mode, size: 0, mtime, uid: info.uid, gid: info.gid })) yield* write(block);
          const children = yield* Effect.try({ try: () => readdirOrEmpty(path), catch: (e) => e as Error });
          for (const child of children) yield* visit(tree, join(path, child.name), child);
          return;
        }
        if (linkname) {
          for (const block of entryHeader(name, "2", { mode, size: 0, mtime, linkname, uid: info.uid, gid: info.gid })) yield* write(block);
          return;
        }
        const fd = yield* Effect.try({ try: () => openOrNull(path), catch: (e) => e as Error });
        if (fd === null) return;
        yield* Effect.acquireUseRelease(
          Effect.succeed(fd),
          () =>
            Effect.gen(function* () {
              for (const block of entryHeader(name, "0", { mode, size: info.size, mtime, uid: info.uid, gid: info.gid })) yield* write(block);
              yield* copyFile(fd, info.size, write, aborted);
              yield* write(padding(info.size));
            }),
          () => Effect.sync(() => closeSync(fd)),
        );
      });

    for (const tree of resolved) {
      const children = yield* Effect.try({ try: () => readdirSync(tree.source, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)), catch: (e) => e as Error });
      for (const child of children) yield* visit(tree, join(tree.source, child.name), child);
    }
    if (hooks.trailing) {
      for (const entry of yield* hooks.trailing(MIGRATION_BYTE_LIMIT - expanded)) {
        if (entry.body) {
          yield* emit(entry.name, entry.body);
          continue;
        }
        if (!entry.file) continue;
        const size = yield* Effect.try({ try: () => lstatSync(entry.file!).size, catch: (e) => e as Error });
        if (seen.has(entry.name)) return yield* Effect.fail(fail("selected roots contain colliding archive paths"));
        seen.add(entry.name);
        for (const block of entryHeader(entry.name, "0", { mode: 0o600, size, mtime: 0 })) yield* write(block);
        yield* Effect.acquireUseRelease(
          Effect.try({ try: () => openSync(entry.file!, constants.O_RDONLY | constants.O_NOFOLLOW), catch: (e) => e as Error }),
          (fd) => copyFile(fd, size, write, aborted),
          (fd) => Effect.sync(() => closeSync(fd)),
        );
        yield* write(padding(size));
      }
    }
    yield* write(Buffer.alloc(1024));
    yield* Effect.raceFirst(
      Effect.promise(() => new Promise<void>((resolve) => (out.writableFinished ? resolve() : (out.once("finish", () => resolve()), out.once("close", () => resolve()), compressor.end())))),
      Effect.promise(() => outError).pipe(Effect.flatMap((e) => Effect.fail(e))),
    );
  });
}

const lstatOrNull = (path: string): Stats | null => {
  try {
    return lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
};
const readdirOrEmpty = (path: string): Dirent[] => {
  try {
    return readdirSync(path, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
};
const openOrNull = (path: string): number | null => {
  try {
    return openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
};

/**
 * Copies `size` bytes of an open file. A running process may still write it: bytes it appended are left out, and a file
 * it truncated is padded with zeros to the size its header promised (as GNU tar).
 */
function copyFile(fd: number, size: number, write: (chunk: Buffer) => Effect.Effect<void, Error>, aborted: () => boolean): Effect.Effect<void, Error> {
  return Effect.gen(function* () {
    const buffer = Buffer.alloc(256 * 1024);
    let left = size;
    while (left > 0) {
      if (aborted()) return yield* Effect.fail(fail("archive cancelled"));
      const n = readSync(fd, buffer, 0, Math.min(buffer.length, left), null);
      if (n === 0) {
        for (; left > 0; left -= Math.min(buffer.length, left)) yield* write(Buffer.alloc(Math.min(buffer.length, left)));
        return;
      }
      left -= n;
      yield* write(Buffer.from(buffer.subarray(0, n)));
    }
  });
}

/** A whole tree as a gzipped tar in memory (small trees and tests). */
export function writeTarGz(root: string, hooks?: ArchiveHooks): Effect.Effect<Buffer, Error> {
  return Effect.suspend(() => {
    const sink = new PassThrough();
    const chunks: Buffer[] = [];
    sink.on("data", (chunk: Buffer) => chunks.push(chunk));
    return writeTarTrees(sink, [{ source: root, prefix: "." }], { codec: "gzip", hooks }).pipe(Effect.map(() => Buffer.concat(chunks)));
  });
}

// Restore.

type Header = { name: string; type: string; mode: number; size: number; linkname: string };

/** Reads tar entries from a decompressed stream: each entry's body is read (bounded) or skipped before the next. */
class TarReader {
  private buffered: Buffer[] = [];
  private length = 0;
  private ended = false;
  private readonly iterator: AsyncIterator<Buffer>;
  constructor(stream: Readable) {
    this.iterator = (stream as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  }
  private async fill(n: number): Promise<boolean> {
    while (this.length < n && !this.ended) {
      const next = await this.iterator.next();
      if (next.done) this.ended = true;
      else {
        this.buffered.push(next.value);
        this.length += next.value.length;
      }
    }
    return this.length >= n;
  }
  private take(n: number): Buffer {
    const joined = this.buffered.length === 1 ? this.buffered[0] : Buffer.concat(this.buffered);
    const out = joined.subarray(0, n);
    const rest = joined.subarray(n);
    this.buffered = rest.length ? [rest] : [];
    this.length = rest.length;
    return out;
  }
  async read(n: number): Promise<Buffer> {
    if (!(await this.fill(n))) throw fail("unexpected EOF");
    return Buffer.from(this.take(n));
  }
  /** Streams `n` bytes to `sink` in chunks. */
  async pipe(n: number, sink: (chunk: Buffer) => void): Promise<void> {
    let left = n;
    while (left > 0) {
      if (!(await this.fill(1))) throw fail("unexpected EOF");
      const chunk = this.take(Math.min(left, this.length, 1024 * 1024));
      sink(chunk);
      left -= chunk.length;
    }
  }
  async next(): Promise<Header | null> {
    let pax: Record<string, string> = {};
    let longName = "";
    let longLink = "";
    while (true) {
      if (!(await this.fill(512))) {
        if (this.length === 0) return null;
        throw fail("unexpected EOF");
      }
      const block = this.take(512);
      if (block.every((b) => b === 0)) return null;
      const field = (start: number, length: number) => {
        const raw = block.subarray(start, start + length);
        const end = raw.indexOf(0);
        return raw.subarray(0, end < 0 ? length : end).toString("utf8");
      };
      const number = (start: number, length: number) => {
        if (block[start] & 0x80) {
          let value = 0;
          for (let i = start + 1; i < start + length; i++) value = value * 256 + block[i];
          return value;
        }
        const text = field(start, length).trim();
        return text ? Number.parseInt(text, 8) : 0;
      };
      let sum = 0;
      for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : block[i];
      if (sum !== number(148, 8)) throw fail("archive/tar: invalid tar header");
      const type = field(156, 1) || "0";
      const size = number(124, 12);
      const prefix = field(257, 6).startsWith("ustar") ? field(345, 155) : "";
      let name = prefix ? `${prefix}/${field(0, 100)}` : field(0, 100);
      let linkname = field(157, 100);
      if (type === "x" || type === "g" || type === "L" || type === "K") {
        if (size > 1024 * 1024) throw fail("archive/tar: header too large");
        const body = await this.read(size);
        await this.read((512 - (size % 512)) % 512);
        if (type === "x") pax = { ...pax, ...parsePax(body) };
        if (type === "L") longName = body.toString("utf8").replace(/\0+$/, "");
        if (type === "K") longLink = body.toString("utf8").replace(/\0+$/, "");
        continue;
      }
      if (longName) name = longName;
      if (longLink) linkname = longLink;
      if (pax.path) name = pax.path;
      if (pax.linkpath) linkname = pax.linkpath;
      const paxSize = pax.size !== undefined ? Number(pax.size) : size;
      return { name, type, mode: number(100, 8), size: paxSize, linkname };
    }
  }
  async skipPadding(size: number) {
    const pad = (512 - (size % 512)) % 512;
    if (pad) await this.read(pad);
  }
}

function parsePax(body: Buffer): Record<string, string> {
  const records: Record<string, string> = {};
  let offset = 0;
  while (offset < body.length) {
    const space = body.indexOf(32, offset);
    if (space < 0) break;
    const length = Number.parseInt(body.subarray(offset, space).toString("ascii"), 10);
    if (!Number.isFinite(length) || length <= 0) throw fail("archive/tar: invalid PAX record");
    const record = body.subarray(space + 1, offset + length - 1).toString("utf8");
    const equals = record.indexOf("=");
    if (equals > 0) records[record.slice(0, equals)] = record.slice(equals + 1);
    offset += length;
  }
  return records;
}

export function safeArchiveTarget(root: string, name: string): string {
  const clean = normalize(name);
  if (clean === "." || clean === "./" || clean === ".." || clean.startsWith(`..${sep}`) || isAbsolute(clean)) throw fail(`archive path escapes workspace: ${name}`);
  const target = join(root, clean);
  if (!inPath(target, root) || target === root) throw fail(`archive path escapes workspace: ${name}`);
  return target.replace(/\/+$/, "");
}

function rejectExistingSymlink(path: string) {
  try {
    if (lstatSync(path).isSymbolicLink()) throw fail(`archive path crosses symlink: ${path}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function ensureSafeArchiveParent(root: string, target: string) {
  const rel = relative(root, dirname(target));
  if (!rel) return;
  let current = root;
  for (const part of rel.split(sep)) {
    current = join(current, part);
    let info: Stats | null = null;
    try {
      info = lstatSync(current);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (info) {
      if (info.isSymbolicLink()) throw fail(`archive path crosses symlink: ${current}`);
      if (!info.isDirectory()) throw fail(`archive path parent is not a directory: ${current}`);
      continue;
    }
    try {
      mkdirSync(current, 0o755);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
    rejectExistingSymlink(current);
  }
}

function rejectSymlinkPath(root: string, target: string) {
  ensureSafeArchiveParent(root, target);
  rejectExistingSymlink(target);
}

/**
 * Clears `target` for an archive entry of `kind`. The archive, being the Workload's state, takes its paths. A
 * Workload's restore lands on a disk no station has started on (durable-archive.ts `restoreBeforeStart`); what is there
 * all the same (the image's, or what a start seeds: jobs/bin's command and the link of its former name, agent home
 * links, keys and settings) gives way. A file or link in the way is removed, never followed; a directory stays for a
 * directory. A directory in the way of a file or link is refused: removing a tree is not a restore's to do.
 */
function makeWay(target: string, kind: "directory" | "file") {
  const info = lstatOrNull(target);
  if (!info || (kind === "directory" ? info.isDirectory() : info.isFile())) return;
  if (info.isDirectory()) throw fail(`archive entry would replace a directory: ${target}`);
  unlinkSync(target);
}

/**
 * Makes the archive's link at `target`. A link already there to the same place (as the station's start made it,
 * relative or absolute) stays as it is. A different link or a file is replaced at once by the archive's link (made
 * aside, then renamed over it); the next start sets its own links again as it does on every start.
 */
function placeLink(linkname: string, target: string) {
  const info = lstatOrNull(target);
  if (!info) return void symlinkSync(linkname, target);
  if (info.isDirectory()) throw fail(`archive link would replace a directory: ${target}`);
  if (info.isSymbolicLink() && resolve(dirname(target), readlinkSync(target)) === resolve(dirname(target), linkname)) return;
  const aside = join(dirname(target), `.${basename(target)}.restore-${process.pid}`);
  rmSync(aside, { force: true });
  symlinkSync(linkname, aside);
  renameSync(aside, target);
}

/** What a restore put in place: every entry (directories, files and links), and of them the files. */
export type RestoreCount = { entries: number; files: number };

/**
 * Restores a compressed tar from `input` into `root`. Nothing is synced here: a file's bytes and a directory's entries
 * reach the disk when its caller syncs the root (a restore's disk is new, and one that failed is not used again).
 */
export function restoreTar(input: Readable, root: string, options: { codec: ArchiveCodec; fileLimit?: number; hooks?: RestoreHooks }): Effect.Effect<RestoreCount, Error> {
  return Effect.gen(function* () {
    const fileLimit = options.fileLimit ?? MAX_ARCHIVE_FILE;
    const hooks = options.hooks ?? {};
    const base = yield* Effect.try({ try: () => realpathSync(root), catch: (e) => e as Error });
    const decompressor = options.codec === "gzip" ? createGunzip() : createZstdDecompress();
    input.on("error", (error) => decompressor.destroy(error));
    input.pipe(decompressor);
    const reader = new TarReader(decompressor);
    const count: RestoreCount = { entries: 0, files: 0 };
    yield* Effect.tryPromise({
      try: async () => {
        const links: Header[] = [];
        const directories: Header[] = [];
        let expanded = 0;
        while (true) {
          const entry = await reader.next();
          if (!entry) break;
          if (entry.size < 0 || entry.size > MIGRATION_BYTE_LIMIT - expanded) throw fail("archive expanded size limit exceeded");
          expanded += entry.size;
          const target = safeArchiveTarget(base, entry.name);
          const rel = toSlash(relative(base, target));
          if (hooks.owns?.(rel)) {
            if (entry.type !== "0" && entry.type !== "\0") throw fail(`invalid archive entry: ${rel}`);
            if (entry.size > fileLimit) throw fail(`archive file too large: ${entry.name}`);
            const body = await reader.read(entry.size);
            await reader.skipPadding(entry.size);
            hooks.take?.(rel, body);
            continue;
          }
          if (hooks.leaveOut?.(rel)) {
            await reader.pipe(entry.size, () => {});
            await reader.skipPadding(entry.size);
            continue;
          }
          const refused = hooks.refuse?.(target);
          if (refused) throw fail(refused);
          switch (entry.type) {
            case "5":
              ensureSafeArchiveParent(base, target);
              makeWay(target, "directory");
              mkdirSync(target, { recursive: true, mode: 0o700 });
              directories.push(entry);
              count.entries++;
              break;
            case "0":
            case "\0":
            case "7": {
              if (entry.size > fileLimit) throw fail(`archive file too large: ${entry.name}`);
              ensureSafeArchiveParent(base, target);
              makeWay(target, "file");
              const fd = openSync(target, constants.O_CREAT | constants.O_WRONLY | constants.O_TRUNC | constants.O_NOFOLLOW, entry.mode & 0o777);
              try {
                await reader.pipe(entry.size, (chunk) => {
                  let offset = 0;
                  while (offset < chunk.length) offset += writeSync(fd, chunk, offset);
                });
                await reader.skipPadding(entry.size);
                if ((fstatSync(fd).mode & 0o777) !== (entry.mode & 0o777)) chmodSync(target, entry.mode & 0o777);
              } finally {
                closeSync(fd);
              }
              count.entries++;
              count.files++;
              break;
            }
            case "2":
              links.push(entry);
              break;
            case "1":
              throw fail(`archive hard links are not supported: ${entry.name}`);
            default:
              throw fail(`unsupported archive entry: ${entry.name}`);
          }
          if (entry.type !== "0" && entry.type !== "\0" && entry.type !== "7" && entry.size > 0) {
            await reader.pipe(entry.size, () => {});
            await reader.skipPadding(entry.size);
          }
        }
        for (const link of links) {
          const target = safeArchiveTarget(base, link.name);
          if (isAbsolute(link.linkname)) throw fail(`archive link escapes workspace: ${link.name}`);
          let resolved: string;
          try {
            resolved = safeArchiveTarget(base, join(dirname(link.name), link.linkname));
          } catch {
            throw fail(`archive link escapes workspace: ${link.name}`);
          }
          rejectSymlinkPath(base, resolved);
          // A retained link may point at an omitted cache: it is restored even when its target is absent.
          ensureSafeArchiveParent(base, target);
          placeLink(link.linkname, target);
          count.entries++;
        }
        for (const directory of directories.reverse()) {
          const target = safeArchiveTarget(base, directory.name);
          rejectSymlinkPath(base, target);
          chmodSync(target, directory.mode & 0o777);
        }
      },
      catch: (e) => (e instanceof Error ? e : new Error(String(e))),
    });
    if (hooks.finish) yield* hooks.finish();
    return count;
  });
}

/** Restores a gzipped tar held in memory. */
export function restoreTarGz(archive: Buffer, root: string, hooks?: RestoreHooks): Effect.Effect<RestoreCount, Error> {
  return Effect.suspend(() => {
    const input = new PassThrough();
    input.end(archive);
    return restoreTar(input, root, { codec: "gzip", hooks });
  });
}
