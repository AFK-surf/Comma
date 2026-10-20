// A runtime's own session transcript as one readable timeline for the pages (the Rust station's transcript.rs), read whole
// as a session nobody watches is (live.rs `before`): its file, or its `.zst` once put away; the agent's own posts left
// out of it and woven back in from the station's record of them (hub.rs `post_entries`).
// - claude: <home>/projects/<cwd>/<id>.jsonl, lines of {type: user|assistant, message: {content: string | blocks}}
// - codex: <home>/sessions/**/rollout-*<id>.jsonl, lines of {type: response_item, payload: message | reasoning | …}
//
// JSON is read with JSON.parse, so a value shows as JavaScript has it: a number written `1.0` shows `1`, a key that is
// an integer comes first, a number past 2^53 rounds (serde_json keeps each as written). Transcripts rarely have them.
import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import { zstdDecompressSync } from "node:zlib";
import { tr } from "./spoken.ts";
import type { Json } from "./store.ts";

/// TimelineEntry as serde writes it: `tool`, `ok`, `callId`, `subagent` left out when none.
export type TimelineEntry = { at: string | null; kind: string; text: string; tool?: string; ok?: boolean; callId?: string; subagent?: boolean };

const MAX_TEXT = 4000;

// ---- Rust's char classes (Unicode White_Space, Alphabetic, Numeric) ----

const WS = /^\p{White_Space}$/u;
const isWs = (c: string | undefined) => c !== undefined && WS.test(c);
const isAlphabetic = (c: string | undefined) => c !== undefined && /^\p{Alphabetic}$/u.test(c);
const isAlphanumeric = (c: string | undefined) => c !== undefined && /^[\p{Alphabetic}\p{N}]$/u.test(c);
const trimStart = (s: string) => s.replace(/^\p{White_Space}+/u, "");
const trim = (s: string) => s.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, "");
const isStr = (v: Json): v is string => typeof v === "string";
const isObj = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
/// serde_json's `value.get(key)`: an object's field, else none.
const get = (v: Json, key: string): Json | undefined => (isObj(v) && Object.hasOwn(v, key) ? v[key] : undefined);
const stringOf = (v: Json | undefined): string | undefined => (isStr(v) ? v : undefined);

/// archive.rs `storage`: the file, or its `.zst` once put away.
const storage = (path: string) => (existsSync(path) ? path : `${path}.zst`);
const isFile = (path: string) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};
const isDir = (path: string) => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};
const entriesOf = (dir: string): string[] | null => {
  try {
    return readdirSync(dir);
  } catch {
    return null;
  }
};

/// transcript_path: where a runtime keeps a session's transcript, if it is there.
export function transcriptPath(runtime: "claude" | "codex", home: string, id: string): string | null {
  if (runtime === "claude") {
    for (const dir of entriesOf(join(home, "projects")) ?? []) {
      const path = join(home, "projects", dir, `${id}.jsonl`);
      if (isFile(storage(path))) return path;
    }
    return null;
  }
  const find = (dir: string): string | null => {
    for (const name of entriesOf(dir) ?? []) {
      const path = join(dir, name);
      if (isDir(path)) {
        const found = find(path);
        if (found !== null) return found;
      } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl`)) {
        return path;
      } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl.zst`)) {
        return path.slice(0, -".zst".length);
      }
    }
    return null;
  };
  return find(join(home, "sessions"));
}

/// The transcripts of a session's runtime sessions (`ids`, the first first, ending with its current one), each looked
/// for in the homes given (its profile's first): a runtime session that ran on another account may have written into
/// that account's home (one whose transcript directory is not the shared one, agent-home.ts `linkTranscripts`).
/// `current` is whether the current one's is there: a runtime writes it only once its conversation has begun.
export function transcriptPaths(runtime: "claude" | "codex", homes: string[], ids: string[]): { paths: string[]; current: boolean } {
  const found = ids.map((id) => {
    for (const home of homes) {
      const path = transcriptPath(runtime, home, id);
      if (path !== null) return path;
    }
    return null;
  });
  return { paths: found.filter((p) => p !== null), current: found.at(-1) != null };
}

function clip(text: string): string {
  const chars = Array.from(text);
  return chars.length > MAX_TEXT ? `${chars.slice(0, MAX_TEXT).join("")}\n… (${chars.length - MAX_TEXT} more characters)` : text;
}

/// serde_json::to_string_pretty.
const pretty = (v: Json) => JSON.stringify(v, null, 2) ?? "null";

function toText(v: Json): string {
  if (isStr(v)) return v;
  if (Array.isArray(v)) {
    return v
      .map((item) => {
        const text = get(item, "text");
        return text !== undefined ? (isStr(text) ? text : JSON.stringify(text)) : toText(item);
      })
      .join("\n");
  }
  return pretty(v);
}

/// A post: shown whole in the history, where the agent made it (its words are what people read, not a call to cut).
export const isPosting = (tool: string) => tool === "mcp__stillfail__chat_post" || tool === "mcp__ember__chat_post";

/// What reading keeps between lines: calls taken out of a script.
export type ReadState = { inner: Map<string, number> };

/// A record's timeline entries, read on from `state` (what TranscriptTail keeps between reads): for a reader that takes
/// a transcript a piece at a time as it grows (src/sessions/live.ts).
export function timelineOf(runtime: "claude" | "codex", record: Json, state: ReadState, out: TimelineEntry[]): void {
  if (runtime === "claude") claudeTimeline(record, state, out);
  else codexTimeline(record, state, out);
}

function claudeTimeline(r: Json, state: ReadState, out: TimelineEntry[]) {
  const kind = stringOf(get(r, "type")) ?? "";
  if ((kind !== "user" && kind !== "assistant") || get(r, "isMeta") === true) return;
  const at = stringOf(get(r, "timestamp")) ?? null;
  const subagent = get(r, "isSidechain") === true;
  const entry = (kind: string, text: string): TimelineEntry => {
    const e: TimelineEntry = { at, kind, text };
    if (subagent) e.subagent = true;
    return e;
  };
  // Fields in serde's order: at, kind, text, tool, ok, callId, subagent.
  const withFields = (e: TimelineEntry, more: Partial<TimelineEntry>): TimelineEntry => {
    const v: TimelineEntry = { at: e.at, kind: e.kind, text: e.text };
    if (more.tool !== undefined) v.tool = more.tool;
    if (more.ok !== undefined) v.ok = more.ok;
    if (more.callId !== undefined) v.callId = more.callId;
    if (e.subagent !== undefined) v.subagent = e.subagent;
    return v;
  };
  const content = get(get(r, "message"), "content");
  if (isStr(content)) {
    out.push(entry(kind, clip(content)));
    return;
  }
  for (const block of Array.isArray(content) ? content : []) {
    const textOf = (k: string) => {
      const t = get(block, k);
      return isStr(t) && t !== "" ? t : undefined;
    };
    switch (stringOf(get(block, "type"))) {
      case "text": {
        const t = textOf("text");
        if (t !== undefined) out.push(entry(kind, clip(t)));
        break;
      }
      case "thinking": {
        const t = textOf("thinking");
        if (t !== undefined) out.push(entry("thinking", clip(t)));
        break;
      }
      case "tool_use": {
        const name = stringOf(get(block, "name")) ?? "";
        const id = stringOf(get(block, "id"));
        const input = pretty(get(block, "input") ?? null);
        out.push(withFields(entry("tool_call", isPosting(name) ? input : clip(input)), { tool: name, callId: id }));
        break;
      }
      case "tool_result": {
        const id = stringOf(get(block, "tool_use_id"));
        const isError = get(block, "is_error");
        const failed = typeof isError === "boolean" ? isError : false;
        out.push(withFields(entry("tool_result", clip(toText(get(block, "content") ?? null))), { ok: !failed, callId: id }));
        break;
      }
    }
  }
}

/// injected: context Codex prepends as user messages; not what anyone said.
export function injected(text: string): boolean {
  const t = trimStart(text);
  return ["environment_context", "user_instructions", "permissions", "skills_instructions", "collaboration_mode"].some((tag) => {
    if (!t.startsWith(`<${tag}`)) return false;
    const next = Array.from(t.slice(tag.length + 1))[0];
    return next === undefined || (!isAlphanumeric(next) && next !== "_");
  });
}

/// machine_sessions.rs `typed_parts`: what a person typed in a Codex user message, without the context Codex adds.
function typedParts(content: Json): string {
  if (isStr(content)) return content;
  return (Array.isArray(content) ? content : [])
    .map((b) => get(b, "text"))
    .filter(isStr)
    .map(typed)
    .filter((t): t is string => t !== null && trim(t) !== "" && !injected(t) && !wrapped(t))
    .join("\n");
}

/// machine_sessions.rs `typed`: none of the instructions Codex adds; of an editor's context before a request, the request.
function typed(text: string): string | null {
  const t = trimStart(text);
  if (t.startsWith("# AGENTS.md instructions")) return null;
  if (!t.startsWith("#")) return text;
  for (const mark of ["## My request for Codex:", "## My request:"]) {
    const at = t.lastIndexOf(mark);
    if (at >= 0) return trim(t.slice(at + mark.length));
  }
  return text;
}

/// machine_sessions.rs `wrapped`: context Codex adds as a person's message, one tag around all of it.
function wrapped(text: string): boolean {
  const t = trim(text);
  if (!t.startsWith("<")) return false;
  const close = t.indexOf(">", 1);
  if (close < 0) return false;
  const name = t.slice(1, close);
  return name !== "" && /^[A-Za-z0-9_-]+$/.test(name) && t.endsWith(`</${name}>`);
}

function codexTimeline(r: Json, state: ReadState, out: TimelineEntry[]) {
  if (get(r, "type") !== "response_item") return;
  const p = get(r, "payload") ?? null;
  const at = stringOf(get(r, "timestamp")) ?? null;
  const kind = stringOf(get(p, "type")) ?? "";
  const name = stringOf(get(p, "name")) ?? "";
  const callId = stringOf(get(p, "call_id"));
  const call = (tool: string, id: string | undefined, text: string): TimelineEntry => {
    const e: TimelineEntry = { at, kind: "tool_call", text, tool };
    if (id !== undefined) e.callId = id;
    return e;
  };
  const result = (ok: boolean, id: string | undefined, text: string): TimelineEntry => {
    const e: TimelineEntry = { at, kind: "tool_result", text, ok };
    if (id !== undefined) e.callId = id;
    return e;
  };
  switch (kind) {
    case "message": {
      const role = stringOf(get(p, "role")) ?? "";
      if (role !== "user" && role !== "assistant") return;
      const content = get(p, "content") ?? null;
      // A person's: what they typed, without the context Codex adds as parts of their own.
      const text = role === "user" ? typedParts(content) : toText(content);
      if (role === "user" && injected(text)) return;
      if (trim(text) !== "") out.push({ at, kind: role, text: clip(text) });
      return;
    }
    case "reasoning": {
      const content = get(p, "content");
      const chosen = Array.isArray(content) && content.length > 0 ? content : (get(p, "summary") ?? []);
      const text = toText(chosen);
      if (trim(text) !== "") out.push({ at, kind: "thinking", text: clip(text) });
      return;
    }
  }
  if (kind === "custom_tool_call" && name === "exec") {
    // Codex's code mode: the calls in the script are the steps; the script itself is one only when it does more than
    // call them.
    const script = stringOf(get(p, "input")) ?? "";
    const [calls, only] = scriptCalls(script);
    if (!only) out.push(call("exec", callId, clip(script)));
    calls.forEach(([tool, args], i) => {
      // The script's output answers its first call when the script is nothing but calls.
      const id = callId === undefined ? undefined : only && i === 0 ? callId : `${callId}#${i}`;
      out.push(call(tool, id, isPosting(tool) ? pretty(args) : clip(pretty(args))));
    });
    // Calls taken out of a script that does more: they are done when the script is.
    if (!only && callId !== undefined && calls.length > 0) state.inner.set(callId, calls.length);
    return;
  }
  if (kind === "function_call" || kind === "custom_tool_call") {
    const given = get(p, "arguments") ?? get(p, "input");
    const raw = given === undefined ? "" : isStr(given) ? given : JSON.stringify(given);
    // Not JSON (custom tools take free text): shown as is.
    let args: string;
    try {
      args = pretty(JSON.parse(raw));
    } catch {
      args = raw;
    }
    out.push(call(name, callId, isPosting(name) ? args : clip(args)));
    return;
  }
  if (kind === "function_call_output" || kind === "custom_tool_call_output") {
    const text = toText(get(p, "output") ?? null);
    const said = text.indexOf("Process exited with code ");
    const failed = said >= 0 && /^[1-9]/.test(text.slice(said + 25));
    out.push(result(!failed, callId, clip(text)));
    const count = callId === undefined ? 0 : (state.inner.get(callId) ?? 0);
    for (let i = 0; i < count; i++) out.push(result(!failed, `${callId ?? ""}#${i}`, tr("station.transcript.inScriptOutput")));
  }
}

// ---- code mode's scripts ----

/// script_calls: the tool calls in a code-mode script, `tools.<name>({…})` with a literal argument (read as data,
/// never run), and whether the script is nothing else.
export function scriptCalls(script: string): [[string, Json][], boolean] {
  const chars = Array.from(script);
  const calls: [string, Json][] = [];
  let rest = script;
  let i = 0;
  for (let found = findFrom(chars, i, "tools."); found !== null; found = findFrom(chars, i, "tools.")) {
    let j = found + 6;
    const nameStart = j;
    while (j < chars.length && (isAlphanumeric(chars[j]) || chars[j] === "_" || chars[j] === "$")) j++;
    const name = chars.slice(nameStart, j).join("");
    const first = chars[nameStart];
    const firstOk = first !== undefined && (isAlphabetic(first) || first === "_" || first === "$");
    while (j < chars.length && isWs(chars[j])) j++;
    i = found + 6;
    if (!firstOk || chars[j] !== "(") continue;
    const literal = readLiteral(chars, j + 1);
    if (literal === null) continue;
    let k = literal[1];
    while (k < chars.length && isWs(chars[k])) k++;
    if (chars[k] !== ")") continue;
    calls.push([name, literal[0]]);
    const whole = chars.slice(found, k + 1).join("");
    const at = rest.indexOf(whole);
    if (at >= 0) rest = rest.slice(0, at) + rest.slice(at + whole.length);
    i = k + 1;
  }
  // What is left once the calls are out: nothing but their wrapping.
  const stripped = stripWrapping(rest);
  const only = calls.length > 0 && Array.from(stripped).every((c) => isWs(c) || c === ";");
  return [calls, only];
}

function findFrom(chars: string[], from: number, needle: string): number | null {
  const n = Array.from(needle);
  for (let i = from; i < Math.max(0, chars.length - (n.length - 1)); i++) {
    if (n.every((c, k) => chars[i + k] === c)) return i;
  }
  return null;
}

const bytes = (s: string) => Buffer.byteLength(s);

/// strip_wrapping: `text(await )`, `await` and `text()` taken out (spaces inside allowed), until none is left. As the
/// Rust does, what spaces it skips it counts in bytes over characters.
function stripWrapping(rest: string): string {
  let s = rest;
  for (;;) {
    const before = s;
    let out = "";
    const chars = Array.from(s);
    let i = 0;
    while (i < chars.length) {
      const tail = chars.slice(i).join("");
      if (tail.startsWith("text(")) {
        const after = tail.slice(5);
        const trimmed = trimStart(after);
        const skipped = bytes(after) - bytes(trimmed);
        if (trimmed.startsWith("await")) {
          const afterAwait = trimmed.slice(5);
          const t2 = trimStart(afterAwait);
          if (t2.startsWith(")")) {
            i += 5 + skipped + 5 + (bytes(afterAwait) - bytes(t2)) + 1;
            continue;
          }
        } else if (trimmed.startsWith(")")) {
          i += 5 + skipped + 1;
          continue;
        }
      }
      if (tail.startsWith("await")) {
        i += 5;
        continue;
      }
      out += chars[i];
      i += 1;
    }
    s = out;
    if (s === before) return s;
  }
}

/// read_literal: a JavaScript literal (object, array, string, number, true/false/null) at `at`, as data, and its end;
/// null when it is anything else.
function readLiteral(src: string[], at: number): [Json, number] | null {
  let i = at;
  const space = () => {
    while (i < src.length && isWs(src[i])) i++;
  };
  const string = (): string | null => {
    const quote = src[i];
    i++;
    let out = "";
    while (i < src.length && src[i] !== quote) {
      if (quote === "`" && src[i] === "$" && src[i + 1] === "{") return null;
      if (src[i] === "\\") {
        const next = src[i + 1];
        if (next === undefined) return null;
        if (next === "u") {
          if (i + 6 > src.length) return null;
          const hex = src.slice(i + 2, i + 6).join("");
          // u32::from_str_radix takes a leading +; char::from_u32 no surrogate.
          if (!/^\+?[0-9a-fA-F]+$/.test(hex)) return null;
          const code = parseInt(hex, 16);
          if (code >= 0xd800 && code <= 0xdfff) return null;
          out += String.fromCodePoint(code);
          i += 6;
          continue;
        }
        const escapes: Record<string, string> = { n: "\n", t: "\t", r: "\r", b: "\b", f: "\f", v: "\v", "0": "\0" };
        out += escapes[next] ?? next;
        i += 2;
        continue;
      }
      out += src[i];
      i++;
    }
    if (src[i] !== quote) return null;
    i++;
    return out;
  };
  const value = (): Json | undefined => {
    space();
    const c = src[i];
    if (c === undefined) return undefined;
    if (c === "{") {
      i++;
      const obj: Json = {};
      for (;;) {
        space();
        if (src[i] === "}") {
          i++;
          return obj;
        }
        let key: string;
        if (src[i] === '"' || src[i] === "'") {
          const k = string();
          if (k === null) return undefined;
          key = k;
        } else {
          const start = i;
          const first = src[i];
          if (first === undefined || !(isAlphabetic(first) || first === "_" || first === "$")) return undefined;
          while (i < src.length && (isAlphanumeric(src[i]) || src[i] === "_" || src[i] === "$")) i++;
          key = src.slice(start, i).join("");
        }
        space();
        if (src[i] !== ":") return undefined;
        i++;
        const v = value();
        if (v === undefined) return undefined;
        obj[key] = v;
        space();
        if (src[i] === ",") i++;
        else if (src[i] === "}") {
          i++;
          return obj;
        } else return undefined;
      }
    }
    if (c === "[") {
      i++;
      const list: Json[] = [];
      for (;;) {
        space();
        if (src[i] === "]") {
          i++;
          return list;
        }
        const v = value();
        if (v === undefined) return undefined;
        list.push(v);
        space();
        if (src[i] === ",") i++;
        else if (src[i] === "]") {
          i++;
          return list;
        } else return undefined;
      }
    }
    if (c === '"' || c === "'" || c === "`") return string() ?? undefined;
    const rest = src.slice(i, i + 64).join("");
    for (const word of ["true", "false", "null"]) {
      if (rest.startsWith(word)) {
        i += word.length;
        return JSON.parse(word);
      }
    }
    const len = numberLen(rest);
    if (len === null) return undefined;
    i += len;
    try {
      return JSON.parse(rest.slice(0, len));
    } catch {
      return undefined;
    }
  };
  const v = value();
  return v === undefined ? null : [v, i];
}

/// number_len: the length of a JSON-like number at the start (-?\d+(\.\d+)?([eE][+-]?\d+)?), if one is there.
function numberLen(s: string): number | null {
  const m = /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(s);
  return m ? m[0].length : null;
}

// ---- times ----

/// Rust's `str::parse::<i64>` of a few bytes: digits with a sign at most.
function num(b: Buffer, from: number, len: number): number | null {
  if (from + len > b.length) return null;
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(b.subarray(from, from + len));
  } catch {
    return null;
  }
  return /^[+-]?\d+$/.test(text) ? Number(text) : null;
}

const divEuclid = (a: number, b: number) => Math.floor(a / b);

/// parse_iso: milliseconds of an ISO timestamp as transcripts write them, if it is one.
export function parseIso(at: string): number | null {
  const b = Buffer.from(at);
  const parts = [num(b, 0, 4), num(b, 5, 2), num(b, 8, 2), num(b, 11, 2), num(b, 14, 2), num(b, 17, 2)];
  if (parts.some((p) => p === null)) return null;
  const [y, mo, d, h, mi, s] = parts as number[];
  let ms = 0;
  if (b[19] === 0x2e) {
    const frac = /^[0-9]*/.exec(b.subarray(20).toString("utf8"))![0];
    ms = Number(frac.slice(0, 3).padEnd(3, "0"));
  }
  // Days from the civil date (Howard Hinnant's algorithm).
  const [yy, mm] = mo <= 2 ? [y - 1, mo + 9] : [y, mo - 3];
  const era = divEuclid(yy, 400);
  const yoe = yy - era * 400;
  const doy = Math.trunc((153 * mm + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.trunc(yoe / 4) - Math.trunc(yoe / 100) + doy;
  const days = era * 146_097 + doe - 719_468;
  return (days * 86_400 + h * 3600 + mi * 60 + s) * 1000 + ms;
}

/// iso: an ISO timestamp of milliseconds since the epoch, as toISOString writes it (any year, as the Rust does).
export function iso(ms: number): string {
  const days = divEuclid(ms, 86_400_000);
  const rest = ms - days * 86_400_000;
  const z = days + 719_468;
  const era = divEuclid(z, 146_097);
  const doe = z - era * 146_097;
  const yoe = Math.trunc((doe - Math.trunc(doe / 1460) + Math.trunc(doe / 36_524) - Math.trunc(doe / 146_096)) / 365);
  const doy = doe - (365 * yoe + Math.trunc(yoe / 4) - Math.trunc(yoe / 100));
  const mp = Math.trunc((5 * doy + 2) / 153);
  const d = doy - Math.trunc((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const y = yoe + era * 400 + (m <= 2 ? 1 : 0);
  const pad = (n: number, w: number) => (n < 0 ? `-${String(-n).padStart(w - 1, "0")}` : String(n).padStart(w, "0"));
  const [h, mi, s, milli] = [Math.trunc(rest / 3_600_000), Math.trunc(rest / 60_000) % 60, Math.trunc(rest / 1000) % 60, rest % 1000];
  return `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}T${pad(h, 2)}:${pad(mi, 2)}:${pad(s, 2)}.${pad(milli, 3)}Z`;
}

// ---- reading ----

/// The bytes of a transcript: its file, or its `.zst` decompressed (archive.rs `reader`); null when neither reads.
function transcriptBytes(path: string): { file: number; size: number } | { bytes: Buffer } | null {
  const disk = storage(path);
  try {
    if (disk === path) {
      const file = openSync(path, "r");
      return { file, size: statSync(path).size };
    }
    return { bytes: zstdDecompressSync(readFileOf(disk)) };
  } catch {
    return null;
  }
}

function readFileOf(path: string): Buffer {
  const file = openSync(path, "r");
  try {
    const size = statSync(path).size;
    const out = Buffer.alloc(size);
    let at = 0;
    while (at < size) {
      const n = readSync(file, out, at, size - at, at);
      if (n === 0) break;
      at += n;
    }
    return out.subarray(0, at);
  } finally {
    closeSync(file);
  }
}

/// TranscriptTail::read from the start: the timeline entries of every whole line (one still being written waits). Read
/// a piece at a time, so a long transcript is never one string.
export function readTimeline(runtime: "claude" | "codex", path: string): TimelineEntry[] {
  const source = transcriptBytes(path);
  if (source === null) return [];
  const out: TimelineEntry[] = [];
  const state: ReadState = { inner: new Map() };
  const line = (bytes: Buffer) => {
    // str::lines: a line's \r before its \n goes; from_utf8_lossy.
    const text = new TextDecoder("utf-8").decode(bytes.at(-1) === 0x0d ? bytes.subarray(0, -1) : bytes);
    if (text === "") return;
    let record: Json;
    try {
      record = JSON.parse(text);
    } catch {
      return;
    }
    if (runtime === "claude") claudeTimeline(record, state, out);
    else codexTimeline(record, state, out);
  };
  const lines = (chunk: Buffer, carry: Buffer): Buffer => {
    let data: Buffer = carry.length > 0 ? Buffer.concat([carry, chunk]) : chunk;
    for (let nl = data.indexOf(0x0a); nl >= 0; nl = data.indexOf(0x0a)) {
      line(data.subarray(0, nl));
      data = data.subarray(nl + 1);
    }
    return Buffer.from(data);
  };
  if ("bytes" in source) {
    lines(source.bytes, Buffer.alloc(0));
    return out;
  }
  try {
    const piece = Buffer.alloc(4 << 20);
    let carry: Buffer = Buffer.alloc(0);
    for (let at = 0; at < source.size; ) {
      const n = readSync(source.file, piece, 0, Math.min(piece.length, source.size - at), at);
      if (n === 0) break;
      at += n;
      carry = lines(piece.subarray(0, n), carry);
    }
  } catch {
    // As the Rust's read failing: nothing.
    return [];
  } finally {
    closeSync(source.file);
  }
  return out;
}
