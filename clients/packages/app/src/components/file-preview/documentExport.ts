// A document as other products take it. An Agent writes Markdown the way Comma reads it; Notion, Google Docs and
// other strict readers take less: a list or a table needs a blank line before it, and `**标签：**正文` is not bold
// to them. So a document leaves Comma written again from its parsed tree (`@comma/core/markdown`), not as its source:
//
//   documentMarkdown  portable Markdown (CommonMark with GitHub's tables, task lists and strikethrough)
//   documentHtml      the same document as HTML, which a rich editor pastes as headings, lists and tables
//
// Bounds: both walk the tree once.
import { documentColorElement, documentColorOf } from "./documentColors";
import {
  documentNodes,
  toMarkdownTree,
  type MarkdownTree,
  type MarkdownTreeNode,
} from "@comma/core/markdown";

type Attributes = Record<string, unknown>;
type Parsed = { kind: string; children: MarkdownTreeNode[]; attributes: Attributes };

function parsed(node: Exclude<MarkdownTreeNode, string>): Parsed {
  const [kind, first, second] = node;
  return {
    kind,
    children: Array.isArray(first) ? first : [],
    attributes: (Array.isArray(first) ? second : first) ?? {},
  };
}

const text = (value: unknown) => (typeof value === "string" ? value : "");

/** The document's tree, as every Comma client draws it. */
export const documentTree = (markdown: string): MarkdownTree =>
  toMarkdownTree(documentNodes([{ type: "markdown", text: markdown }]));

const frontMatter = /^---\r?\n[\s\S]*?\r?\n---\r?\n/u;

/**
 * A document in its two parts: its front matter (the facts about the file that some Markdown files open with,
 * between two `---` lines) and its page, the text after it. The front matter is not text of the page: nothing
 * draws it, reads a title or a heading in it, or compares it. What writes the document writes it back as it was.
 */
export function documentParts(markdown: string) {
  const front = frontMatter.exec(markdown)?.[0] ?? "";
  return { front, page: markdown.slice(front.length) };
}

/** A heading of the document's outline: the document's own headings, not those inside a quote or a list. */
export type DocumentHeading = { level: number; text: string };

function plainText(nodes: MarkdownTreeNode[]): string {
  return nodes
    .map((node) => {
      if (typeof node === "string") return node;
      const { children, attributes } = parsed(node);
      return children.length ? plainText(children) : text(attributes.code);
    })
    .join("");
}

/** The document's headings in order, one for each heading block the page draws. */
export const documentHeadings = (tree: MarkdownTree): DocumentHeading[] =>
  tree.flatMap((node) => {
    if (typeof node === "string" || node[0] !== "h") return [];
    const { children, attributes } = parsed(node);
    return [
      {
        level: Math.min(6, Math.max(1, Number(attributes.level) || 1)),
        text: plainText(children).replace(/\s+/gu, " ").trim(),
      },
    ];
  });

// ── Markdown ────────────────────────────────────────────────────────────────

const punctuation = /[\p{P}\p{S}]/u;
const space = /\s/u;
/** A character a delimiter run may stand beside and still open or close emphasis. */
const free = (character: string | undefined) =>
  character === undefined || space.test(character) || punctuation.test(character);

/**
 * Text as Markdown that reads back as the same text: the characters that would start a span, a link or HTML are
 * escaped, and so is what would turn a line into a heading, a quote, a list item or a rule.
 */
function escapeText(value: string, cell: boolean) {
  let out = value
    .replace(/[\\`*[\]$]/gu, "\\$&")
    // An underscore inside a word is only a letter.
    .replace(/(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])/gu, "\\_")
    .replace(/~~/gu, "\\~~")
    .replace(/<(?=[A-Za-z/!?])/gu, "\\<")
    .replace(/^(\s*)(#{1,6}\s|>|[-+]\s|(?:-{3,}|={3,})\s*$)/gmu, "$1\\$2")
    .replace(/^(\s*\d+)([.)]\s)/gmu, "$1\\$2");
  if (cell) out = out.replace(/\|/gu, "\\|").replace(/\n/gu, " ");
  return out;
}

/** A code span around `code`: a fence of backticks longer than any run inside it. */
function codeSpan(code: string) {
  const longest = Math.max(0, ...(code.match(/`+/gu) ?? []).map((run) => run.length));
  const fence = "`".repeat(longest + 1);
  const padded = /^`|`$|^ .* $/u.test(code) ? ` ${code} ` : code;
  return `${fence}${padded}${fence}`;
}

function linkTarget(href: string, title: string) {
  const target = /[\s()<>]/u.test(href) ? `<${href.replace(/[<>]/gu, "")}>` : href;
  return title ? `${target} "${title.replace(/"/gu, '\\"')}"` : target;
}

/**
 * A span's children with what cannot stand inside its marks taken out. To a strict reader a delimiter run with a
 * space inside it, or with punctuation inside and a letter outside, opens or closes nothing: that space or
 * punctuation moves outside the marks, where it reads the same.
 */
function emphasisParts(
  children: MarkdownTreeNode[],
  before: string | undefined,
  after: string | undefined
) {
  const inner = [...children];
  let lead = "";
  let trail = "";
  const first = inner[0];
  if (typeof first === "string") {
    const spaces = /^\s*/u.exec(first)![0];
    const marks = free(spaces ? " " : before)
      ? ""
      : /^[\p{P}\p{S}]*/u.exec(first.slice(spaces.length))![0];
    lead = spaces + marks;
    inner[0] = first.slice(lead.length);
  }
  const last = inner.at(-1);
  if (typeof last === "string") {
    const spaces = /\s*$/u.exec(last)![0];
    const kept = last.slice(0, last.length - spaces.length);
    const marks = free(spaces ? " " : after) ? "" : /[\p{P}\p{S}]*$/u.exec(kept)![0];
    trail = marks + spaces;
    inner[inner.length - 1] = last.slice(0, last.length - trail.length);
  }
  return { lead, inner: inner.filter((node) => node !== ""), trail };
}

const marks: Record<string, string> = { b: "**", i: "*", s: "~~" };
const htmlTags: Record<string, string> = {
  subscript: "sub",
  superscript: "sup",
  highlight: "mark",
};

/** The first character an inline node writes, for the emphasis before it: markup starts with punctuation. */
function firstCharacter(node: MarkdownTreeNode | undefined): string | undefined {
  if (node === undefined || typeof node === "string") return node?.[0];
  return parsed(node).kind === "br" ? " " : "*";
}

export function inlineMarkdown(nodes: MarkdownTreeNode[], cell = false): string {
  let out = "";
  nodes.forEach((node, index) => {
    if (typeof node === "string") {
      out += escapeText(node, cell);
      return;
    }
    const { kind, children, attributes } = parsed(node);
    const mark = marks[kind];
    if (mark) {
      const { lead, inner, trail } = emphasisParts(
        children,
        out.at(-1),
        firstCharacter(nodes[index + 1])
      );
      const body = inlineMarkdown(inner, cell);
      out +=
        escapeText(lead, cell) +
        (body ? mark + body + mark : "") +
        escapeText(trail, cell);
    } else if (kind === "code") {
      const code = codeSpan(text(attributes.code));
      out += cell ? code.replace(/\|/gu, "\\|") : code;
    } else if (kind === "a") {
      const href = text(attributes.href);
      const label = inlineMarkdown(children, cell);
      out +=
        children.length === 1 &&
        children[0] === href &&
        /^[a-z][a-z0-9+.-]*:/iu.test(href)
          ? `<${href}>`
          : `[${label}](${linkTarget(href, text(attributes.title))})`;
    } else if (kind === "img") {
      out += `![${escapeText(text(attributes.alt), cell)}](${linkTarget(text(attributes.src), text(attributes.title))})`;
    } else if (kind === "br") {
      out += cell ? "<br>" : "  \n";
    } else if (kind === "math") {
      out += `$${text(attributes.content)}$`;
    } else if (kind === "footnote_reference") {
      out += `[^${text(attributes.id)}]`;
    } else if (kind === "html_inline") {
      out += text(attributes.raw) || text(attributes.content);
    } else if (kind === "color" || kind === "ground") {
      // A colour a reader gave in the editor (`documentColors`).
      out += documentColorElement(
        kind,
        text(attributes.color),
        inlineMarkdown(children, cell)
      );
    } else if (kind === "raw_inline") {
      // Markdown an editor kept as written (`documentEditorModel`).
      out += text(attributes.markdown);
    } else if (kind === "checkbox_input") {
      out += attributes.checked === true ? "[x]" : "[ ]";
    } else if (htmlTags[kind]) {
      out += `<${htmlTags[kind]}>${inlineMarkdown(children, cell)}</${htmlTags[kind]}>`;
    } else if (kind !== "footnote_anchor" && kind !== "comma-inline") {
      out += inlineMarkdown(children, cell);
    }
  });
  return out;
}

const indent = (block: string, prefix: string, first = prefix) =>
  block
    .split("\n")
    .map(
      (line, index) => (index === 0 ? first : line ? prefix : prefix.trimEnd()) + line
    )
    .join("\n");

function fencedCode(code: string, language: string) {
  const longest = Math.max(2, ...(code.match(/`+/gu) ?? []).map((run) => run.length));
  const fence = "`".repeat(longest + 1);
  // A reader takes the info string's first word as the language; the rest is Comma's.
  const name = language.trim().split(/\s+/u)[0] ?? "";
  return `${fence}${name}\n${code.replace(/\n$/u, "")}\n${fence}`;
}

const tableLine = (values: string[]) => `| ${values.join(" | ")} |`;

function tableMarkdown(rows: MarkdownTreeNode[]) {
  const cells = rows.flatMap((row) =>
    typeof row === "string" ? [] : [parsed(row).children.flatMap(cellOf)]
  );
  const [header, ...body] = cells;
  if (!header) return "";
  const rule = header.map(({ align }) =>
    // Left is every reader's own alignment.
    align === "center" ? ":-:" : align === "right" ? "--:" : "---"
  );
  return [
    tableLine(header.map((cell) => cell.markdown)),
    tableLine(rule),
    ...body.map((row) =>
      // Every row has the header's number of cells, or a strict reader drops the table.
      tableLine(header.map((_, index) => row[index]?.markdown ?? ""))
    ),
  ].join("\n");
}

function cellOf(cell: MarkdownTreeNode) {
  if (typeof cell === "string") return [];
  const { children, attributes } = parsed(cell);
  return [{ markdown: inlineMarkdown(children, true).trim(), align: attributes.align }];
}

function listMarkdown(items: MarkdownTreeNode[], attributes: Attributes) {
  const ordered = attributes.ordered === true;
  const start = typeof attributes.start === "number" ? attributes.start : 1;
  const blocks = items.flatMap((item, index) => {
    if (typeof item === "string") return [];
    const marker = ordered ? `${start + index}. ` : "- ";
    const held = parsed(item).children;
    const parts = held.flatMap(blockMarkdown);
    // An item of one paragraph, with or without a list under it, is tight; any other has blank lines.
    const kinds = held.map((block) => (typeof block === "string" ? "" : block[0]));
    const tight =
      kinds.length <= 1 ||
      (kinds.length === 2 && kinds[0] === "p" && kinds[1] === "list");
    return [
      {
        tight,
        text: indent(
          parts.join(tight ? "\n" : "\n\n") || "",
          " ".repeat(marker.length),
          marker
        ),
      },
    ];
  });
  return blocks
    .map((block) => block.text)
    .join(blocks.every((block) => block.tight) ? "\n" : "\n\n");
}

/** A block node as Markdown blocks; a caller joins blocks with one blank line. */
export function blockMarkdown(node: MarkdownTreeNode): string[] {
  if (typeof node === "string") return node.trim() ? [escapeText(node, false)] : [];
  const { kind, children, attributes } = parsed(node);
  switch (kind) {
    case "h": {
      const level = Math.min(6, Math.max(1, Number(attributes.level) || 1));
      return [`${"#".repeat(level)} ${inlineMarkdown(children).replace(/\n/gu, " ")}`];
    }
    case "p": {
      const [first, ...rest] = children;
      // A task's box is syntax, with one space after it.
      if (first && typeof first !== "string" && parsed(first).kind === "checkbox_input")
        return [`${inlineMarkdown([first])} ${inlineMarkdown(rest).trimStart()}`];
      return [inlineMarkdown(children)];
    }
    case "list":
      return [listMarkdown(children, attributes)];
    case "quote":
      return [indent(children.flatMap(blockMarkdown).join("\n\n"), "> ")];
    case "pre":
      return [fencedCode(text(attributes.code), text(attributes.language))];
    case "table":
      return [tableMarkdown(children)];
    case "hr":
      return ["---"];
    case "mathblock":
      return [`$$\n${text(attributes.content).trim()}\n$$`];
    case "html_block":
      return [text(attributes.raw) || text(attributes.content)];
    case "raw_block":
      return [text(attributes.markdown)];
    case "footnote": {
      const marker = `[^${text(attributes.id)}]: `;
      return [indent(children.flatMap(blockMarkdown).join("\n\n"), "    ", marker)];
    }
    default: {
      const inline = inlineMarkdown(children);
      return inline ? [inline] : [];
    }
  }
}

/** The document as Markdown a strict reader takes: blocks a blank line apart, one newline at the end. */
/** A whole document as Markdown other products take: its front matter as it was, then its page written anew. */
export function documentFileMarkdown(markdown: string) {
  const { front, page } = documentParts(markdown);
  return front + documentMarkdown(documentTree(page));
}

export function documentMarkdown(tree: MarkdownTree) {
  const blocks = tree.flatMap(blockMarkdown).filter((block) => block !== "");
  return blocks.length ? `${blocks.join("\n\n")}\n` : "";
}

// ── HTML ────────────────────────────────────────────────────────────────────

const escapeHtml = (value: string) =>
  value.replace(/&/gu, "&amp;").replace(/</gu, "&lt;").replace(/>/gu, "&gt;");
const attribute = (value: string) => escapeHtml(value).replace(/"/gu, "&quot;");
/** A link another product may follow: the web, mail, or a place in the document. */
const safeHref = (href: string) => (/^(?:https?:|mailto:|#)/iu.test(href) ? href : "");

const inlineTags: Record<string, string> = {
  // What a comparison of two versions added and took away (`documentDiff`).
  ins: "ins",
  del: "del",
  b: "strong",
  i: "em",
  s: "del",
  subscript: "sub",
  superscript: "sup",
  highlight: "mark",
};

function inlineHtml(nodes: MarkdownTreeNode[]): string {
  return nodes
    .map((node) => {
      if (typeof node === "string") return escapeHtml(node);
      const { kind, children, attributes } = parsed(node);
      const tag = inlineTags[kind];
      if (tag) return `<${tag}>${inlineHtml(children)}</${tag}>`;
      switch (kind) {
        case "code":
          return `<code>${escapeHtml(text(attributes.code))}</code>`;
        case "a": {
          const href = safeHref(text(attributes.href));
          return href
            ? `<a href="${attribute(href)}">${inlineHtml(children)}</a>`
            : inlineHtml(children);
        }
        case "img": {
          const src = safeHref(text(attributes.src));
          const alt = text(attributes.alt);
          return src
            ? `<img src="${attribute(src)}" alt="${attribute(alt)}">`
            : escapeHtml(alt);
        }
        case "br":
          return "<br>";
        case "math":
          return `<code>${escapeHtml(text(attributes.content))}</code>`;
        case "footnote_reference":
          return `<sup>[${escapeHtml(text(attributes.id))}]</sup>`;
        // A rich editor has no task box in pasted HTML: the box is a character.
        case "checkbox_input":
          return attributes.checked === true ? "☑" : "☐";
        // HTML the document wrote is shown as its text, never run. A colour is the one element kept: its tag
        // and name are written anew, never copied.
        case "html_inline": {
          const colored = documentColorOf(text(attributes.content));
          return colored
            ? documentColorElement(colored.kind, colored.color, inlineHtml(children))
            : inlineHtml(children) || escapeHtml(text(attributes.content));
        }
        case "color":
        case "ground":
          return documentColorElement(
            kind,
            text(attributes.color),
            inlineHtml(children)
          );
        case "raw_inline":
          return escapeHtml(text(attributes.markdown));
        case "footnote_anchor":
        case "comma-inline":
          return "";
        default:
          return inlineHtml(children);
      }
    })
    .join("");
}

/** A block a comparison marked as added or taken away says so on its own element. */
function blockHtml(node: MarkdownTreeNode): string {
  const html = plainBlockHtml(node);
  const diff = typeof node === "string" ? undefined : parsed(node).attributes.diff;
  return diff === "ins" || diff === "del"
    ? html.replace(/^<([a-z0-9]+)/u, `<$1 data-diff="${diff}"`)
    : html;
}

function plainBlockHtml(node: MarkdownTreeNode): string {
  if (typeof node === "string") return node.trim() ? `<p>${escapeHtml(node)}</p>` : "";
  const { kind, children, attributes } = parsed(node);
  const blocks = () => children.map(blockHtml).join("");
  switch (kind) {
    case "h": {
      const level = Math.min(6, Math.max(1, Number(attributes.level) || 1));
      return `<h${level}>${inlineHtml(children)}</h${level}>`;
    }
    case "p":
      return `<p>${inlineHtml(children)}</p>`;
    case "list": {
      const tag = attributes.ordered === true ? "ol" : "ul";
      const start =
        tag === "ol" && typeof attributes.start === "number" && attributes.start !== 1
          ? ` start="${attributes.start}"`
          : "";
      return `<${tag}${start}>${blocks()}</${tag}>`;
    }
    case "li": {
      // An item's one paragraph is the item's own text, as editors write a tight list.
      const [first, ...rest] = children;
      const lead =
        first && typeof first !== "string" && parsed(first).kind === "p"
          ? inlineHtml(parsed(first).children)
          : first
            ? blockHtml(first)
            : "";
      return `<li>${lead}${rest.map(blockHtml).join("")}</li>`;
    }
    case "quote":
      return `<blockquote>${blocks()}</blockquote>`;
    case "pre": {
      const language = text(attributes.language).trim().split(/\s+/u)[0] ?? "";
      const name = language ? ` class="language-${attribute(language)}"` : "";
      return `<pre><code${name}>${escapeHtml(text(attributes.code))}</code></pre>`;
    }
    case "table": {
      const [header, ...rows] = children;
      const row = (value: MarkdownTreeNode | undefined) =>
        value === undefined || typeof value === "string"
          ? ""
          : blockHtml(["tr-row", parsed(value).children, parsed(value).attributes]);
      return `<table><thead>${row(header)}</thead><tbody>${rows.map(row).join("")}</tbody></table>`;
    }
    case "tr-row":
      return `<tr>${children.map(blockHtml).join("")}</tr>`;
    case "raw_block":
      return `<pre><code>${escapeHtml(text(attributes.markdown))}</code></pre>`;
    case "td": {
      const tag = attributes.header === true ? "th" : "td";
      const align =
        typeof attributes.align === "string" &&
        /^(?:left|center|right)$/u.test(attributes.align)
          ? ` style="text-align: ${attributes.align}"`
          : "";
      return `<${tag}${align}>${inlineHtml(children)}</${tag}>`;
    }
    case "hr":
      return "<hr>";
    case "mathblock":
      return `<pre><code>${escapeHtml(text(attributes.content).trim())}</code></pre>`;
    case "html_block":
      return `<pre><code>${escapeHtml(text(attributes.raw) || text(attributes.content))}</code></pre>`;
    case "footnote":
      return `<p><sup>[${escapeHtml(text(attributes.id))}]</sup> ${children
        .map((child) =>
          typeof child !== "string" && parsed(child).kind === "p"
            ? inlineHtml(parsed(child).children)
            : blockHtml(child)
        )
        .join(" ")}</p>`;
    default:
      return children.length ? `<p>${inlineHtml(children)}</p>` : "";
  }
}

/** The document as HTML for a rich editor's paste: structure in the tags alone, no script and no style sheet. */
export const documentHtml = (tree: MarkdownTree) =>
  `<meta charset="utf-8">${documentBodyHtml(tree)}`;

/** The document's blocks as HTML, for a page of the app that draws them itself. */
export const documentBodyHtml = (tree: MarkdownTree) => tree.map(blockHtml).join("");
