// One document made of Markdown text and application-owned elements (a chat message's Task chips and cards, a
// briefing's items), parsed as one so definitions and inline formatting keep their document-wide meaning; the
// elements' markers are then promoted to nodes of their own. Every client's Markdown goes through here.
import { parseMarkdown, type MarkdownNode } from "./parse.ts";

export type { MarkdownNode };

export type MarkdownDocumentFragment =
  | { type: "inline"; key: string }
  | { type: "block"; key: string }
  | { type: "markdown"; text: string };

export type MarkdownDocumentNodes = readonly MarkdownNode[];

export const trustedInlineTag = "comma-inline";
const trustedInlineMarkerStart = "\uE000";
const trustedInlineMarkerEnd = "\uE001";
const trustedInlineMarkerPattern = /\uE000([0-9A-Za-z_-]+)\uE001/g;
const trustedInlineArrayProperties = ["children", "items", "rows", "cells"];
const trustedInlineObjectProperties = ["header"];
const trustedInlineLiftContainers = new Set(["blockquote", "html_inline", "link"]);

type TrustedInlineValuePiece =
  | { type: "inline"; key: string }
  | { type: "text"; value: string };

/**
 * Parses the ordered fragments as one Markdown document so definitions and
 * inline formatting retain their document-wide semantics. Application-owned
 * inline markers are then promoted in the parsed tree. If Markdown placed a
 * marker in an opaque node (for example a code span, fence, HTML node, or link
 * destination), that node is split and the trusted element is lifted outside.
 */
export function documentNodes(
  fragments: readonly MarkdownDocumentFragment[]
): MarkdownDocumentNodes {
  const trustedKeys = new Set<string>();
  const blockKeys = new Set<string>();
  const source = fragments
    .map((fragment) => {
      if (fragment.type === "markdown") {
        return fragment.text
          .replaceAll(trustedInlineMarkerStart, "�")
          .replaceAll(trustedInlineMarkerEnd, "�");
      }
      validateTrustedInlineKey(fragment.key);
      trustedKeys.add(fragment.key);
      if (fragment.type === "block") {
        blockKeys.add(fragment.key);
        return `\n\n${trustedInlineMarker(fragment.key)}\n\n`;
      }
      return trustedInlineMarker(fragment.key);
    })
    .join("");
  const promoted = parseMarkdown(source).flatMap((node) =>
    promoteTrustedInlineNode(node, trustedKeys, false)
  );
  const blocks = promoted.flatMap((node) => {
    const children = nodeChildren(node);
    return node.type === "paragraph" &&
      children.length === 1 &&
      blockKeys.has(markdownNodeAttribute(children[0]!, "data-key") ?? "")
      ? children
      : [node];
  });
  return wrapRootTrustedInlineNodes(blocks, blockKeys);
}

function createTrustedInlineNode(key: string): MarkdownNode {
  validateTrustedInlineKey(key);
  const raw = `<${trustedInlineTag} data-key="${key}"></${trustedInlineTag}>`;
  return {
    commaTrustedInline: true,
    attrs: [["data-key", key]],
    autoClosed: false,
    children: [],
    content: "",
    loading: false,
    raw,
    tag: trustedInlineTag,
    type: trustedInlineTag,
  };
}

function validateTrustedInlineKey(key: string) {
  if (!/^[0-9A-Za-z_-]+$/.test(key)) {
    throw new Error("MarkdownStream inline keys must be opaque identifier strings.");
  }
}

function trustedInlineMarker(key: string) {
  return `${trustedInlineMarkerStart}${key}${trustedInlineMarkerEnd}`;
}

function promoteTrustedInlineNode(
  node: MarkdownNode,
  trustedKeys: ReadonlySet<string>,
  liftTrustedInline: boolean
): MarkdownNode[] {
  if (isTrustedInlineNode(node)) return [node];
  if (node.type === trustedInlineTag) return [markdownTextNode(asString(node.raw))];

  const opaque = splitOpaqueTrustedInlineNode(node, trustedKeys);
  if (opaque) return opaque;

  if (node.type === "text") {
    const value = asString(node.content) || asString(node.raw);
    const pieces = splitTrustedInlineValue(value, trustedKeys);
    if (pieces.some((piece) => piece.type === "inline")) {
      return pieces.flatMap((piece) =>
        piece.type === "inline"
          ? [createTrustedInlineNode(piece.key)]
          : piece.value
            ? [{ ...node, content: piece.value, raw: piece.value }]
            : []
      );
    }
  }

  const childNodes = markdownNodeChildren(node);
  if (!childNodes.some((child) => markdownNodeHasTrustedMarker(child, trustedKeys))) {
    const raw = firstTrustedMarkerString(node, trustedKeys);
    if (raw) return trustedValueAsTextNodes(raw, trustedKeys);
  }

  const mustLift = liftTrustedInline || trustedInlineLiftContainers.has(node.type);
  let variants: MarkdownNode[] = [scrubTrustedMarkersFromNode(node, trustedKeys)];

  for (const property of trustedInlineArrayProperties) {
    variants = variants.flatMap((variant) => {
      const value = variant[property];
      if (!Array.isArray(value) || !value.some(isDocumentMarkdownNode)) {
        return [variant];
      }
      const transformed = (value as MarkdownNode[]).flatMap((child) =>
        promoteTrustedInlineNode(child, trustedKeys, mustLift)
      );
      if (mustLift && transformed.some(isTrustedInlineNode)) {
        return splitContainerAtTrustedInline(variant, property, transformed);
      }
      return [{ ...variant, [property]: transformed }];
    });
  }

  for (const property of trustedInlineObjectProperties) {
    variants = variants.flatMap((variant) => {
      const value = variant[property];
      if (!isDocumentMarkdownNode(value)) return [variant];
      const transformed = promoteTrustedInlineNode(value, trustedKeys, mustLift);
      if (mustLift && transformed.some(isTrustedInlineNode)) {
        return transformed.map((piece) =>
          isTrustedInlineNode(piece) ? piece : { ...variant, [property]: piece }
        );
      }
      return transformed.length === 1
        ? [{ ...variant, [property]: transformed[0] }]
        : [variant];
    });
  }

  return variants;
}

function splitOpaqueTrustedInlineNode(
  node: MarkdownNode,
  trustedKeys: ReadonlySet<string>
): MarkdownNode[] | undefined {
  if (node.type === "code_block") {
    const language = asString(node.language);
    if (hasTrustedInlineMarker(language, trustedKeys)) {
      const pieces = splitTrustedInlineValue(language, trustedKeys);
      return pieces.flatMap((piece, index): MarkdownNode[] => {
        if (piece.type === "inline") return [createTrustedInlineNode(piece.key)];
        const hasInlineAfter = pieces
          .slice(index + 1)
          .some((candidate) => candidate.type === "inline");
        const next = cloneCodeBlock(
          node,
          piece.value,
          hasInlineAfter ? "" : asString(node.code)
        );
        if (!piece.value && !next.code) return [];
        return hasInlineAfter
          ? [next]
          : (splitOpaqueTrustedInlineNode(next, trustedKeys) ?? [next]);
      });
    }

    const code = asString(node.code) || asString(node.raw);
    if (hasTrustedInlineMarker(code, trustedKeys)) {
      return splitTrustedInlineValue(code, trustedKeys).flatMap((piece) =>
        piece.type === "inline"
          ? [createTrustedInlineNode(piece.key)]
          : piece.value
            ? [cloneCodeBlock(node, language, piece.value)]
            : []
      );
    }
    return undefined;
  }

  const opaqueField =
    node.type === "inline_code"
      ? "code"
      : node.type === "html_block" || node.type === "html_inline"
        ? "content"
        : node.type === "math_block" || node.type === "math_inline"
          ? "content"
          : undefined;
  if (!opaqueField) return undefined;

  const value = asString(node[opaqueField]) || asString(node.raw);
  if (!hasTrustedInlineMarker(value, trustedKeys)) return undefined;
  return splitTrustedInlineValue(value, trustedKeys).flatMap((piece) => {
    if (piece.type === "inline") return [createTrustedInlineNode(piece.key)];
    if (!piece.value) return [];
    if (node.type === "inline_code") {
      return [{ ...node, code: piece.value, raw: piece.value }];
    }
    return [
      {
        ...node,
        children: [],
        content: piece.value,
        raw: piece.value,
      },
    ];
  });
}

function cloneCodeBlock(node: MarkdownNode, language: string, code: string) {
  return { ...node, code, language, raw: code } as MarkdownNode;
}

function splitContainerAtTrustedInline(
  node: MarkdownNode,
  property: string,
  children: MarkdownNode[]
) {
  const result: MarkdownNode[] = [];
  let run: MarkdownNode[] = [];
  const flush = () => {
    if (run.length > 0) result.push({ ...node, [property]: run });
    run = [];
  };
  children.forEach((child) => {
    if (isTrustedInlineNode(child)) {
      flush();
      result.push(child);
    } else {
      run.push(child);
    }
  });
  flush();
  return result;
}

function splitTrustedInlineValue(
  value: string,
  trustedKeys: ReadonlySet<string>
): TrustedInlineValuePiece[] {
  const pieces: TrustedInlineValuePiece[] = [];
  let offset = 0;
  for (const match of value.matchAll(trustedInlineMarkerPattern)) {
    const index = match.index;
    const key = match[1];
    if (!key || !trustedKeys.has(key)) continue;
    pieces.push({ type: "text", value: value.slice(offset, index) });
    pieces.push({ key, type: "inline" });
    offset = index + match[0].length;
  }
  pieces.push({ type: "text", value: value.slice(offset) });
  return pieces;
}

function hasTrustedInlineMarker(value: string, trustedKeys: ReadonlySet<string>) {
  return splitTrustedInlineValue(value, trustedKeys).some(
    (piece) => piece.type === "inline"
  );
}

function trustedValueAsTextNodes(value: string, trustedKeys: ReadonlySet<string>) {
  return splitTrustedInlineValue(value, trustedKeys).flatMap((piece) =>
    piece.type === "inline"
      ? [createTrustedInlineNode(piece.key)]
      : piece.value
        ? [markdownTextNode(piece.value)]
        : []
  );
}

function firstTrustedMarkerString(
  node: MarkdownNode,
  trustedKeys: ReadonlySet<string>
) {
  for (const property of ["raw", "content", "code", "href", "src", "title"]) {
    const value = node[property];
    if (typeof value === "string" && hasTrustedInlineMarker(value, trustedKeys)) {
      return value;
    }
  }
  return undefined;
}

function scrubTrustedMarkersFromNode(
  node: MarkdownNode,
  trustedKeys: ReadonlySet<string>
) {
  const next = { ...node };
  for (const property of ["raw", "content", "text"]) {
    const value = next[property];
    if (typeof value === "string" && hasTrustedInlineMarker(value, trustedKeys)) {
      next[property] = splitTrustedInlineValue(value, trustedKeys)
        .filter(
          (piece): piece is Extract<TrustedInlineValuePiece, { type: "text" }> =>
            piece.type === "text"
        )
        .map((piece) => piece.value)
        .join("");
    }
  }
  return next;
}

function markdownNodeChildren(node: MarkdownNode) {
  const children: MarkdownNode[] = [];
  for (const property of trustedInlineArrayProperties) {
    const value = node[property];
    if (Array.isArray(value)) {
      children.push(...value.filter(isDocumentMarkdownNode));
    }
  }
  for (const property of trustedInlineObjectProperties) {
    const value = node[property];
    if (isDocumentMarkdownNode(value)) children.push(value);
  }
  return children;
}

function markdownNodeHasTrustedMarker(
  node: MarkdownNode,
  trustedKeys: ReadonlySet<string>
): boolean {
  if (firstTrustedMarkerString(node, trustedKeys)) return true;
  return markdownNodeChildren(node).some((child) =>
    markdownNodeHasTrustedMarker(child, trustedKeys)
  );
}

function isDocumentMarkdownNode(value: unknown): value is MarkdownNode {
  return Boolean(
    value &&
    typeof value === "object" &&
    "type" in value &&
    typeof value.type === "string"
  );
}

function isTrustedInlineNode(node: MarkdownNode) {
  return node.commaTrustedInline === true;
}

function markdownTextNode(content: string): MarkdownNode {
  return { center: false, content, raw: content, type: "text" };
}

function wrapRootTrustedInlineNodes(
  nodes: MarkdownNode[],
  blockKeys = new Set<string>()
) {
  const result: MarkdownNode[] = [];
  let inlineRun: MarkdownNode[] = [];
  const flush = () => {
    if (inlineRun.length > 0) {
      result.push({ children: inlineRun, raw: "", type: "paragraph" });
    }
    inlineRun = [];
  };
  nodes.forEach((node) => {
    if (
      isTrustedInlineNode(node) &&
      blockKeys.has(markdownNodeAttribute(node, "data-key") ?? "")
    ) {
      flush();
      result.push(node);
      return;
    }
    if (isTrustedInlineNode(node)) {
      inlineRun.push(node);
      return;
    }
    flush();
    result.push(node);
  });
  flush();
  return result;
}

const asString = (value: unknown) => (typeof value === "string" ? value : "");

const isMarkdownNode = (value: unknown): value is MarkdownNode =>
  Boolean(
    value &&
    typeof value === "object" &&
    typeof (value as { type?: unknown }).type === "string"
  );

const nodeChildren = (node: MarkdownNode): MarkdownNode[] =>
  Array.isArray(node.children) ? node.children.filter(isMarkdownNode) : [];

/** An attribute of a node the parser read from HTML (`attrs`, as pairs or as named values). */
export function markdownNodeAttribute(node: MarkdownNode, name: string) {
  const attrs = node.attrs;
  if (Array.isArray(attrs)) {
    for (const attr of attrs) {
      if (Array.isArray(attr) && attr[0] === name) {
        return typeof attr[1] === "string" ? attr[1] : undefined;
      }
      if (
        attr &&
        typeof attr === "object" &&
        "name" in attr &&
        attr.name === name &&
        "value" in attr &&
        typeof attr.value === "string"
      ) {
        return attr.value;
      }
    }
    return undefined;
  }
  if (!attrs || typeof attrs !== "object") return undefined;
  const value = (attrs as Record<string, unknown>)[name];
  return typeof value === "string" ? value : undefined;
}
