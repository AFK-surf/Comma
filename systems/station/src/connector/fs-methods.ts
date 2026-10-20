// Workspace file methods: read, write, delete, stat, list, glob, grep, read_stream and write_stream. Paths resolve
// against the connector root (absolute paths are taken as given, as the Go connector did).
import { constants } from "node:fs";
import { mkdir, open, readdir, rm, stat, unlink } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { Effect } from "effect";
import { openWritable, readLimited } from "./fs-io.ts";
import { type Message, boolParam, defaultString, intParam, stringParam } from "./message.ts";
import type { Session } from "./session.ts";

export const MAX_OUTPUT_BYTES = 64 * 1024;
export const MAX_FILE_BYTES = 10 * 1024 * 1024;
export const READ_STREAM_CHUNK = 64 * 1024;

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));
const attempt = <A>(f: () => Promise<A>) => Effect.tryPromise({ try: f, catch: toError });

export function resolvePath(root: string, path: string): string {
  const full = path === "" ? "." : path;
  return resolve(isAbsolute(full) ? full : join(root, full));
}

export function pathInsideRoot(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

/** Go's filepath.Match for one pattern against one name (`*`, `?`, `[...]`, `\` escapes; `*` never crosses `/`). */
export function globMatch(pattern: string, name: string): boolean {
  let re = "^";
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === "*") re += "[^/]*";
    else if (ch === "?") re += "[^/]";
    else if (ch === "[") {
      const end = pattern.indexOf("]", i + 1);
      if (end < 0) return false;
      let body = pattern.slice(i + 1, end);
      if (body.startsWith("^")) body = `^${body.slice(1)}`;
      re += `[${body.replace(/\\/g, "\\\\")}]`;
      i = end;
    } else if (ch === "\\" && i + 1 < pattern.length) re += escapeRegex(pattern[++i]);
    else re += escapeRegex(ch);
  }
  try {
    return new RegExp(`${re}$`).test(name);
  } catch {
    return false;
  }
}

const escapeRegex = (s: string) => s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

/** Splits keeping each line's terminator, as Go's strings.SplitAfter(text, "\n") without the empty tail. */
function splitLinesAfter(text: string): string[] {
  const lines: string[] = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\n") {
      lines.push(text.slice(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) lines.push(text.slice(start));
  return lines;
}

export function makeFsMethods(root: () => string) {
  const resolveIn = (path: string) => resolvePath(root(), path);
  const displayPath = (path: string) => {
    const rel = relative(root(), path);
    if (rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`)) return `/${rel.split(sep).join("/")}`;
    return path.split(sep).join("/");
  };

  async function* walkFiles(base: string): AsyncGenerator<string> {
    let entries;
    try {
      entries = await readdir(base, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entry of entries) {
      const full = join(base, entry.name);
      if (entry.isDirectory()) yield* walkFiles(full);
      else yield full;
    }
  }

  return {
    displayPath,
    read: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(stringParam(params, "path"));
        const data = yield* readLimited(full, MAX_FILE_BYTES + 1);
        const truncated = data.length > MAX_FILE_BYTES;
        const bytes = truncated ? data.subarray(0, MAX_FILE_BYTES) : data;
        let text = bytes.toString("utf8");
        const offset = intParam(params, "offset", 0);
        const limit = intParam(params, "limit", 0);
        if (offset > 0 || limit > 0) {
          const lines = splitLinesAfter(text);
          let end = lines.length;
          if (limit > 0 && offset + limit < end) end = offset + limit;
          text = offset > lines.length ? "" : lines.slice(offset, end).join("");
        }
        return { content: text, size: bytes.length, truncated };
      }),
    write: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(stringParam(params, "path"));
        const raw = Buffer.from(stringParam(params, "content"));
        if (raw.length > MAX_FILE_BYTES) return yield* Effect.fail(new Error("content exceeds 10MB cap"));
        yield* attempt(() => mkdir(dirname(full), { recursive: true, mode: 0o755 }));
        const file = yield* openWritable(full, stringParam(params, "mode") === "append");
        yield* file.write(raw).pipe(Effect.ensuring(file.close));
        return { size: raw.length };
      }),
    delete: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(stringParam(params, "path"));
        if (boolParam(params, "recursive")) yield* attempt(() => rm(full, { recursive: true, force: true }));
        else
          yield* attempt(async () => {
            const info = await stat(full);
            if (info.isDirectory()) await import("node:fs/promises").then((fs) => fs.rmdir(full));
            else await unlink(full);
          });
        return { deleted: true };
      }),
    stat: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(stringParam(params, "path"));
        const info = yield* attempt(() => stat(full));
        return {
          path: stringParam(params, "path"),
          kind: info.isDirectory() ? "dir" : "file",
          size: info.size,
          mode: `0${(info.mode & 0o777).toString(8)}`,
          modified_at: Math.floor(info.mtimeMs / 1000),
        };
      }),
    list: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(defaultString(stringParam(params, "path"), "."));
        const entries = yield* attempt(() => readdir(full, { withFileTypes: true }));
        const out: Array<Record<string, unknown>> = [];
        for (const entry of entries) {
          const info = yield* attempt(() => stat(join(full, entry.name))).pipe(Effect.option);
          if (info._tag === "None") continue;
          out.push({ name: entry.name, kind: info.value.isDirectory() ? "dir" : "file", size: info.value.size, modified_at: Math.floor(info.value.mtimeMs / 1000) });
        }
        out.sort((a, b) => ((a.name as string) < (b.name as string) ? -1 : 1));
        return { entries: out };
      }),
    glob: (params: Record<string, unknown>) =>
      attempt(async () => {
        const base = resolveIn(defaultString(stringParam(params, "path"), "."));
        const pattern = defaultString(stringParam(params, "pattern"), "*");
        const matches: string[] = [];
        for await (const path of walkFiles(base)) {
          const display = displayPath(path);
          if (globMatch(pattern, basename(path)) || globMatch(pattern, display.replace(/^\//, ""))) matches.push(display);
        }
        matches.sort();
        const truncated = matches.length > 1000;
        return { matches: matches.slice(0, 1000), truncated };
      }),
    grep: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const base = resolveIn(defaultString(stringParam(params, "path"), "."));
        const re = yield* Effect.try({ try: () => new RegExp(stringParam(params, "pattern")), catch: toError });
        const glob = stringParam(params, "glob");
        return yield* attempt(async () => {
          const matches: Array<Record<string, unknown>> = [];
          for await (const path of walkFiles(base)) {
            if (glob && !globMatch(glob, basename(path))) continue;
            let text: string;
            try {
              const handle = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
              const info = await handle.stat();
              if (!info.isFile()) {
                await handle.close();
                continue;
              }
              text = (await handle.readFile()).toString("utf8");
              await handle.close();
            } catch {
              continue;
            }
            const lines = text.split("\n");
            if (lines.length && lines[lines.length - 1] === "") lines.pop();
            for (let i = 0; i < lines.length; i++) {
              const line = lines[i].replace(/\r$/, "");
              if (re.test(line)) {
                matches.push({ path: displayPath(path), line: i + 1, text: line });
                if (matches.length >= 1000) return { matches, truncated: true };
              }
            }
          }
          return { matches, truncated: false };
        });
      }),
    /** Streams a file in ACKed chunks; the result follows the last chunk. */
    readStream: (session: Session, id: string, params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const full = resolveIn(stringParam(params, "path"));
        const size = (yield* attempt(() => stat(full))).size;
        const handle = yield* attempt(() => open(full, constants.O_RDONLY));
        return yield* Effect.gen(function* () {
          let seq = 0;
          let sent = 0;
          const buffer = Buffer.alloc(READ_STREAM_CHUNK);
          while (true) {
            const { bytesRead } = yield* attempt(() => handle.read(buffer, 0, buffer.length, null));
            if (bytesRead > 0) {
              seq++;
              sent += bytesRead;
              const frame: Message = { id, type: "stream", stream: { channel: "data", data: buffer.subarray(0, bytesRead).toString("base64"), eof: sent >= size, seq } };
              yield* session.sendReadStreamFrame(id, seq, frame);
            }
            if (bytesRead === 0) {
              if (size === 0) yield* session.send({ id, type: "stream", stream: { channel: "data", data: "", eof: true, seq: seq + 1 } }).pipe(Effect.ignore);
              break;
            }
          }
          return { size };
        }).pipe(Effect.ensuring(Effect.promise(() => handle.close().catch(() => {}))));
      }),
    /** Reserves the write before touching the file, so a refused stream cannot truncate it. */
    prepareWriteStream: (session: Session, id: string, params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const pending = yield* Effect.try({ try: () => session.reservePendingWrite(id), catch: toError });
        return yield* Effect.gen(function* () {
          const full = resolveIn(stringParam(params, "path"));
          yield* attempt(() => mkdir(dirname(full), { recursive: true, mode: 0o755 }));
          const file = yield* openWritable(full, stringParam(params, "mode") === "append");
          if (!session.activatePendingWrite(id, pending, file)) return yield* Effect.fail(new Error("context canceled"));
          return { status: "ready" };
        }).pipe(Effect.tapError(() => Effect.sync(() => session.finishPendingWrite(id))));
      }),
  };
}

export type FsMethods = ReturnType<typeof makeFsMethods>;
