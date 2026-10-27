// The Markdown a chat message carries (`ChatMessage.markdown`): the parsed document as a compact tree, so no client
// parses a message itself. Text is itself; any other node is `[kind, children?, attributes?]`, its attributes only
// what tells it apart (no source text, no default values). An application element is `["comma-inline",
// { key }]`, the key naming the message part it stands for (`elementKey`). Measured on real replies the tree is about
// as long as the text it came from.
//
// `fromMarkdownTree` gives back the nodes the parser made, with their text as their source, for a renderer that
// draws those.
import type { MarkdownDocumentNodes, MarkdownNode } from "./document.ts";
import { markdownNodeAttribute, trustedInlineTag } from "./document.ts";

export type MarkdownTreeNode =
  | string
  | [kind: string]
  | [kind: string, children: MarkdownTreeNode[]]
  | [kind: string, attributes: Record<string, unknown>]
  | [kind: string, children: MarkdownTreeNode[], attributes: Record<string, unknown>];

export type MarkdownTree = MarkdownTreeNode[];

/** The tree's names for the parser's node kinds (others keep theirs), the way HTML names them where it does. */
export const MARKDOWN_KINDS: Record<string, string> = {
  paragraph: "p",
  heading: "h",
  strong: "b",
  emphasis: "i",
  strikethrough: "s",
  inline_code: "code",
  code_block: "pre",
  link: "a",
  image: "img",
  list_item: "li",
  blockquote: "quote",
  table_row: "tr",
  table_cell: "td",
  thematic_break: "hr",
  hardbreak: "br",
  math_inline: "math",
  math_block: "mathblock",
};
const PARSER_KINDS = Object.fromEntries(
  Object.entries(MARKDOWN_KINDS).map(([parser, tree]) => [tree, parser])
);

/** Fields the tree does not carry: source text, parse state, and where the children are. */
const OMITTED = new Set([
  "type",
  "raw",
  "center",
  "autoClosed",
  "children",
  "items",
  "rows",
  "cells",
]);
/** Nodes whose source is all they show: the tree keeps it. */
const SOURCE_SHOWN = new Set(["html_block", "html_inline"]);

export function toMarkdownTree(
  nodes: MarkdownDocumentNodes | readonly MarkdownNode[]
): MarkdownTree {
  return (nodes as readonly MarkdownNode[]).map(toTreeNode);
}

function toTreeNode(node: MarkdownNode): MarkdownTreeNode {
  if (node.type === "text") return typeof node.content === "string" ? node.content : "";
  if (node.commaTrustedInline === true)
    return [trustedInlineTag, { key: markdownNodeAttribute(node, "data-key") ?? "" }];
  const attributes: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(node)) {
    if (
      OMITTED.has(name) ||
      // A table's header row is a child; a cell's `header` flag is kept.
      (name === "header" && typeof value === "object") ||
      value === undefined ||
      value === null ||
      value === false ||
      value === ""
    )
      continue;
    // A heading's or a link's text is its children's.
    if (name === "text" && Array.isArray(node.children)) continue;
    // HTML attributes the node already has as its own fields (a link's `href`, an image's `src`).
    if (name === "attrs" && repeatsFields(node, value)) continue;
    attributes[name] = value;
  }
  if (SOURCE_SHOWN.has(node.type) && typeof node.raw === "string")
    attributes.raw = node.raw;
  const children = childrenOf(node)?.map(toTreeNode);
  const attributed = Object.keys(attributes).length > 0;
  const kind = MARKDOWN_KINDS[node.type] ?? node.type;
  if (children) return attributed ? [kind, children, attributes] : [kind, children];
  return attributed ? [kind, attributes] : [kind];
}

function repeatsFields(node: MarkdownNode, attrs: unknown): boolean {
  return (
    Array.isArray(attrs) &&
    attrs.every(
      (attr) =>
        Array.isArray(attr) && typeof attr[0] === "string" && node[attr[0]] === attr[1]
    )
  );
}

/** Where a node's children are: a list's items, a table's header row then its rows, a row's cells. */
function childrenOf(node: MarkdownNode): MarkdownNode[] | undefined {
  if (node.type === "list" && Array.isArray(node.items))
    return node.items as MarkdownNode[];
  if (node.type === "table")
    return [
      ...(node.header ? [node.header as MarkdownNode] : []),
      ...((Array.isArray(node.rows) ? node.rows : []) as MarkdownNode[]),
    ];
  if (node.type === "table_row" && Array.isArray(node.cells))
    return node.cells as MarkdownNode[];
  return Array.isArray(node.children) ? node.children : undefined;
}

export function fromMarkdownTree(tree: MarkdownTree): MarkdownDocumentNodes {
  return tree.map(fromTreeNode) as unknown as MarkdownDocumentNodes;
}

function fromTreeNode(node: MarkdownTreeNode): MarkdownNode {
  if (typeof node === "string")
    return { type: "text", content: node, raw: node, center: false };
  const [kind, first, second] = node;
  const type = PARSER_KINDS[kind] ?? kind;
  const children = Array.isArray(first) ? first : undefined;
  const attributes = (Array.isArray(first) ? second : first) ?? {};
  if (type === trustedInlineTag) {
    const key = typeof attributes.key === "string" ? attributes.key : "";
    return {
      commaTrustedInline: true,
      attrs: [["data-key", key]],
      autoClosed: false,
      children: [],
      content: "",
      loading: false,
      raw: `<${trustedInlineTag} data-key="${key}"></${trustedInlineTag}>`,
      tag: trustedInlineTag,
      type,
    };
  }
  const nested = (children ?? []).map(fromTreeNode);
  const out: MarkdownNode = {
    type,
    ...attributes,
    raw: sourceOf(type, attributes, nested),
    // Still being parsed (a reply streaming in): a fence not closed, a table not ended.
    loading: attributes.loading === true,
  };
  if (type === "list") out.items = nested;
  else if (type === "table") {
    out.header = nested[0];
    out.rows = nested.slice(1);
  } else if (type === "table_row") out.cells = nested;
  else if (children) out.children = nested;
  if ((type === "heading" || type === "link") && children) out.text = textOf(nested);
  return out;
}

/** A node's source as a renderer may fall back to it: what it shows. */
function sourceOf(
  type: string,
  attributes: Record<string, unknown>,
  children: MarkdownNode[]
): string {
  if (typeof attributes.raw === "string") return attributes.raw;
  for (const field of ["code", "content"])
    if (typeof attributes[field] === "string") return attributes[field] as string;
  return type === "hardbreak" ? "\n" : textOf(children);
}

function textOf(nodes: MarkdownNode[]): string {
  return nodes.map((node) => (typeof node.raw === "string" ? node.raw : "")).join("");
}

/** Whether the tree is one code block and nothing else: a message that is only code. */
export function isCodeBlockOnly(tree: MarkdownTree): boolean {
  const [only] = tree;
  return (
    tree.length === 1 && Array.isArray(only) && only[0] === MARKDOWN_KINDS.code_block
  );
}

/** The application elements a tree shows, by key: those a part put there and the parse kept. */
export function markdownTreeElements(tree: MarkdownTree): Set<string> {
  const keys = new Set<string>();
  const visit = (node: MarkdownTreeNode) => {
    if (typeof node === "string") return;
    const [kind, first, second] = node;
    const attributes = (Array.isArray(first) ? second : first) ?? {};
    if (kind === trustedInlineTag && typeof attributes.key === "string")
      keys.add(attributes.key);
    if (Array.isArray(first)) first.forEach(visit);
  };
  tree.forEach(visit);
  return keys;
}
