// Markdown text as the nodes every renderer draws (the kinds `tree.ts` names): parsed whole, or as it grows (a reply
// streaming in). A growing document is Incremark's: a block that can no longer change is parsed once and kept, and
// only the blocks after it are parsed again. Until the text is final, its last block is read as if what it opened
// were closed (a fence, a `$$` block, a link, a code span, emphasis), the nodes still open marked `loading`.
import {
  createIncremarkParser,
  type IncremarkParser,
  type ParsedBlock,
} from "@incremark/core";
import { decodeCharacterReferences } from "./entities.ts";
import { hasKeptSpaces, keptSpaces, MarkdownAstBuilder } from "./syntax.ts";

export type MarkdownNode = {
  type: string;
  raw: string;
  loading?: boolean;
  children?: MarkdownNode[];
} & Record<string, unknown>;

/** A node of the syntax tree (mdast), read loosely: the builder adds kinds of its own. */
type Syntax = {
  type: string;
  children?: Syntax[];
  value?: string;
  position?: { start: { offset?: number }; end: { offset?: number } };
} & Record<string, unknown>;

type Definitions = ReadonlyMap<string, { url: string; title: string | null }>;

type Reading = {
  definitions: Definitions;
  footnotes: MarkdownNode[];
};

// A builder keeps the link definitions it has read: each document is read by its own.
const syntaxOf = (text: string) =>
  new MarkdownAstBuilder().parse(text).children as unknown as Syntax[];

/** The nodes of a whole document. */
export function parseMarkdown(text: string): MarkdownNode[] {
  const syntax = syntaxOf(text);
  const reading: Reading = { definitions: definitionsOf(syntax), footnotes: [] };
  return withFootnotes(
    syntax.flatMap((node) => rootNode(node, text, reading)),
    reading.footnotes
  );
}

/** One growing document's parse, kept between its versions. */
export class IncrementalMarkdown {
  #parser: IncremarkParser = createIncremarkParser({ astBuilder: MarkdownAstBuilder });
  #text = "";
  #final = false;
  #pending: ParsedBlock[] = [];
  #nodes: MarkdownNode[] = [];
  /** The settled blocks' nodes, kept while the definitions they were read with are the same. */
  #settled = new WeakMap<
    ParsedBlock,
    { nodes: MarkdownNode[]; footnotes: MarkdownNode[] }
  >();
  #definitionsKey = "";

  /** Forgets what was parsed: the next document starts afresh. */
  reset(): void {
    this.#parser.reset();
    this.#text = "";
    this.#final = false;
    this.#pending = [];
    this.#nodes = [];
  }

  parse({ content, final }: { content: string; final: boolean }): MarkdownNode[] {
    if (content === this.#text && final === this.#final && this.#text !== "")
      return this.#nodes;
    if (this.#final || !content.startsWith(this.#text)) this.reset();
    const added = content.slice(this.#text.length);
    if (added !== "" || this.#text === "")
      this.#pending = this.#parser.append(added).pending;
    if (final) {
      this.#parser.finalize();
      this.#pending = [];
    }
    this.#text = content;
    this.#final = final;
    this.#nodes = this.#read();
    return this.#nodes;
  }

  #read(): MarkdownNode[] {
    const settled = this.#parser.getCompletedBlocks();
    // Every definition so far, a block still open included: a reference above links once its definition arrives.
    const definitions = definitionsOf(
      [...settled, ...this.#pending].map((parsed) => parsed.node as unknown as Syntax)
    );
    const definitionsKey = JSON.stringify([...definitions]);
    if (definitionsKey !== this.#definitionsKey) {
      this.#settled = new WeakMap();
      this.#definitionsKey = definitionsKey;
    }
    const nodes: MarkdownNode[] = [];
    const footnotes: MarkdownNode[] = [];
    for (const parsed of settled) {
      let read = this.#settled.get(parsed);
      if (!read) {
        const reading: Reading = { definitions, footnotes: [] };
        read = {
          nodes: root(parsed.node as unknown as Syntax, reading, blockSource(parsed)),
          footnotes: reading.footnotes,
        };
        this.#settled.set(parsed, read);
      }
      nodes.push(...read.nodes);
      footnotes.push(...read.footnotes);
    }
    const reading: Reading = { definitions, footnotes };
    this.#pending.forEach((pending, index) =>
      nodes.push(
        ...(index === this.#pending.length - 1
          ? openBlock(pending, reading)
          : root(pending.node as unknown as Syntax, reading, blockSource(pending)))
      )
    );
    return withFootnotes(nodes, footnotes);
  }
}

const blockSource = (parsed: ParsedBlock) => parsed.rawText.replace(/\n+$/, "");

/** The last block of a document not yet final: read with what it opened closed, those nodes `loading`. */
function openBlock(parsed: ParsedBlock, reading: Reading): MarkdownNode[] {
  const text = parsed.rawText;
  const fence = /^ {0,3}(`{3,}|~{3,})/.exec(text);
  if (fence) {
    const nodes = root(parsed.node as unknown as Syntax, reading, blockSource(parsed));
    const closed = new RegExp(
      `\\n {0,3}${fence[1]![0]}{${fence[1]!.length},}[ \\t]*\\n*$`
    ).test(text);
    if (!closed) markLast(nodes, "code_block");
    return nodes;
  }
  if (/^ {0,3}\$\$/.test(text) && !text.trimStart().slice(2).includes("$$")) {
    const nodes = parseRoot(`${text.trimEnd()}\n$$`, reading);
    markLast(nodes, "math_block");
    return nodes;
  }
  const { closers, openLink, openMath } = openMarkup(text);
  if (closers === "")
    return root(parsed.node as unknown as Syntax, reading, blockSource(parsed));
  const nodes = parseRoot(text + closers, reading);
  // An image's address still streaming is not one to load.
  if (openLink) markLast(nodes, openLink);
  if (openMath) markLast(nodes, "math_inline");
  return nodes;
}

function parseRoot(text: string, reading: Reading) {
  return syntaxOf(text).flatMap((node) => rootNode(node, text, reading));
}

/**
 * What closes the inline markup still open at the end of a block's text: a code span, `$` math, a link's
 * or an image's destination, strikethrough and emphasis, innermost first.
 */
function openMarkup(text: string) {
  const open: string[] = [];
  let index = 0;
  while (index < text.length) {
    const top = open.at(-1);
    if (top === "`") {
      const end = text.indexOf("`", index);
      if (end < 0) break;
      open.pop();
      index = end + 1;
      continue;
    }
    if (top === "$") {
      const end = text.indexOf("$", index);
      if (end < 0) break;
      open.pop();
      index = end + 1;
      continue;
    }
    const char = text[index]!;
    if (char === "\\") {
      index += 2;
      continue;
    }
    if (char === "`") {
      const run = /^`+/.exec(text.slice(index))![0];
      const end = text.indexOf(run, index + run.length);
      if (end < 0) {
        open.push(run.length === 1 ? "`" : run);
        if (run.length > 1) break;
        index += 1;
        continue;
      }
      index = end + run.length;
      continue;
    }
    if (char === "$") {
      if (text[index + 1] === "$") {
        index += 2;
        continue;
      }
      if (/[^\s\d$]/.test(text[index + 1] ?? " ")) open.push("$");
      index += 1;
      continue;
    }
    const delimiter = text.startsWith("**", index)
      ? "**"
      : text.startsWith("~~", index)
        ? "~~"
        : char === "*"
          ? "*"
          : undefined;
    if (delimiter) {
      const before = text[index - 1] ?? "\n";
      const after = text[index + delimiter.length] ?? "\n";
      if (top === delimiter && !/\s/.test(before)) open.pop();
      else if (
        !/\s/.test(after) &&
        !(delimiter === "*" && /^[ \t]*$/.test(lineBefore(text, index)))
      )
        open.push(delimiter);
      index += delimiter.length;
      continue;
    }
    index += 1;
  }
  const destination = /(!?)\[[^\]\n]*\]\([^)\s]*$/.exec(text);
  const openLink = destination ? (destination[1] ? "image" : "link") : undefined;
  const closers = (openLink ? ")" : "") + open.toReversed().join("");
  return { closers, openLink, openMath: open.includes("$") };
}

const lineBefore = (text: string, index: number) =>
  text.slice(text.lastIndexOf("\n", index - 1) + 1, index);

function markLast(nodes: MarkdownNode[], type: string): boolean {
  for (let index = nodes.length - 1; index >= 0; index -= 1) {
    const node = nodes[index]!;
    for (const key of ["items", "children", "cells", "rows"]) {
      const children = node[key];
      if (Array.isArray(children) && markLast(children as MarkdownNode[], type))
        return true;
    }
    if (node.type === type) {
      node.loading = true;
      if (type === "code_block" && typeof node.code === "string")
        node.code = node.code.replace(/\n$/, "");
      return true;
    }
  }
  return false;
}

function definitionsOf(syntax: readonly Syntax[]): Definitions {
  const definitions = new Map<string, { url: string; title: string | null }>();
  for (const node of syntax) {
    const label = labelOf(node);
    if (node.type === "definition" && !definitions.has(label))
      definitions.set(label, {
        url: node.url as string,
        title: (node.title as string | null) ?? null,
      });
  }
  return definitions;
}

/** A reference's label as CommonMark matches it: case and runs of white space do not count. */
const labelOf = (node: Syntax) =>
  String(node.label ?? node.identifier ?? "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();

function withFootnotes(nodes: MarkdownNode[], footnotes: MarkdownNode[]) {
  return footnotes.length === 0 ? nodes : [...nodes, ...footnotes];
}

/** A root block: its source is the text it was parsed from, from its offset there. */
function rootNode(node: Syntax, text: string, reading: Reading): MarkdownNode[] {
  const start = node.position?.start.offset;
  const end = node.position?.end.offset;
  const raw =
    start === undefined || end === undefined
      ? undefined
      : text.slice(start, end).replace(/\n+$/, "");
  return root(node, reading, raw ?? text);
}

/** A root block read from `source`, its no-break and zero-width spaces as written. */
function root(node: Syntax, reading: Reading, source: string): MarkdownNode[] {
  const footnotes = reading.footnotes.length;
  const nodes = block(node, reading, source);
  if (!hasKeptSpaces(source)) return nodes;
  reading.footnotes.push(
    ...(restoreSpaces(reading.footnotes.splice(footnotes)) as MarkdownNode[])
  );
  return restoreSpaces(nodes) as MarkdownNode[];
}

const restoreSpaces = (value: unknown): unknown =>
  typeof value === "string"
    ? keptSpaces(value)
    : Array.isArray(value)
      ? value.map(restoreSpaces)
      : value && typeof value === "object"
        ? Object.fromEntries(
            Object.entries(value).map(([key, field]) => [key, restoreSpaces(field)])
          )
        : value;

function blocks(
  nodes: readonly Syntax[] | undefined,
  reading: Reading
): MarkdownNode[] {
  return (nodes ?? []).flatMap((node) => block(node, reading));
}

function block(node: Syntax, reading: Reading, source?: string): MarkdownNode[] {
  switch (node.type) {
    case "paragraph": {
      const children = lines(phrasing(node.children, reading));
      return [{ type: "paragraph", children, raw: source ?? textOf(children) }];
    }
    case "heading": {
      const children = lines(phrasing(node.children, reading));
      const text = textOf(children);
      return [
        { type: "heading", level: node.depth, text, children, raw: source ?? text },
      ];
    }
    case "thematicBreak":
      return [{ type: "thematic_break", raw: source ?? "---" }];
    case "blockquote": {
      const children = blocks(node.children, reading);
      return [{ type: "blockquote", children, raw: source ?? textOf(children) }];
    }
    case "list": {
      const items = (node.children ?? []).map((item) => listItem(item, reading));
      const start =
        node.ordered && node.start !== 1 ? (node.start as number) : undefined;
      return [
        {
          type: "list",
          ordered: node.ordered === true,
          start,
          items,
          raw: source ?? textOf(items),
        },
      ];
    }
    case "code": {
      const code = `${node.value ?? ""}\n`;
      return [
        {
          type: "code_block",
          language: (node.lang as string | null) ?? "",
          code,
          raw: source ?? code,
        },
      ];
    }
    case "math": {
      const opening = source?.trimStart() ?? "";
      const markup = opening.startsWith("\\[")
        ? "\\[\\]"
        : opening.startsWith("[")
          ? "[]"
          : "$$";
      return [
        { type: "math_block", content: node.value ?? "", markup, raw: source ?? "" },
      ];
    }
    case "html":
      return [htmlBlock((node.value ?? "").replace(/\n+$/, ""))];
    case "table": {
      const align = (node.align as (string | null)[] | undefined) ?? [];
      const rows = (node.children ?? []).map((row, index) => ({
        type: "table_row",
        cells: (row.children ?? []).map((cell, column) => {
          const children = lines(phrasing(cell.children, reading));
          return {
            type: "table_cell",
            header: index === 0,
            align: align[column] ?? "left",
            children,
            raw: textOf(children),
          };
        }),
        raw: "",
      }));
      return [
        { type: "table", header: rows[0], rows: rows.slice(1), raw: source ?? "" },
      ];
    }
    case "footnoteDefinition": {
      const id = node.identifier as string;
      const children = blocks(node.children, reading);
      const last = children.at(-1);
      const anchor = { type: "footnote_anchor", id, raw: "" };
      if (last?.type === "paragraph")
        last.children = [...(last.children ?? []), anchor];
      else children.push({ type: "paragraph", children: [anchor], raw: "" });
      reading.footnotes.push({ type: "footnote", id, children, raw: source ?? "" });
      return [];
    }
    case "definition":
      return [];
    case "containerDirective": {
      const name = String(node.name);
      const children = blocks(node.children, reading);
      if (!ADMONITIONS.has(name))
        return [
          { type: "vmr_container", name, children, raw: source ?? textOf(children) },
        ];
      const title =
        Object.keys((node.attributes as Record<string, string> | undefined) ?? {}).join(
          " "
        ) || name[0]!.toUpperCase() + name.slice(1);
      return [
        {
          type: "admonition",
          kind: name,
          title,
          children,
          raw: source ?? textOf(children),
        },
      ];
    }
    default: {
      const children = phrasing(node.children, reading);
      return children.length > 0
        ? [{ type: "paragraph", children, raw: textOf(children) }]
        : [];
    }
  }
}

const ADMONITIONS = new Set(["warning", "info", "note", "tip", "danger", "caution"]);

function listItem(node: Syntax, reading: Reading): MarkdownNode {
  const children = blocks(node.children, reading);
  if (typeof node.checked === "boolean") {
    const box: MarkdownNode = {
      type: "checkbox_input",
      checked: node.checked,
      raw: "",
    };
    const first = children[0];
    if (first?.type === "paragraph") {
      const [text, ...rest] = first.children ?? [];
      first.children =
        text?.type === "text"
          ? [box, textNode(` ${String(text.content)}`), ...rest]
          : [box, ...(first.children ?? [])];
    } else children.unshift({ type: "paragraph", children: [box], raw: "" });
  }
  return { type: "list_item", children, raw: textOf(children) };
}

const HTML_TAG = /^<\s*\/?\s*([A-Za-z][\w-]*)/;
const HTML_ATTRIBUTE =
  /([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
const VOID_TAGS = new Set([
  "area",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "source",
  "track",
  "wbr",
]);

function htmlBlock(content: string): MarkdownNode {
  const tag = HTML_TAG.exec(content)?.[1]?.toLowerCase() ?? "";
  const opening = tag ? (/^<[^>]*>/.exec(content)?.[0] ?? "") : "";
  const attrs = [
    ...opening
      .slice(1 + tag.length)
      .replace(/\/?>$/, "")
      .matchAll(HTML_ATTRIBUTE),
  ].map(
    (match) => [match[1]!, match[2] ?? match[3] ?? match[4] ?? ""] as [string, string]
  );
  return {
    type: "html_block",
    content,
    tag,
    ...(attrs.length > 0 ? { attrs } : {}),
    raw: content,
  };
}

function phrasing(
  nodes: readonly Syntax[] | undefined,
  reading: Reading
): MarkdownNode[] {
  const out: MarkdownNode[] = [];
  for (const node of nodes ?? [])
    for (const next of inline(node, reading)) {
      const previous = out.at(-1);
      if (next.type === "text" && previous?.type === "text") {
        previous.content = `${String(previous.content)}${String(next.content)}`;
        previous.raw = previous.content as string;
      } else if (next.type !== "text" || next.content !== "") out.push(next);
    }
  return pairHtml(out);
}

/** A block's text without the spaces that begin or end its lines, as CommonMark reads them. */
function lines(nodes: MarkdownNode[]): MarkdownNode[] {
  nodes.forEach((node, index) => {
    if (node.type !== "text") return;
    let content = String(node.content).replace(/[ \t]*\n[ \t]*/g, "\n");
    if (index === 0) content = content.replace(/^[ \t]+/, "");
    if (index === nodes.length - 1) content = content.replace(/[ \t]+$/, "");
    node.content = content;
    node.raw = content;
  });
  return nodes.filter((node) => node.type !== "text" || node.content !== "");
}

function inline(node: Syntax, reading: Reading): MarkdownNode[] {
  switch (node.type) {
    case "text":
      return [textNode(node.value ?? "")];
    case "strong":
    case "emphasis":
    case "delete":
    case "highlight":
    case "insert":
    case "subscript":
    case "superscript": {
      const children = phrasing(node.children, reading);
      const type = node.type === "delete" ? "strikethrough" : node.type;
      return [{ type, children, raw: textOf(children) }];
    }
    case "inlineCode":
      return [{ type: "inline_code", code: node.value ?? "", raw: node.value ?? "" }];
    case "break":
      return [{ type: "hardbreak", raw: "\n" }];
    case "link":
      return [
        link(
          node.url as string,
          node.title as string | null,
          phrasing(node.children, reading)
        ),
      ];
    case "image":
      return [
        image(
          node.url as string,
          node.alt as string | null,
          node.title as string | null
        ),
      ];
    case "linkReference":
    case "imageReference": {
      const definition = reading.definitions.get(labelOf(node));
      const label =
        node.type === "imageReference"
          ? [textNode(String(node.alt ?? ""))]
          : phrasing(node.children, reading);
      if (definition)
        return node.type === "imageReference"
          ? [image(definition.url, textOf(label), definition.title)]
          : [link(definition.url, definition.title, label)];
      // Not defined: the text it was written as.
      const reference =
        node.referenceType === "full"
          ? `[${String(node.label ?? node.identifier)}]`
          : node.referenceType === "collapsed"
            ? "[]"
            : "";
      return [
        textNode(node.type === "imageReference" ? "!" : ""),
        textNode("["),
        ...label,
        textNode(`]${reference}`),
      ];
    }
    case "footnoteReference":
      return [
        {
          type: "footnote_reference",
          id: node.identifier,
          raw: `[^${String(node.identifier)}]`,
        },
      ];
    case "inlineMath":
      return [
        {
          type: "math_inline",
          content: node.value ?? "",
          markup: (node.data as { markup?: string } | undefined)?.markup ?? "$",
          raw: node.value ?? "",
        },
      ];
    case "html": {
      const value = node.value ?? "";
      if (/^<br\s*\/?>$/i.test(value)) return [{ type: "hardbreak", raw: "\n" }];
      return [htmlInline(value, [])];
    }
    default:
      return node.children
        ? phrasing(node.children, reading)
        : node.value
          ? [textNode(node.value)]
          : [];
  }
}

function htmlInline(content: string, children: MarkdownNode[]): MarkdownNode {
  const tag = HTML_TAG.exec(content)?.[1]?.toLowerCase() ?? "";
  return { type: "html_inline", tag, content, children, raw: content };
}

/**
 * An opening tag and its closing tag later in the same run: one HTML node around what is between them. A tag left
 * without its other half is text, as written.
 */
function pairHtml(nodes: MarkdownNode[]): MarkdownNode[] {
  if (!nodes.some((node) => node.type === "html_inline")) return nodes;
  const out: MarkdownNode[] = [];
  const push = (node: MarkdownNode) => {
    const previous = out.at(-1);
    if (node.type === "text" && previous?.type === "text") {
      previous.content = `${String(previous.content)}${String(node.content)}`;
      previous.raw = previous.content as string;
    } else out.push(node);
  };
  for (let index = 0; index < nodes.length; index += 1) {
    const node = nodes[index]!;
    const content = String(node.content ?? "");
    const tag = node.tag as string;
    const whole = !tag || content.endsWith("/>") || VOID_TAGS.has(tag);
    if (node.type === "html_inline" && !whole && !content.startsWith("</")) {
      const close = nodes.findIndex(
        (candidate, at) =>
          at > index &&
          candidate.type === "html_inline" &&
          new RegExp(`^<\\s*/\\s*${tag}\\s*>$`, "i").test(String(candidate.content))
      );
      if (close > index) {
        const inner = nodes.slice(index + 1, close);
        out.push(
          htmlInline(
            content + inner.map(sourceOf).join("") + String(nodes[close]!.content),
            inner
          )
        );
        index = close;
        continue;
      }
    }
    push(node.type === "html_inline" && !whole ? textNode(content) : node);
  }
  return out;
}

/** A destination as a URL: characters a URL cannot hold percent-encoded, those already encoded kept. */
const encodeUrl = (url: string) =>
  url.replace(/%(?![0-9A-Fa-f]{2})|[^\w;,/?:@&=+$\-.!~*'()#%[\]]/gu, (char) =>
    encodeURIComponent(char)
  );

function link(
  url: string,
  title: string | null,
  children: MarkdownNode[]
): MarkdownNode {
  const text = textOf(children);
  return {
    type: "link",
    href: encodeUrl(decodeCharacterReferences(url)),
    title: title === null ? null : decodeCharacterReferences(title),
    text,
    children,
    raw: text,
  };
}

function image(url: string, alt: string | null, title: string | null): MarkdownNode {
  return {
    type: "image",
    src: encodeUrl(decodeCharacterReferences(url)),
    alt: decodeCharacterReferences(alt ?? ""),
    title: title === null ? null : decodeCharacterReferences(title),
    raw: alt ?? "",
  };
}

const textNode = (content: string): MarkdownNode => ({
  type: "text",
  content,
  raw: content,
});

function sourceOf(node: MarkdownNode): string {
  if (node.type === "text") return String(node.content);
  if (node.type === "inline_code") return `\`${String(node.code)}\``;
  if (node.type === "html_inline") return String(node.content);
  return typeof node.raw === "string" ? node.raw : "";
}

function textOf(nodes: readonly MarkdownNode[]): string {
  return nodes.map((node) => (typeof node.raw === "string" ? node.raw : "")).join("");
}
