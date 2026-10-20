// Sessions, threads and jobs as the pages read them (admin/mod.rs `route`): GET /sessions, /sessions/:key and its
// timeline, files and widget-state; GET /threads, /threads/:id; GET /jobs, /jobs/:id, /jobs/:id/log. As the Rust
// splits a path, its parts are those between slashes that are not empty, each percent-decoded (a `+` stays itself),
// and parts after the third do not count.
import { createReadStream } from "node:fs";
import { access, mkdir, open, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { type Answer, type Request, error, param, percentDecode } from "../request.ts";
import type { Route, Tools } from "../admin.ts";
import { ioMessage } from "../../read/sessions.ts";
import { dir as thumbsDir, thumbnail } from "../../sessions/thumbs.ts";
import { poster, wanted as wantedPoster } from "../../sessions/posters.ts";
import { withLock, workspaceFile } from "../../sessions/archive.ts";

/// admin/mod.rs `segment_decode`.
const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));
/// What the Rust answers a path it has no route for.
const noRoute = (r: Request) => error(404, `no route ${r.method} ${r.path}`);

/// What a file read (`sessionFile`) found: one on the disk (its path), an image whose thumbnail is to be made, or one
/// packed with its archived workspace.
type Found =
  | { contentType: string; file: string }
  | { contentType: string; image: string; thumbs: string }
  | { contentType: string; archived: { room: string; path: string; relative: string }; notFound: string };

const answered = (contentType: string, body: Answer["body"], extra: Record<string, string> = {}): Answer => ({
  status: 200,
  headers: { "content-type": contentType, "cache-control": "private, max-age=3600", ...extra },
  body,
});

/// A file on the disk as it goes out: read as it is sent once it is big, not taken into memory whole.
async function fromDisk(contentType: string, path: string): Promise<Answer> {
  try {
    const size = (await stat(path)).size;
    if (size <= STREAMED) return answered(contentType, await readFile(path));
    await access(path);
    return answered(contentType, createReadStream(path, { highWaterMark: 1 << 20 }) as AsyncIterable<Buffer>);
  } catch (e) {
    return error(500, ioMessage(e as NodeJS.ErrnoException));
  }
}
/// Over this a file is sent as it is read.
const STREAMED = 8 * 1024 * 1024;

/// The bytes of a file read (`sessionFile`), answered as files.rs does; an error as it came. An image whose thumbnail is
/// not made yet (`thumb=1`) has it made here, by the image codecs off this thread (sessions/thumbs.ts), and is answered
/// with it, or with the image itself when it gets none. One packed with its archived workspace is read out of the archive
/// here, under the room's lock (files.rs `session_file`; sessions/archive.ts).
async function file(read: Tools["read"], r: Request, args: unknown): Promise<Answer> {
  const answer = await read(r, "sessionFile", args);
  if (answer.status !== 200 || !Buffer.isBuffer(answer.body)) return answer;
  const found = JSON.parse(answer.body.toString("utf8")) as Found;
  if ("file" in found) return fromDisk(found.contentType, found.file);
  if ("archived" in found) {
    const { room, path, relative } = found.archived;
    // Restored meanwhile: it is back in its upload directory.
    const bytes = await withLock(room, async () => (await readFile(path).catch(() => null)) ?? workspaceFile(room, relative));
    return bytes === null ? error(404, found.notFound) : answered(found.contentType, bytes);
  }
  const made = await thumbnail(found.image, found.thumbs);
  return made !== null ? fromDisk(made.type, made.path) : fromDisk(found.contentType, found.image);
}

/// A file of a session on the disk, for a part of it or its poster: one packed with its archived workspace is put back
/// in its upload directory first (as sending it again does), so its parts are read from there. Its path and type, or the
/// answer to give instead.
async function onDisk(read: Tools["read"], r: Request, key: string, name: string): Promise<{ path: string; type: string } | Answer> {
  const answer = await read(r, "sessionFile", { key, name, thumb: false, lang: r.lang });
  if (answer.status !== 200 || !Buffer.isBuffer(answer.body)) return answer;
  const found = JSON.parse(answer.body.toString("utf8")) as Found;
  if ("file" in found) return { path: found.file, type: found.contentType };
  if ("archived" in found) {
    const { room, path, relative } = found.archived;
    const back = await withLock(room, async () => {
      if (await access(path).then(() => true, () => false)) return true;
      const bytes = await workspaceFile(room, relative);
      if (bytes === null) return false;
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, bytes);
      return true;
    });
    return back ? { path, type: found.contentType } : error(404, found.notFound);
  }
  return { path: found.image, type: found.contentType };
}

/// The most a part (GET /sessions/:key/parts) takes.
const MAX_PART = 8 * 1024 * 1024;

/// GET /sessions/:key/parts?name=&offset=&length=: `length` bytes of a file from `offset` (fewer at its end), with its
/// whole size (`stillfail-total`): a big file is fetched a part at a time, onto the disk, never all in memory.
async function part(read: Tools["read"], r: Request, key: string): Promise<Answer> {
  const num = (name: string, fallback: number) => {
    const v = param(r, name);
    return v === undefined ? fallback : /^[0-9]+$/.test(v) ? Number(v) : -1;
  };
  const offset = num("offset", 0);
  const length = num("length", MAX_PART);
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || length > MAX_PART) return error(400, "invalid offset or length");
  const found = await onDisk(read, r, key, param(r, "name") ?? "");
  if ("status" in found) return found;
  let handle;
  try {
    handle = await open(found.path, "r");
    const total = (await handle.stat()).size;
    const want = Math.max(0, Math.min(length, total - offset));
    const bytes = Buffer.alloc(want);
    let got = 0;
    while (got < want) {
      const { bytesRead } = await handle.read(bytes, got, want - got, offset + got);
      if (bytesRead === 0) break;
      got += bytesRead;
    }
    return answered(found.type, bytes.subarray(0, got), { "stillfail-total": String(total) });
  } catch (e) {
    return error(500, ioMessage(e as NodeJS.ErrnoException));
  } finally {
    await handle?.close();
  }
}

/// GET /sessions/:key/poster?name=: a video's poster (sessions/posters.ts), a JPEG; 404 when none can be made.
async function posterOf(read: Tools["read"], r: Request, key: string, dataDir: string | undefined): Promise<Answer> {
  const name = param(r, "name") ?? "";
  if (dataDir === undefined || !wantedPoster(name)) return error(404, "no poster");
  const found = await onDisk(read, r, key, name);
  if ("status" in found) return found;
  const made = await poster(found.path, thumbsDir(dataDir));
  return made === null ? error(404, "no poster") : fromDisk("image/jpeg", made);
}

export const routes = ({ read, agents }: Tools): Route[] => [
  {
    method: "GET",
    pattern: /^\/sessions$/,
    handle: (r) => read(r, "sessions", { connect: param(r, "connect") ?? null, archived: param(r, "archived") === "1", lang: r.lang }),
  },
  {
    method: "GET",
    pattern: /^\/*sessions\/+([^/]+)(?:\/+([^/]+))?(?:\/.*)?$/,
    handle: async (r, [rawKey, rawAction]) => {
      const key = segment(rawKey!);
      const action = rawAction === undefined ? undefined : segment(rawAction);
      if (action === undefined) return read(r, "session", { key, viewer: r.viewer, lang: r.lang });
      if (action === "timeline") return read(r, "timeline", { key, before: param(r, "before"), limit: param(r, "limit"), lang: r.lang });
      if (action === "files") return file(read, r, { key, name: param(r, "name") ?? "", thumb: param(r, "thumb") === "1", lang: r.lang });
      if (action === "parts") return part(read, r, key);
      if (action === "poster") return posterOf(read, r, key, agents?.hub.config().dataDir);
      if (action === "widget-state") return read(r, "widgetState", { key, path: param(r, "path"), lang: r.lang });
      return noRoute(r);
    },
  },
  { method: "GET", pattern: /^\/threads$/, handle: (r) => read(r, "threads", { viewer: r.viewer, session: param(r, "session") ?? null, lang: r.lang }) },
  {
    // GET /threads/:id/entries is the chats' (routes/chats.ts); any other action is none, once the thread is there.
    method: "GET",
    pattern: /^\/*threads\/+([^/]+)(?:\/+(?!entries(?:\/|$))([^/]+)(?:\/.*)?|\/*)$/,
    handle: async (r, [rawId, rawAction]) => {
      const id = segment(rawId!);
      const answer = await read(r, "thread", { id, viewer: r.viewer, lang: r.lang });
      if (rawAction === undefined || answer.status !== 200) return answer;
      if (segment(rawAction) === "entries") return read(r, "entries", { viewer: r.viewer, thread: Number(id), params: r.query });
      return noRoute(r);
    },
  },
  { method: "GET", pattern: /^\/jobs$/, handle: (r) => read(r, "openJobs", { viewer: r.viewer, lang: r.lang }) },
  {
    method: "GET",
    pattern: /^\/*jobs\/+([^/]+)(?:\/+([^/]+))?(?:\/.*)?$/,
    handle: async (r, [rawId, rawAction]) => {
      const id = segment(rawId!);
      const action = rawAction === undefined ? undefined : segment(rawAction);
      if (action === undefined) return read(r, "job", { id });
      if (action === "log") return read(r, "jobLog", { id, lines: param(r, "lines") });
      return noRoute(r);
    },
  },
];
