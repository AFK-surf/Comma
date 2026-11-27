import DOMPurify from "dompurify";

/** Largest notebook the preview reads whole (notebooks often embed base64 plots). */
export const notebookPreviewMaxBytes = 16 * 1024 * 1024;
/** Maximum number of cells rendered in one preview. */
export const notebookPreviewMaxCells = 200;

export type NotebookOutput =
  | { kind: "stream"; name: "stdout" | "stderr"; text: string }
  | { kind: "image"; mime: string; dataUrl: string }
  | { kind: "html"; html: string }
  | { kind: "markdown"; markdown: string }
  | { kind: "text"; text: string }
  | { kind: "error"; ename: string; evalue: string; traceback: string };

export type NotebookCell =
  | { kind: "markdown"; source: string }
  | { kind: "raw"; source: string }
  | {
      kind: "code";
      source: string;
      executionCount: number | null;
      outputs: NotebookOutput[];
    };

export interface ParsedNotebook {
  language: string;
  languageExtension: string;
  kernelName: string | undefined;
  cells: NotebookCell[];
  totalCells: number;
  truncated: boolean;
}

const extensionByLanguage: Record<string, string> = {
  python: "py",
  python3: "py",
  javascript: "js",
  typescript: "ts",
  r: "r",
  julia: "jl",
  rust: "rs",
  go: "go",
  sql: "sql",
  bash: "sh",
  shell: "sh",
  scala: "scala",
  ruby: "rb",
  cpp: "cpp",
  "c++": "cpp",
  c: "c",
  java: "java",
  kotlin: "kt",
  swift: "swift",
};

// Strips ANSI CSI/OSC escape sequences (common in Python/Jupyter tracebacks and terminal streams).
/* oxlint-disable no-control-regex */
const ansiPattern =
  /\u001b(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001b]*(?:\u0007|\u001b\\)|[@-Z\\-_])/gu;
/* oxlint-enable no-control-regex */

export function stripAnsi(text: string): string {
  return text.replace(ansiPattern, "");
}

function joinSource(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value))
    return value.filter((part): part is string => typeof part === "string").join("");
  return "";
}

const rasterImageMimes = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
] as const;
const base64Only = /^[A-Za-z0-9+/=\s]+$/u;

function encodeUtf8Base64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]!);
  }
  return btoa(binary);
}

const allowedNotebookHtmlTags = [
  "a",
  "abbr",
  "b",
  "blockquote",
  "br",
  "caption",
  "code",
  "col",
  "colgroup",
  "dd",
  "del",
  "details",
  "div",
  "dl",
  "dt",
  "em",
  "figcaption",
  "figure",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "i",
  "img",
  "ins",
  "li",
  "mark",
  "ol",
  "p",
  "pre",
  "s",
  "small",
  "span",
  "strong",
  "sub",
  "summary",
  "sup",
  "table",
  "tbody",
  "td",
  "tfoot",
  "th",
  "thead",
  "tr",
  "u",
  "ul",
];

const allowedNotebookHtmlAttrs = [
  "align",
  "alt",
  "colspan",
  "dir",
  "headers",
  "href",
  "lang",
  "open",
  "rowspan",
  "scope",
  "src",
  "start",
  "title",
  "valign",
];

const safeNotebookImageSrc =
  /^data:image\/(?:png|gif|jpe?g|webp);base64,[A-Za-z0-9+/=\s]+$/iu;
const safeNotebookHref = /^(?:https?:|mailto:)/iu;

/**
 * Sanitizes notebook HTML output (such as Pandas DataFrames) before mounting in the app DOM:
 * uses a strict structural allowlist, strips `class`/`id`/`style`/`data-*` so output cannot spoof
 * app UI, and blocks remote subresource loads (`<img src="https://...">` tracking pixels).
 */
export function sanitizeNotebookHtml(raw: string): string {
  const fragment = DOMPurify.sanitize(raw, {
    ALLOWED_TAGS: allowedNotebookHtmlTags,
    ALLOWED_ATTR: allowedNotebookHtmlAttrs,
    ALLOW_DATA_ATTR: false,
    ALLOW_ARIA_ATTR: false,
    ALLOWED_URI_REGEXP: /^(?:https?:|mailto:|data:image\/(?:png|gif|jpe?g|webp);)/iu,
    RETURN_DOM_FRAGMENT: true,
  });
  for (const img of Array.from(fragment.querySelectorAll("img"))) {
    const src = img.getAttribute("src")?.trim() ?? "";
    if (!safeNotebookImageSrc.test(src)) {
      img.remove();
    }
  }
  for (const link of Array.from(fragment.querySelectorAll("a"))) {
    const href = link.getAttribute("href")?.trim() ?? "";
    if (!safeNotebookHref.test(href)) {
      link.removeAttribute("href");
    }
  }
  const container = fragment.ownerDocument.createElement("div");
  container.append(fragment);
  return container.innerHTML;
}

function parseRichOutput(data: Record<string, unknown>): NotebookOutput | undefined {
  for (const mime of rasterImageMimes) {
    const raw = joinSource(data[mime]).trim();
    if (raw && base64Only.test(raw)) {
      return {
        kind: "image",
        mime,
        dataUrl: `data:${mime};base64,${raw.replace(/\s+/gu, "")}`,
      };
    }
  }
  const svg = joinSource(data["image/svg+xml"]).trim();
  if (svg) {
    // Rendering SVG inside <img> via a data URL isolates it from scripts and external subresources.
    return {
      kind: "image",
      mime: "image/svg+xml",
      dataUrl: `data:image/svg+xml;base64,${encodeUtf8Base64(svg)}`,
    };
  }
  const html = joinSource(data["text/html"]).trim();
  if (html) {
    const clean = sanitizeNotebookHtml(html).trim();
    if (clean) return { kind: "html", html: clean };
  }
  const markdown = joinSource(data["text/markdown"]);
  if (markdown.trim()) return { kind: "markdown", markdown };
  const plain = joinSource(data["text/plain"]);
  if (plain) return { kind: "text", text: stripAnsi(plain) };
  return undefined;
}

function parseOutput(raw: unknown): NotebookOutput | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const output = raw as Record<string, unknown>;
  const type = output.output_type;
  if (type === "stream") {
    const text = stripAnsi(joinSource(output.text));
    if (!text) return undefined;
    return {
      kind: "stream",
      name: output.name === "stderr" ? "stderr" : "stdout",
      text,
    };
  }
  if (type === "error") {
    const ename = typeof output.ename === "string" ? output.ename : "Error";
    const evalue = typeof output.evalue === "string" ? stripAnsi(output.evalue) : "";
    const trace = Array.isArray(output.traceback)
      ? stripAnsi(
          output.traceback
            .filter((line): line is string => typeof line === "string")
            .join("\n")
        )
      : "";
    return { kind: "error", ename, evalue, traceback: trace };
  }
  if (type === "display_data" || type === "execute_result") {
    const data = output.data;
    if (data && typeof data === "object" && !Array.isArray(data)) {
      return parseRichOutput(data as Record<string, unknown>);
    }
  }
  return undefined;
}

/** Parses a Jupyter Notebook (.ipynb, nbformat v3/v4) JSON string into structured cells and outputs. */
export function parseNotebook(
  text: string,
  maxCells = notebookPreviewMaxCells
): ParsedNotebook {
  const doc = JSON.parse(text) as unknown;
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    throw new Error("not a notebook");
  }
  const record = doc as Record<string, unknown>;
  const rawCells: unknown[] | undefined = Array.isArray(record.cells)
    ? record.cells
    : Array.isArray(record.worksheets) &&
        record.worksheets[0] &&
        typeof record.worksheets[0] === "object" &&
        Array.isArray((record.worksheets[0] as Record<string, unknown>).cells)
      ? ((record.worksheets[0] as Record<string, unknown>).cells as unknown[])
      : undefined;
  if (!rawCells) throw new Error("notebook has no cells");

  const metadata =
    record.metadata && typeof record.metadata === "object"
      ? (record.metadata as Record<string, unknown>)
      : undefined;
  const kernelspec =
    metadata?.kernelspec && typeof metadata.kernelspec === "object"
      ? (metadata.kernelspec as Record<string, unknown>)
      : undefined;
  const languageInfo =
    metadata?.language_info && typeof metadata.language_info === "object"
      ? (metadata.language_info as Record<string, unknown>)
      : undefined;

  const rawLanguage =
    (typeof languageInfo?.name === "string" && languageInfo.name) ||
    (typeof kernelspec?.language === "string" && kernelspec.language) ||
    "python";
  const language = rawLanguage.toLowerCase();
  const fileExt =
    typeof languageInfo?.file_extension === "string"
      ? languageInfo.file_extension.replace(/^\./u, "").toLowerCase()
      : "";
  const languageExtension =
    fileExt || extensionByLanguage[language] || language || "py";
  const kernelName =
    typeof kernelspec?.display_name === "string" && kernelspec.display_name.trim()
      ? kernelspec.display_name.trim()
      : undefined;

  const totalCells = rawCells.length;
  const truncated = totalCells > maxCells;
  const cells: NotebookCell[] = [];

  for (const raw of rawCells.slice(0, maxCells)) {
    if (!raw || typeof raw !== "object") continue;
    const cell = raw as Record<string, unknown>;
    const cellType = cell.cell_type;
    const source = joinSource(cell.source ?? cell.input);
    if (cellType === "markdown" || cellType === "heading") {
      cells.push({ kind: "markdown", source });
    } else if (cellType === "code") {
      const executionCount =
        typeof cell.execution_count === "number"
          ? cell.execution_count
          : typeof cell.prompt_number === "number"
            ? cell.prompt_number
            : null;
      const outputs = Array.isArray(cell.outputs)
        ? cell.outputs
            .map(parseOutput)
            .filter((item): item is NotebookOutput => item !== undefined)
        : [];
      cells.push({ kind: "code", source, executionCount, outputs });
    } else {
      cells.push({ kind: "raw", source });
    }
  }

  return {
    language: rawLanguage,
    languageExtension,
    kernelName,
    cells,
    totalCells,
    truncated,
  };
}
