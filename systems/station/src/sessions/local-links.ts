// Local Markdown destinations are files to deliver, not routes on the web client (the Rust station's local_links.rs). The
// Rust reads the Markdown with pulldown-cmark; this reads what that finds of links: inline links and images (`[x](d)`,
// `![x](d)`, `<…>` destinations, nested ones), outside code spans and fenced code blocks, and reference links (which
// are refused when they name a local file). With the native addon the Rust's own code reads it (native/mesh/src/local.rs); without it, raw HTML and indented code blocks
// are not told apart from text.
import { realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Mesh, loadMesh } from "../mesh/native.ts";
import { platform } from "../platform/index.ts";

type Found = { inline: boolean; destination: string; start: number; end: number };

const isFile = (path: string) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

/// percent_decode_str(..).decode_utf8_lossy().
function percentDecode(text: string): string {
  const bytes: number[] = [];
  const raw = Buffer.from(text, "utf8");
  for (let i = 0; i < raw.length; i++) {
    const hex = (c: number) => (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
    if (raw[i] === 0x25 && i + 2 < raw.length && hex(raw[i + 1]!) && hex(raw[i + 2]!)) {
      bytes.push(parseInt(String.fromCharCode(raw[i + 1]!, raw[i + 2]!), 16));
      i += 2;
    } else bytes.push(raw[i]!);
  }
  return new TextDecoder("utf-8").decode(Buffer.from(bytes));
}

/// utf8_percent_encode(.., NON_ALPHANUMERIC): every byte but ASCII letters and digits as %XX.
function percentEncode(text: string): string {
  let out = "";
  for (const b of Buffer.from(text, "utf8")) {
    out += (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ? String.fromCharCode(b) : `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

/// Resolves only file URLs, familiar machine roots, or paths that actually name a local file. In particular, station
/// routes (/o/…, /chats/…) and protocol-relative web URLs stay web links.
function localPath(destination: string): string | null {
  const decoded = percentDecode(destination);
  let path: string;
  if (destination.startsWith("file:")) {
    try {
      path = fileURLToPath(new URL(destination));
    } catch {
      throw new Error(`invalid local file link: ${destination}; use an absolute path in files`);
    }
  } else if (platform.paths.isDrivePath(decoded)) {
    // A drive's path (`C:\…`, `C:/…`, on Windows) is a local one, as a familiar root's is on Unix.
    path = decoded;
  } else {
    if (!decoded.startsWith("/") || decoded.startsWith("//")) return null;
    const known = ["/Users/", "/home/", "/tmp/", "/private/", "/var/", "/Volumes/", "/mnt/", "/workspace/", "/etc/", "/opt/"];
    if (!known.some((root) => decoded.startsWith(root)) && !isFile(decoded)) return null;
    path = decoded;
  }
  if (isFile(path)) return path;
  // Codex commonly emits /path/file.rs:12 or /path/file.rs:12:3.
  let base = path;
  for (let i = 0; i < 2; i++) {
    const at = base.lastIndexOf(":");
    if (at < 0) break;
    const tail = base.slice(at + 1);
    if (tail === "" || !/^[0-9]+$/.test(tail)) break;
    base = base.slice(0, at);
    if (isFile(base)) return base;
  }
  throw new Error(`local file link does not name a readable file: ${destination}; correct the path or write it as code instead of a link`);
}

const PUNCT = /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/;

/// A destination as pulldown-cmark gives it: without its `<>`, backslash escapes resolved.
const unescape = (raw: string) => raw.replace(/\\(.)/g, (all, c) => (PUNCT.test(c) ? c : all));

/// Where code is (fenced blocks and code spans), as [start, end) ranges: nothing in them is a link.
function codeRanges(text: string): [number, number][] {
  const ranges: [number, number][] = [];
  // Fenced blocks: a line opening with ``` or ~~~ (up to three spaces in), to a line closing it with as many.
  const lines = text.split("\n");
  let at = 0;
  let open: { start: number; fence: string } | null = null;
  for (const line of lines) {
    const fence = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (open === null && fence && !(fence[1]![0] === "`" && line.slice(fence[0].length).includes("`"))) open = { start: at, fence: fence[1]! };
    else if (open !== null && fence && fence[1]![0] === open.fence[0] && fence[1]!.length >= open.fence.length && line.slice(fence[0].length).trim() === "") {
      ranges.push([open.start, at + line.length]);
      open = null;
    }
    at += line.length + 1;
  }
  if (open !== null) ranges.push([open.start, text.length]);
  // Code spans: a run of backticks to the next run as long.
  const inBlock = (i: number) => ranges.some(([s, e]) => i >= s && i < e);
  const spans: [number, number][] = [];
  for (let i = 0; i < text.length; ) {
    if (text[i] === "\\") {
      i += 2;
      continue;
    }
    if (text[i] !== "`" || inBlock(i)) {
      i++;
      continue;
    }
    let n = 0;
    while (text[i + n] === "`") n++;
    const run = "`".repeat(n);
    let close = -1;
    for (let j = i + n; j < text.length; ) {
      const k = text.indexOf(run, j);
      if (k < 0) break;
      let m = 0;
      while (text[k + m] === "`") m++;
      if (m === n) {
        close = k;
        break;
      }
      j = k + m;
    }
    if (close < 0) {
      i += n;
      continue;
    }
    spans.push([i, close + n]);
    i = close + n;
  }
  return [...ranges, ...spans];
}

/// The `]` closing the bracket that opens at `open`, nested brackets counted, escapes and code skipped.
function closing(text: string, open: number, code: (i: number) => boolean): number {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (code(i)) continue;
    if (text[i] === "[") depth++;
    else if (text[i] === "]" && --depth === 0) return i;
  }
  return -1;
}

/// An inline link's destination after its `](`: the raw destination's [start, end), and where the link ends.
function inlineDestination(text: string, at: number): [number, number, number] | null {
  let i = at;
  while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  let start: number;
  let end: number;
  if (text[i] === "<") {
    start = i + 1;
    let j = start;
    while (j < text.length && text[j] !== ">" && text[j] !== "\n" && text[j] !== "<") j += text[j] === "\\" ? 2 : 1;
    if (text[j] !== ">") return null;
    end = j;
    i = j + 1;
  } else {
    start = i;
    let depth = 0;
    let j = i;
    for (; j < text.length; j++) {
      const c = text[j]!;
      if (c === "\\") {
        j++;
        continue;
      }
      if (/\s/.test(c)) break;
      if (c === "(") depth++;
      else if (c === ")") {
        if (depth === 0) break;
        depth--;
      }
    }
    end = j;
    i = j;
  }
  // An optional title.
  while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  const quote = text[i];
  if (quote === '"' || quote === "'" || quote === "(") {
    const shut = quote === "(" ? ")" : quote;
    let j = i + 1;
    while (j < text.length && text[j] !== shut) j += text[j] === "\\" ? 2 : 1;
    if (text[j] !== shut) return null;
    i = j + 1;
    while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  }
  return text[i] === ")" ? [start, end, i + 1] : null;
}

/// The links and images Markdown finds in `text`, in order of where they start.
function links(text: string): Found[] {
  const code = codeRanges(text);
  const inCode = (i: number) => code.some(([s, e]) => i >= s && i < e);
  // Reference definitions: `[label]: destination` at a line's start.
  const definitions = new Map<string, string>();
  const defined: [number, number][] = [];
  for (const m of text.matchAll(/^ {0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|\S+)[^\n]*$/gm)) {
    if (inCode(m.index!)) continue;
    const label = m[1]!.trim().toLowerCase().replace(/\s+/g, " ");
    const raw = m[2]!;
    if (!definitions.has(label)) definitions.set(label, unescape(raw.startsWith("<") ? raw.slice(1, -1) : raw));
    defined.push([m.index!, m.index! + m[0].length]);
  }
  const found: Found[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (text[i] !== "[" || inCode(i) || defined.some(([s, e]) => i >= s && i < e)) continue;
    const start = i > 0 && text[i - 1] === "!" && !(i > 1 && text[i - 2] === "\\") ? i - 1 : i;
    const close = closing(text, i, inCode);
    if (close < 0) continue;
    if (text[close + 1] === "(") {
      const at = inlineDestination(text, close + 2);
      if (at) {
        const raw = text.slice(at[0], at[1]);
        found.push({ inline: true, destination: unescape(raw), start, end: at[2] });
        continue;
      }
    }
    // A reference: [text][label], [label][] or [label].
    let label = text.slice(i + 1, close);
    if (text[close + 1] === "[") {
      const end = text.indexOf("]", close + 2);
      if (end >= 0 && end > close + 2) label = text.slice(close + 2, end);
    }
    const destination = definitions.get(label.trim().toLowerCase().replace(/\s+/g, " "));
    if (destination !== undefined) found.push({ inline: false, destination, start, end: close + 1 });
  }
  // Autolinks naming a file: <file:///…>.
  for (const m of text.matchAll(/<(file:[^\s<>]*)>/g)) {
    if (!inCode(m.index!) && !found.some((f) => m.index! >= f.start && m.index! < f.end)) found.push({ inline: false, destination: m[1]!, start: m.index!, end: m.index! + m[0].length });
  }
  return found.sort((a, b) => a.start - b.start);
}

const canonical = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

/// Keeps ordinary prose and code untouched. Makes actual local links refer to immutable message attachments (adding
/// their files to `paths`). Run before posting anything, so a missing or ambiguous attachment can be corrected by the
/// agent.
export function prepare(text: string, paths: string[], workspace: string): string {
  // The Rust station's own reading of the Markdown (pulldown-cmark, in the native addon), when it is there.
  const native = nativeOrNull();
  if (native !== null) {
    const prepared = native.prepareLocalLinks(text, paths, workspace);
    paths.splice(0, paths.length, ...prepared.paths);
    return prepared.text;
  }
  return prepareHere(text, paths, workspace);
}

let addon: Mesh | null | undefined;
function nativeOrNull(): Mesh | null {
  if (addon === undefined) {
    try {
      addon = loadMesh();
    } catch {
      addon = null;
    }
  }
  return addon;
}

/// prepare without the addon: as far as this reads the Markdown (raw HTML and indented code blocks not told apart).
export function prepareHere(text: string, paths: string[], workspace: string): string {
  const replacements: [number, number, string][] = [];
  for (const link of links(text)) {
    const path = localPath(link.destination);
    if (path === null) continue;
    if (!link.inline) throw new Error(`local file link ${link.destination} must use inline Markdown: [label](path); it will be attached automatically`);
    const source = text.slice(link.start, link.end);
    let start: number | null = null;
    for (let at = source.lastIndexOf(link.destination); at >= 0; at = at === 0 ? -1 : source.lastIndexOf(link.destination, at - 1)) {
      const before = source.slice(0, at).trimEnd().replace(/<+$/, "").trimEnd();
      if (before.endsWith("](")) {
        start = at;
        break;
      }
    }
    if (start === null) throw new Error(`write local file link ${link.destination} without Markdown escapes (use <…> around paths with spaces)`);
    const real = canonical(path);
    if (real === null) throw new Error(`no such file: ${path}`);
    if (!paths.some((p) => canonical(isAbsolute(p) ? p : join(workspace, p)) === real)) paths.push(path);
    const name = percentEncode(basename(path));
    replacements.push([link.start + start, link.start + start + link.destination.length, name]);
  }
  // Both clients identify attachments by name; different files with one name must never silently overwrite.
  const names = new Map<string, string>();
  for (const p of paths) {
    const path = isAbsolute(p) ? p : join(workspace, p);
    const real = canonical(path);
    if (real === null) throw new Error(`no such file: ${path}`);
    const name = basename(path);
    if (name === "") continue;
    const previous = names.get(name);
    names.set(name, real);
    if (previous !== undefined && previous !== real) throw new Error(`attachments have the same name: ${name}; rename the files before posting`);
  }
  replacements.sort((a, b) => a[0] - b[0]);
  let result = text;
  for (const [from, to, name] of replacements.reverse()) result = result.slice(0, from) + name + result.slice(to);
  return result;
}
