import type {
  ComponentProps,
  CSSProperties,
  ElementType,
  MutableRefObject,
  ReactElement,
  ReactNode,
} from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  MathBlockNode,
  MathInlineNode,
  setCustomComponents,
  type NodeComponentProps,
  type NodeRendererProps,
  type RenderContext,
  type RenderNodeFn,
} from "markstream-react";
import {
  getMarkdown,
  parseMarkdownToStructure,
  type BaseNode,
  type MarkdownIt,
  type MarkdownToken,
  type ParseOptions,
} from "stream-markdown-parser";
import { componentsDark } from "../../tokens/colors";
import { Button } from "../Button";
import {
  CheckIcon,
  ChevronDownSmallIcon,
  ChevronTopSmallIcon,
  CopyIcon,
} from "../icons";
import { cx } from "../utils";
import { ScrollArea } from "../scroll-area";
import { renderCodeHighlightInWorker } from "./shikiHighlightWorkerClient";
import {
  highlightedCodeLines,
  type ShikiHighlightResult,
  type ShikiHighlightToken,
} from "./shikiHighlightTokens";
import { MarkdownDocumentRenderer } from "./MarkdownDocumentRenderer";
import type { MarkdownBlockPresentation } from "./blockPresentation";
import { createCoalescedAsyncRender } from "./coalescedAsyncRender";
import { configureMarkdownSyntax } from "./markdownSyntax";
import { createTextReveal, type TextReveal, type TextRevealLeaf } from "./textReveal";

type MarkdownNode = {
  type: string;
  raw?: string;
  loading?: boolean;
  children?: MarkdownNode[];
} & Record<string, unknown>;

type CommaNodeProps<TNode extends MarkdownNode = MarkdownNode> =
  NodeComponentProps<TNode>;

type MathBlockRenderNode = ComponentProps<typeof MathBlockNode>["node"];
type MathInlineRenderNode = ComponentProps<typeof MathInlineNode>["node"];
type MermaidMode = "preview" | "source";
type MermaidRenderResult = {
  svg?: string;
  bindFunctions?: (container: Element) => void;
};
type MermaidApi = {
  initialize?: (config: Record<string, unknown>) => void;
  render: (
    id: string,
    code: string
  ) => MermaidRenderResult | Promise<MermaidRenderResult>;
};
type MermaidModuleRecord = {
  default?: unknown;
  mermaid?: unknown;
  mermaidAPI?: unknown;
  initialize?: unknown;
  render?: unknown;
};
type CommaNodeComponent<TNode extends MarkdownNode = MarkdownNode> = (
  props: CommaNodeProps<TNode>
) => ReactNode;

type MarkdownStreamAnimation = "blur" | "fade" | "reveal" | "none";

interface CompleteBlurTextQueue {
  activeTextStart: number;
  animatedTextBoundaryRef: MutableRefObject<number>;
  textOffsetsByStreamKey: Map<string, { content: string; startOffset: number }>;
  textOffsetRef: MutableRefObject<number>;
  visibleTextCharacters: number;
}

export interface MarkdownStreamCodeBlockInfo {
  code: string;
  language: string;
  loading: boolean;
}

export interface MarkdownStreamClipboard {
  writeText(text: string): Promise<void>;
}

/**
 * Trusted application-owned elements embedded into a Markdown document.
 * Keys are local to one MarkdownStream instance and never carry resource IDs.
 */
export type MarkdownStreamInlineElements = ReadonlyMap<string, ReactNode>;

export type MarkdownStreamDocumentFragment =
  | { type: "inline"; key: string }
  | { type: "block"; key: string }
  | { type: "markdown"; text: string };

export type MarkdownStreamNodes = readonly BaseNode[];

const trustedInlineTag = "comma-inline";
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
export function createMarkdownStreamDocumentNodes(
  fragments: readonly MarkdownStreamDocumentFragment[]
): MarkdownStreamNodes {
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
  const markdown = configureMarkdownSyntax(
    getMarkdown("comma-trusted-inline-document", {
      customHtmlTags: [trustedInlineTag],
    })
  );
  const parsed = parseMarkdownToStructure(source, markdown, {
    customHtmlTags: [trustedInlineTag],
    final: true,
    streamParse: false,
  }) as MarkdownNode[];
  const promoted = parsed.flatMap((node) =>
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
  return wrapRootTrustedInlineNodes(blocks, blockKeys) as BaseNode[];
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

export interface MarkdownStreamBlurAnimationOptions {
  activeCharacters?: number;
  blurRadiusPx?: number;
  characterDelayMs?: number;
  durationMs?: number;
  initialOpacity?: number;
  translateYEm?: number;
}

type RequiredBlurAnimationOptions = Required<MarkdownStreamBlurAnimationOptions>;

export interface MarkdownStreamProps extends Omit<
  NodeRendererProps,
  | "content"
  | "customId"
  | "fade"
  | "final"
  | "indexKey"
  | "nodes"
  | "onCopy"
  | "renderCodeBlocksAsPre"
  | "smoothStreaming"
  | "typewriter"
> {
  content?: string;
  nodes?: NodeRendererProps["nodes"];
  final?: boolean;
  streamId?: string;
  className?: string;
  blockPresentation?: MarkdownBlockPresentation;
  animation?: MarkdownStreamAnimation;
  ensureBlurAnimation?: boolean;
  showCursor?: boolean;
  smoothStreaming?: NodeRendererProps["smoothStreaming"];
  showCodeBlockHeader?: boolean;
  showCodeBlockCopy?: boolean;
  maxAnimatedCharacters?: number;
  blurAnimation?: MarkdownStreamBlurAnimationOptions;
  renderCodeBlockHeader?: (info: MarkdownStreamCodeBlockInfo) => ReactNode;
  onCopyCode?: (info: MarkdownStreamCodeBlockInfo) => void;
  clipboard?: MarkdownStreamClipboard;
  inlineElements?: MarkdownStreamInlineElements;
  /** File documents cannot acquire resources from URLs embedded in their text. */
  documentResourcePolicy?: { onOpenLink: (url: string) => void };
}

const MarkdownDocumentResourceContext =
  createContext<MarkdownStreamProps["documentResourcePolicy"]>(undefined);

interface MarkdownStreamContextValue {
  animation: MarkdownStreamAnimation;
  completeBlurTextQueue?: CompleteBlurTextQueue | undefined;
  ensureBlurAnimation: boolean;
  final: boolean;
  isDark: boolean;
  settled: boolean;
  blurAnimation: RequiredBlurAnimationOptions;
  maxAnimatedCharacters: number;
  showCodeBlockHeader: boolean;
  showCodeBlockCopy: boolean;
  renderCodeBlockHeader?:
    | ((info: MarkdownStreamCodeBlockInfo) => ReactNode)
    | undefined;
  onCopyCode?: ((info: MarkdownStreamCodeBlockInfo) => void) | undefined;
  clipboard?: MarkdownStreamClipboard | undefined;
}

const emptyInlineElements: MarkdownStreamInlineElements = new Map();

const defaultContext: MarkdownStreamContextValue = {
  animation: "none",
  blurAnimation: {
    activeCharacters: 80,
    blurRadiusPx: 6,
    characterDelayMs: 10,
    durationMs: 280,
    initialOpacity: 0.28,
    translateYEm: 0.4,
  },
  ensureBlurAnimation: false,
  final: false,
  isDark: false,
  settled: false,
  maxAnimatedCharacters: 160,
  showCodeBlockHeader: true,
  showCodeBlockCopy: true,
};

const MarkdownStreamContext = createContext<MarkdownStreamContextValue>(defaultContext);
const MarkdownStreamAnimationVersionContext = createContext(0);
const MarkdownStreamTextRevealContext = createContext<TextReveal | null>(null);
const MarkdownStreamRevealRootContext = createContext<{
  leaves: Map<Text, TextRevealLeaf>;
  dirty: boolean;
} | null>(null);
const MarkdownStreamInsideLinkContext = createContext(false);
// Inline elements live in their own context: nearly every markdown node
// component subscribes to MarkdownStreamContext, so an inlineElements identity
// change must not invalidate the shared context value and re-render the whole
// document — only CommaInlineElementNode consumes this.
const MarkdownStreamInlineElementsContext =
  createContext<MarkdownStreamInlineElements>(emptyInlineElements);

/**
 * Wraps the anchor CommaLinkNode renders for an external http(s) link, e.g. in a
 * hover-preview trigger. `anchor` is the exact `<a>` element the node renders
 * without a decorator; returning it unchanged is the identity decoration.
 *
 * Finality guarantee: the decorator is only invoked once the stream is final,
 * so every `href` it sees is complete and never changes afterwards. While the
 * stream is still emitting, a partially-received href (e.g. `.../COMMA-1` en
 * route to `.../COMMA-151`) can already look like a valid link, so decorating it
 * would preview the wrong resource — and the wrap/no-wrap flip would remount
 * the anchor mid-hover. Streaming links always render as the bare anchor.
 */
export type MarkdownStreamLinkDecorator = (args: {
  anchor: ReactElement;
  href: string;
}) => ReactNode;

// Like inline elements, the decorator lives in its own context: only
// CommaLinkNode consumes it, so a decorator identity change re-renders link
// nodes alone instead of invalidating MarkdownStreamContext for the whole
// document.
export const MarkdownStreamLinkDecoratorContext = createContext<
  MarkdownStreamLinkDecorator | undefined
>(undefined);

const defaultBlurAnimation = defaultContext.blurAnimation;
const minBatchedCharacterFrameMs = 16;
const maxCatchUpCharactersPerFrame = 240;
const codeBlockCollapsedHeightPx = 480;
const codeBlockPreviewLineCount = 32;

const clampNumber = (
  value: number | undefined,
  fallback: number,
  min: number,
  max: number
) =>
  typeof value === "number" && Number.isFinite(value)
    ? Math.min(max, Math.max(min, value))
    : fallback;

const normalizeBlurAnimation = (
  options: MarkdownStreamBlurAnimationOptions | undefined
): RequiredBlurAnimationOptions => ({
  activeCharacters: Math.round(
    clampNumber(
      options?.activeCharacters,
      defaultBlurAnimation.activeCharacters,
      1,
      256
    )
  ),
  blurRadiusPx: clampNumber(
    options?.blurRadiusPx,
    defaultBlurAnimation.blurRadiusPx,
    0,
    32
  ),
  characterDelayMs: clampNumber(
    options?.characterDelayMs,
    defaultBlurAnimation.characterDelayMs,
    0,
    240
  ),
  durationMs: clampNumber(
    options?.durationMs,
    defaultBlurAnimation.durationMs,
    0,
    3000
  ),
  initialOpacity: clampNumber(
    options?.initialOpacity,
    defaultBlurAnimation.initialOpacity,
    0,
    1
  ),
  translateYEm: clampNumber(
    options?.translateYEm,
    defaultBlurAnimation.translateYEm,
    0,
    1
  ),
});

const isMarkdownNode = (value: unknown): value is MarkdownNode =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as { type?: unknown }).type === "string";

const nodeRenderSignatureCache = new WeakMap<object, string>();

const nodeRenderSignature = (node: MarkdownNode) => {
  const cached = nodeRenderSignatureCache.get(node);
  if (cached !== undefined) return cached;

  const signature =
    JSON.stringify(node, (_key, value: unknown) =>
      typeof value === "function" ? undefined : value
    ) ?? "";
  nodeRenderSignatureCache.set(node, signature);
  return signature;
};

const areCommaNodePropsEqual = (
  previous: CommaNodeProps<MarkdownNode>,
  next: CommaNodeProps<MarkdownNode>
) =>
  previous.indexKey === next.indexKey &&
  nodeRenderSignature(previous.node) === nodeRenderSignature(next.node) &&
  previous.ctx === next.ctx;

const memoCommaNode = <TNode extends MarkdownNode>(
  Component: CommaNodeComponent<TNode>
) =>
  memo(
    function CommaRegisteredNode(props: CommaNodeProps<TNode>) {
      // Markstream tries a fence language before its code_block mapping. Comma's
      // built-in AST names (notably `text`) are not custom language renderers.
      // Leave deliberate diagram/language registrations alone, and use the
      // document's code component when a fence collides with another AST name.
      if (
        props.node.type === "code_block" &&
        Component !== CommaCodeBlockNode &&
        Component !== CommaMermaidNode
      ) {
        const CodeComponent = (props.ctx?.customComponents?.code_block ??
          CommaCodeBlockNode) as CommaNodeComponent;
        return <CodeComponent {...props} />;
      }
      return <Component {...props} />;
    },
    areCommaNodePropsEqual as (
      previous: CommaNodeProps<TNode>,
      next: CommaNodeProps<TNode>
    ) => boolean
  );

const hasLoadingMarkdownNode = (node: MarkdownNode): boolean => {
  if (node.loading) return true;

  return Object.values(node).some((value) => {
    if (!Array.isArray(value)) return false;
    return value.some((item) => {
      if (isMarkdownNode(item)) return hasLoadingMarkdownNode(item);
      if (
        typeof item === "object" &&
        item !== null &&
        Array.isArray((item as { cells?: unknown }).cells)
      ) {
        return (item as { cells: unknown[] }).cells.some(
          (cell) => isMarkdownNode(cell) && hasLoadingMarkdownNode(cell)
        );
      }
      return false;
    });
  });
};

const completeBlurNodeTextContent = (node: MarkdownNode, final: boolean): string => {
  if (node.type === "code_block") return codeBlockContent(node);
  if (node.type === "footnote") {
    if (final) return nodeTextContent(node);
    return `[${asString(node.id)}]${nodeTextContent(node)}^`;
  }
  if (node.type === "footnote_ref" || node.type === "footnote_reference") {
    return `[${asString(node.id)}]`;
  }
  if (node.type === "admonition") {
    const title = asString(node.title) || asString(node.kind) || asString(node.name);
    return `${title}${nodeTextContent(node)}`;
  }
  if (node.type === "vmr_container") {
    const title = asString(node.name) || "container";
    return `${title}${nodeTextContent(node)}`;
  }
  if (node.type === "math_block" || node.type === "math_inline") {
    return asString(node.content) || asString(node.raw);
  }
  if (node.type === "thematic_break") return nodeTextContent(node) || "\n";
  return nodeTextContent(node);
};

const completeBlurNodeCharacterCount = (node: MarkdownNode, final: boolean) =>
  stringCharacters(completeBlurNodeTextContent(node, final)).length;

const completeBlurPartitionMetrics = (
  parsedNodes: readonly MarkdownNode[],
  final: boolean,
  stableTextBoundary: number
) => {
  let stableCount = 0;
  let stableTextCharacters = 0;
  let totalTextCharacters = 0;

  parsedNodes.forEach((node, index) => {
    const nodeCharacters = completeBlurNodeCharacterCount(node, final);
    const nextTotalTextCharacters = totalTextCharacters + nodeCharacters;

    if (stableCount === index && nextTotalTextCharacters <= stableTextBoundary) {
      stableCount = index + 1;
      stableTextCharacters = nextTotalTextCharacters;
    }

    totalTextCharacters = nextTotalTextCharacters;
  });

  return {
    stableCount,
    stableTextCharacters,
    totalTextCharacters,
  };
};

const stableRootNodeCount = (parsedNodes: readonly MarkdownNode[], final: boolean) => {
  if (final) return parsedNodes.length;
  if (parsedNodes.length === 0) return 0;

  const firstLoadingIndex = parsedNodes.findIndex(hasLoadingMarkdownNode);
  if (firstLoadingIndex >= 0) return firstLoadingIndex;

  return Math.max(0, parsedNodes.length - 1);
};

type MarkdownParseResult = {
  nodes: MarkdownNode[];
  rootStartLines: number[];
};

type IncrementalMarkdownParseCache = {
  content: string;
  customHtmlTagsKey: string | undefined;
  incrementalSafe: boolean;
  markdown: MarkdownIt;
  nodes: MarkdownNode[];
  parseOptions: ParseOptions | undefined;
  rootSourceOffsets: number[];
};

const topLevelRootStartLines = (tokens: MarkdownToken[]) =>
  tokens.flatMap((token) => {
    const map = token.map;
    const startLine = Array.isArray(map) ? map[0] : undefined;
    return token.level === 0 && token.nesting !== -1 && Number.isInteger(startLine)
      ? [startLine as number]
      : [];
  });

const parseMarkdownWithRootStartLines = ({
  content,
  customHtmlTags,
  final,
  markdown,
  parseOptions,
  streamParse,
}: {
  content: string;
  customHtmlTags?: readonly string[] | undefined;
  final: boolean;
  markdown: MarkdownIt;
  parseOptions?: ParseOptions | undefined;
  streamParse?: false | undefined;
}): MarkdownParseResult => {
  let rootStartLines: number[] = [];
  const userPreTransformTokens = parseOptions?.preTransformTokens;
  const nodes = parseMarkdownToStructure(content, markdown, {
    ...parseOptions,
    ...(customHtmlTags ? { customHtmlTags } : {}),
    final,
    preTransformTokens: (tokens) => {
      const transformedTokens = userPreTransformTokens?.(tokens) ?? tokens;
      rootStartLines = topLevelRootStartLines(transformedTokens);
      return transformedTokens;
    },
    ...(streamParse === false ? { streamParse: false } : {}),
  }) as MarkdownNode[];

  return { nodes, rootStartLines };
};

const markdownLineStartOffsets = (content: string) => {
  const offsets = [0];
  for (let index = 0; index < content.length; index += 1) {
    if (content[index] === "\n") offsets.push(index + 1);
  }
  return offsets;
};

const paragraphRootMatchesSource = (
  content: string,
  offset: number,
  node: MarkdownNode
) => {
  if (node.type !== "paragraph" || typeof node.raw !== "string") return true;
  return content
    .slice(offset)
    .replace(/^[\t ]{0,3}/, "")
    .startsWith(node.raw);
};

const validatedRootSourceOffsets = (
  content: string,
  nodes: readonly MarkdownNode[],
  rootStartLines: readonly number[]
) => {
  if (nodes.length !== rootStartLines.length || /\r(?!\n)/.test(content)) return null;
  if (nodes.length === 0) return [];

  const lineStarts = markdownLineStartOffsets(content);
  const offsets: number[] = [];
  for (let index = 0; index < rootStartLines.length; index += 1) {
    const line = rootStartLines[index];
    const offset = line === undefined ? undefined : lineStarts[line];
    if (
      offset === undefined ||
      offset >= content.length ||
      (index > 0 && offset <= offsets[index - 1]!) ||
      !paragraphRootMatchesSource(content, offset, nodes[index]!)
    ) {
      return null;
    }
    offsets.push(offset);
  }
  return offsets;
};

const hasRetroactiveMarkdownDefinition = (content: string) => content.includes("]:");

// stream-markdown-parser carries filename/ticker demotion context across root
// blocks. That context can continue through an arbitrary run of filename-like
// roots, and the dependency does not expose a checkpoint state that a fragment
// parse can restore. Keep the detector deliberately broader than the parser's
// current trigger expressions so a fragment never silently loses that context.
const hasCrossRootLinkifyContext = (content: string) =>
  /(?:文件|附件|路径|路徑|档案|檔案|文档|文檔|资料|資料|股票|证券|證券|代码|代碼|交易所|后缀|後綴|市场|市場|\b(?:files?|attachments?|paths?|documents?|docs?|tickers?|symbols?|exchanges?)\b)/iu.test(
    content
  );

const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const customHtmlTagsMayShiftSourceLines = (
  content: string,
  customHtmlTags: readonly string[] | undefined
) => {
  if (!customHtmlTags?.length || !content.includes("<")) return false;
  const tagPattern = customHtmlTags.map(escapeRegExp).join("|");
  if (!tagPattern) return false;
  const openPattern = new RegExp(`<\\s*(?:${tagPattern})(?=\\s|/?>)`, "i");
  const closePattern = new RegExp(`<\\s*/\\s*(?:${tagPattern})(?=\\s|>)`, "i");
  const lines = content.split(/\r?\n/);

  return lines.some((line, index) => {
    const hasOpen = openPattern.test(line);
    const hasClose = closePattern.test(line);
    if (!hasOpen && !hasClose) return false;
    // A complete inline custom tag does not change the parser's line map.
    if (hasOpen && hasClose) return false;
    if (hasOpen && index > 0 && lines[index - 1]?.trim() !== "") return true;
    return hasClose && index + 1 < lines.length && lines[index + 1]?.trim() !== "";
  });
};

const incrementalMarkdownParseIsSafe = (
  content: string,
  customHtmlTags: readonly string[] | undefined,
  parseOptions: ParseOptions | undefined,
  customMarkdownIt: NodeRendererProps["customMarkdownIt"] | undefined
) =>
  // A custom MarkdownIt callback may install document-global core/block rules.
  // Without an explicit fragment-safety/checkpoint contract, only the default
  // parser is safe to run against an isolated suffix.
  customMarkdownIt === undefined &&
  typeof parseOptions?.preTransformTokens !== "function" &&
  typeof parseOptions?.postTransformTokens !== "function" &&
  !hasRetroactiveMarkdownDefinition(content) &&
  !hasCrossRootLinkifyContext(content) &&
  !customHtmlTagsMayShiftSourceLines(content, customHtmlTags);

const usePartitionedMarkdownNodes = ({
  content,
  customHtmlTags,
  customId,
  customMarkdownIt,
  enabled,
  final,
  parseOptions,
  stableTextBoundary,
}: {
  content: string;
  customHtmlTags?: NodeRendererProps["customHtmlTags"];
  customId: string;
  customMarkdownIt?: NodeRendererProps["customMarkdownIt"];
  enabled: boolean;
  final: boolean;
  parseOptions?: NodeRendererProps["parseOptions"];
  stableTextBoundary?: number | undefined;
}) => {
  const customHtmlTagsKey =
    customHtmlTags === undefined ? undefined : customHtmlTags.join("\u0000");
  // Key the parser and the parse on the tags VALUE, not the array identity:
  // callers may rebuild an equal array per render, and that must not rebuild
  // the MarkdownIt instance (getMarkdown constructs a fresh parser with its
  // full plugin chain on every call) or re-parse the whole document.
  const stableCustomHtmlTags = useMemo(
    () =>
      customHtmlTagsKey === undefined
        ? undefined
        : customHtmlTagsKey.split("\u0000").filter((tag) => tag !== ""),
    [customHtmlTagsKey]
  );
  const markdown = useMemo<MarkdownIt | null>(() => {
    if (!enabled) return null;
    const parser = getMarkdown(
      `${customId}:partition:${customHtmlTagsKey ?? ""}`,
      stableCustomHtmlTags ? { customHtmlTags: stableCustomHtmlTags } : undefined
    );
    configureMarkdownSyntax(parser);
    return customMarkdownIt ? customMarkdownIt(parser) : parser;
  }, [customHtmlTagsKey, customId, customMarkdownIt, enabled, stableCustomHtmlTags]);
  const parseCacheRef = useRef<IncrementalMarkdownParseCache | null>(null);
  const stableReuseEpochRef = useRef(0);
  const parsedNodes = useMemo(() => {
    if (!enabled || markdown === null) {
      // A compiled nodes handoff (for example a completed reply with embedded
      // tasks) changes the input representation, not this document's lifetime.
      parseCacheRef.current = null;
      return [];
    }

    const stableReuseSafe = incrementalMarkdownParseIsSafe(
      content,
      stableCustomHtmlTags,
      parseOptions,
      customMarkdownIt
    );
    const incrementalSafe = !final && stableReuseSafe;
    const previous = parseCacheRef.current;
    const configMatches =
      previous?.markdown === markdown &&
      previous.parseOptions === parseOptions &&
      previous.customHtmlTagsKey === customHtmlTagsKey;
    const prefixGrew =
      previous !== null &&
      content.length > previous.content.length &&
      content.startsWith(previous.content);

    if (incrementalSafe && previous?.incrementalSafe && configMatches && prefixGrew) {
      const settledCount = stableRootNodeCount(previous.nodes, false);
      const checkpoint = previous.rootSourceOffsets[settledCount];
      if (
        checkpoint !== undefined &&
        checkpoint > 0 &&
        checkpoint < previous.content.length
      ) {
        const tailContent = content.slice(checkpoint);
        const tail = parseMarkdownWithRootStartLines({
          content: tailContent,
          customHtmlTags: stableCustomHtmlTags,
          final: false,
          markdown,
          parseOptions,
          streamParse: false,
        });
        const tailRootSourceOffsets = validatedRootSourceOffsets(
          tailContent,
          tail.nodes,
          tail.rootStartLines
        );
        if (
          tail.nodes.length > 0 &&
          tailRootSourceOffsets?.[0] === 0 &&
          previous.rootSourceOffsets.length === previous.nodes.length
        ) {
          const nodes = [...previous.nodes.slice(0, settledCount), ...tail.nodes];
          const rootSourceOffsets = [
            ...previous.rootSourceOffsets.slice(0, settledCount),
            ...tailRootSourceOffsets.map((offset) => checkpoint + offset),
          ];
          if (
            rootSourceOffsets.length === nodes.length &&
            rootSourceOffsets.every(
              (offset, index) => index === 0 || offset > rootSourceOffsets[index - 1]!
            )
          ) {
            parseCacheRef.current = {
              content,
              customHtmlTagsKey,
              incrementalSafe: true,
              markdown,
              nodes,
              parseOptions,
              rootSourceOffsets,
            };
            return nodes;
          }
        }
      }
    }

    const full = parseMarkdownWithRootStartLines({
      content,
      customHtmlTags: stableCustomHtmlTags,
      final,
      markdown,
      parseOptions,
    });
    // Parsing can revise earlier nodes, including canonical whitespace trims.
    // Text replacement updates this document; only parser/document identity
    // starts a new presentation lifetime. The renderer receives the full AST.
    if (previous !== null && !configMatches) {
      stableReuseEpochRef.current += 1;
    }
    const rootSourceOffsets = validatedRootSourceOffsets(
      content,
      full.nodes,
      full.rootStartLines
    );
    parseCacheRef.current = {
      content,
      customHtmlTagsKey,
      incrementalSafe: incrementalSafe && rootSourceOffsets !== null,
      markdown,
      nodes: full.nodes,
      parseOptions,
      rootSourceOffsets: rootSourceOffsets ?? [],
    };
    return full.nodes;
  }, [
    content,
    customHtmlTagsKey,
    enabled,
    final,
    markdown,
    parseOptions,
    stableCustomHtmlTags,
    customMarkdownIt,
  ]);
  const stableRef = useRef<{
    epoch: number;
    nodes: MarkdownNode[];
    signatures: string[];
  }>({
    epoch: 0,
    nodes: [],
    signatures: [],
  });
  const stableReuseEpoch = stableReuseEpochRef.current;
  return useMemo(() => {
    const completeBlurMetrics =
      typeof stableTextBoundary === "number"
        ? completeBlurPartitionMetrics(parsedNodes, final, stableTextBoundary)
        : undefined;
    const stableCount =
      completeBlurMetrics?.stableCount ?? stableRootNodeCount(parsedNodes, final);
    const stableCandidates = parsedNodes.slice(0, stableCount);
    const signatures = stableCandidates.map(nodeRenderSignature);
    const cachedPrevious = stableRef.current;
    const previous =
      cachedPrevious.epoch === stableReuseEpoch
        ? cachedPrevious
        : { epoch: stableReuseEpoch, nodes: [], signatures: [] };
    const stableNodes = stableCandidates.map((node, index) =>
      previous.signatures[index] === signatures[index]
        ? (previous.nodes[index] ?? node)
        : node
    );
    const stableChanged =
      cachedPrevious.epoch !== stableReuseEpoch ||
      previous.nodes.length !== stableNodes.length ||
      stableNodes.some((node, index) => previous.nodes[index] !== node);

    if (stableChanged) {
      stableRef.current = {
        epoch: stableReuseEpoch,
        nodes: stableNodes,
        signatures,
      };
    }

    const orderedNodes = [
      ...(stableChanged ? stableNodes : previous.nodes),
      ...parsedNodes.slice(stableCount),
    ];

    return {
      renderEpoch: stableReuseEpoch,
      nodes: orderedNodes as BaseNode[],
      stableCount,
      stableTextCharacters: completeBlurMetrics?.stableTextCharacters ?? 0,
      totalTextCharacters: completeBlurMetrics?.totalTextCharacters ?? 0,
    };
  }, [final, parsedNodes, stableReuseEpoch, stableTextBoundary]);
};

const asString = (value: unknown) => (typeof value === "string" ? value : "");

const nodeChildren = (node: MarkdownNode): MarkdownNode[] =>
  Array.isArray(node.children) ? node.children.filter(isMarkdownNode) : [];

const nodeArrayTextContent = (value: unknown): string =>
  Array.isArray(value)
    ? value.filter(isMarkdownNode).map(nodeTextContent).join("")
    : "";

const nodeTextContent = (node: MarkdownNode): string => {
  if (node.type === "hardbreak") return "\n";

  const children = nodeChildren(node);
  if (children.length > 0) return children.map(nodeTextContent).join("");

  const structuredParts = [
    nodeArrayTextContent(node.items),
    nodeArrayTextContent(node.term),
    nodeArrayTextContent(node.definition),
  ];

  const header = node.header as { cells?: unknown } | undefined;
  structuredParts.push(nodeArrayTextContent(header?.cells));

  if (Array.isArray(node.rows)) {
    structuredParts.push(
      node.rows
        .map((row) =>
          typeof row === "object" && row !== null
            ? nodeArrayTextContent((row as { cells?: unknown }).cells)
            : ""
        )
        .join("")
    );
  }

  const structuredText = structuredParts.join("");
  if (structuredText) return structuredText;

  return (
    firstString(
      node.content,
      node.text,
      node.code,
      node.alt,
      node.name,
      node.markup,
      node.raw
    ) ?? ""
  );
};

const renderNode = (
  render: RenderNodeFn | undefined,
  ctx: RenderContext | undefined,
  node: MarkdownNode,
  key: string
) => {
  if (!render || !ctx) return null;
  return render(node as Parameters<RenderNodeFn>[0], key, ctx);
};

const renderChildren = (
  props: CommaNodeProps,
  children: MarkdownNode[],
  keyPrefix: string
) =>
  children.map((child, index) =>
    renderNode(props.renderNode, props.ctx, child, `${keyPrefix}-${index}`)
  );

const childKeyPrefix = (props: CommaNodeProps, fallback: string) =>
  String(props.indexKey ?? fallback);

const blockChildTypes = new Set([
  "blockquote",
  "code_block",
  "heading",
  "html_block",
  "list",
  "paragraph",
  "table",
  "thematic_break",
]);

const normalizeLanguage = (language: unknown) => {
  const value = asString(language).trim();
  if (!value) return "text";
  return value.split(/\s+/)[0]?.toLowerCase() || "text";
};

const shikiLanguageAliases: Record<string, string> = {
  js: "javascript",
  md: "markdown",
  py: "python",
  rb: "ruby",
  sh: "bash",
  shell: "bash",
  text: "plaintext",
  ts: "typescript",
  yml: "yaml",
  zsh: "bash",
};

const commaSupportedShikiLanguages = new Set([
  "astro",
  "bash",
  "c",
  "cpp",
  "css",
  "csharp",
  "diff",
  "dockerfile",
  "go",
  "graphql",
  "html",
  "java",
  "javascript",
  "json",
  "jsonc",
  "jsx",
  "kotlin",
  "less",
  "lua",
  "markdown",
  "php",
  "plaintext",
  "python",
  "ruby",
  "rust",
  "scss",
  "sql",
  "svelte",
  "swift",
  "tsx",
  "typescript",
  "vue",
  "xml",
  "yaml",
]);

const normalizeHighlightLanguage = (language: string) => {
  const normalized = shikiLanguageAliases[language] ?? language;
  return commaSupportedShikiLanguages.has(normalized) ? normalized : "plaintext";
};

const asStringArray = (value: unknown): readonly string[] | undefined =>
  Array.isArray(value) && value.every((item) => typeof item === "string")
    ? value
    : undefined;

const firstString = (...values: unknown[]) =>
  values.find((value): value is string => typeof value === "string");

const firstNonEmptyString = (...values: unknown[]) =>
  values.find(
    (value): value is string => typeof value === "string" && value.length > 0
  ) ??
  firstString(...values) ??
  "";

const codeBlockContent = (node: MarkdownNode) =>
  firstNonEmptyString(node.code, node.content).replace(/\n$/, "");

const resolveMermaidApi = (moduleValue: unknown): MermaidApi | null => {
  const record = moduleValue as MermaidModuleRecord;
  const candidates = [record.default, moduleValue, record.mermaid, record.mermaidAPI];

  for (const candidate of candidates) {
    if (
      typeof candidate === "object" &&
      candidate !== null &&
      typeof (candidate as MermaidApi).render === "function"
    ) {
      return candidate as MermaidApi;
    }
  }

  return null;
};

const mermaidThemeConfig = (isDark: boolean): Record<string, unknown> => {
  if (!isDark) return { theme: "default" };

  const colors = componentsDark.markdown;
  return {
    theme: "base",
    themeVariables: {
      background: colors.bgTable,
      edgeLabelBackground: colors.bgTable,
      lineColor: colors.iconPrimary,
      mainBkg: colors.bgTool,
      nodeBorder: colors.borderTable,
      primaryBorderColor: colors.borderTable,
      primaryColor: colors.bgTool,
      primaryTextColor: colors.textPrimary,
      secondaryColor: colors.bgInlineCode,
      tertiaryColor: colors.bgTable,
      textColor: colors.textPrimary,
      titleColor: colors.textPrimary,
    },
  };
};

const withMermaidThemeInit = (code: string, isDark: boolean) =>
  code.trimStart().startsWith("%%{")
    ? code
    : `%%{init: ${JSON.stringify(mermaidThemeConfig(isDark))}}%%\n${code}`;

const safeSvgHrefPattern =
  /^(?:https?:|mailto:|tel:|#|\/|data:image\/(?:png|gif|jpe?g|webp);)/i;

const sanitizeMermaidSvg = (svg: string) => {
  if (typeof DOMParser === "undefined") return svg;

  const documentValue = new DOMParser().parseFromString(svg, "image/svg+xml");
  const root = documentValue.documentElement;
  if (!root || root.nodeName.toLowerCase() !== "svg") return "";

  const elements = [root, ...Array.from(root.querySelectorAll("*"))];
  for (const element of elements) {
    const tagName = element.tagName.toLowerCase();
    if (tagName === "script" || tagName === "foreignobject") {
      element.remove();
      continue;
    }

    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name;
      const value = attribute.value;
      if (/^on/i.test(name)) {
        element.removeAttribute(name);
        continue;
      }

      if ((name === "href" || name === "xlink:href") && value) {
        const trimmedValue = value.trim();
        if (!safeSvgHrefPattern.test(trimmedValue)) {
          element.removeAttribute(name);
        }
      }
    }
  }

  return root.outerHTML;
};

const isExternalHref = (href: string) => /^https?:\/\//i.test(href);

const safeHref = (href: unknown) => {
  const value = asString(href).trim();
  if (!value) return undefined;
  if (
    value.startsWith("#") ||
    value.startsWith("/") ||
    value.startsWith("./") ||
    value.startsWith("../")
  ) {
    return value;
  }

  try {
    const url = new URL(value);
    if (
      url.protocol === "http:" ||
      url.protocol === "https:" ||
      url.protocol === "mailto:"
    ) {
      return value;
    }
  } catch {
    return undefined;
  }

  return undefined;
};

const commonTextClasses = "whitespace-pre-wrap break-words";

interface CommaAnimatedTextProps {
  className?: string;
  content: string;
  streamState?: RenderContext["textStreamState"];
  streamKey: string;
}

interface AnimatedTextSegment {
  complete: boolean;
  id: number;
  text: string;
}

interface AnimatedTextState {
  activeSegments: AnimatedTextSegment[];
  latestContent: string;
  nextSegmentId: number;
  settledContent: string;
}

const createAnimatedTextState = (
  content: string,
  shouldPrepareInitialAnimation: boolean
): AnimatedTextState =>
  shouldPrepareInitialAnimation
    ? {
        activeSegments: [],
        latestContent: "",
        nextSegmentId: 0,
        settledContent: "",
      }
    : {
        activeSegments: [],
        latestContent: content,
        nextSegmentId: 0,
        settledContent: content,
      };

const stringCharacters = (value: string) => Array.from(value);

const completeBlurReservationKey = (indexKey: unknown, purpose: string) =>
  `${String(indexKey ?? purpose)}:${purpose}`;

const observeCompleteBlurTextOffset = (
  queue: CompleteBlurTextQueue,
  content: string,
  streamKey: string
) => {
  const previousOffset = queue.textOffsetsByStreamKey.get(streamKey);
  if (previousOffset?.content === content) return previousOffset.startOffset;

  const startOffset = queue.textOffsetRef.current;
  queue.textOffsetsByStreamKey.set(streamKey, { content, startOffset });
  return startOffset;
};

const reserveCompleteBlurTextOffset = (
  queue: CompleteBlurTextQueue,
  content: string,
  streamKey: string
) => {
  const reservationKey = `reservation:${streamKey}`;
  const previousOffset = queue.textOffsetsByStreamKey.get(reservationKey);
  if (previousOffset?.content === content) return previousOffset.startOffset;

  const startOffset = queue.textOffsetRef.current;
  queue.textOffsetsByStreamKey.set(reservationKey, { content, startOffset });
  queue.textOffsetRef.current += stringCharacters(content).length;
  return startOffset;
};

const reserveCompleteBlurTextVisibility = (
  queue: CompleteBlurTextQueue | undefined,
  content: string,
  streamKey: string
) => {
  if (!queue) return true;

  const characterCount = stringCharacters(content).length;
  if (characterCount === 0) return true;

  const startOffset = observeCompleteBlurTextOffset(
    queue,
    content,
    `visibility:${streamKey}`
  );
  const visibleCount = clampVisibleCharacterCount(
    queue.visibleTextCharacters,
    startOffset,
    characterCount
  );

  if (visibleCount > 0) return true;

  reserveCompleteBlurTextOffset(queue, content, `hidden:${streamKey}`);
  return false;
};

const getCompleteBlurTextRange = (
  queue: CompleteBlurTextQueue | undefined,
  content: string,
  streamKey: string
) => {
  const characterCount = stringCharacters(content).length;
  if (!queue || characterCount === 0) {
    return {
      characterCount,
      complete: true,
      visible: true,
      visibleCount: characterCount,
    };
  }

  const startOffset = observeCompleteBlurTextOffset(
    queue,
    content,
    `range:${streamKey}`
  );
  const visibleCount = clampVisibleCharacterCount(
    queue.visibleTextCharacters,
    startOffset,
    characterCount
  );

  return {
    characterCount,
    complete: visibleCount >= characterCount,
    visible: visibleCount > 0,
    visibleCount,
  };
};

const reserveHiddenCompleteBlurText = (
  queue: CompleteBlurTextQueue | undefined,
  content: string,
  streamKey: string
) => {
  if (!queue) return;
  reserveCompleteBlurTextOffset(queue, content, streamKey);
};

const shouldRenderCompleteBlurContent = (
  queue: CompleteBlurTextQueue | undefined,
  content: string,
  streamKey: string
) => !content || reserveCompleteBlurTextVisibility(queue, content, streamKey);

const shouldRenderCompleteBlurNode = (
  queue: CompleteBlurTextQueue | undefined,
  node: MarkdownNode,
  streamKey: string,
  content = nodeTextContent(node)
) => shouldRenderCompleteBlurContent(queue, content, streamKey);

const settleCompletedSegments = (state: AnimatedTextState): AnimatedTextState => {
  let settledContent = state.settledContent;
  let firstActiveIndex = 0;

  while (
    firstActiveIndex < state.activeSegments.length &&
    state.activeSegments[firstActiveIndex]?.complete
  ) {
    settledContent += state.activeSegments[firstActiveIndex]?.text ?? "";
    firstActiveIndex += 1;
  }

  if (firstActiveIndex === 0) return state;

  return {
    ...state,
    activeSegments: state.activeSegments.slice(firstActiveIndex),
    settledContent,
  };
};

const clampVisibleCharacterCount = (
  visibleTextCharacters: number,
  startOffset: number,
  characterCount: number
) => Math.min(characterCount, Math.max(0, visibleTextCharacters - startOffset));

const isLineBreakCharacter = (character: string) =>
  character === "\n" || character === "\r";

const isWhitespaceCharacter = (character: string) => /\s/u.test(character);

const moveStartToWordBoundary = (
  characters: readonly string[],
  startIndex: number,
  maxLookBehind = 64
) => {
  let start = Math.min(Math.max(0, startIndex), characters.length);
  const originalStart = start;
  const minStart = Math.max(0, start - maxLookBehind);

  while (
    start > minStart &&
    start < characters.length &&
    !isWhitespaceCharacter(characters[start] ?? "") &&
    !isWhitespaceCharacter(characters[start - 1] ?? "")
  ) {
    start -= 1;
  }

  const foundWhitespaceBoundary =
    start < originalStart &&
    (isWhitespaceCharacter(characters[start] ?? "") ||
      isWhitespaceCharacter(characters[start - 1] ?? ""));

  return foundWhitespaceBoundary ? start : originalStart;
};

const renderCharacterRuns = (
  characters: readonly string[],
  renderCharacter: (character: string, index: number) => ReactNode,
  keyPrefix: string
) => {
  const runs: ReactNode[] = [];
  let wordCharacters: ReactNode[] = [];
  let wordStartIndex = 0;

  const flushWord = () => {
    if (wordCharacters.length === 0) return;
    runs.push(
      <span
        className="markdown-stream-char-word"
        key={`${keyPrefix}:word:${wordStartIndex}`}
      >
        {wordCharacters}
      </span>
    );
    wordCharacters = [];
  };

  characters.forEach((character, index) => {
    if (isLineBreakCharacter(character)) {
      flushWord();
      runs.push(character);
      return;
    }

    const renderedCharacter = renderCharacter(character, index);
    if (isWhitespaceCharacter(character)) {
      flushWord();
      runs.push(renderedCharacter);
      return;
    }

    if (wordCharacters.length === 0) {
      wordStartIndex = index;
    }
    wordCharacters.push(renderedCharacter);
  });

  flushWord();

  return runs;
};

function CommaCompleteBlurCharacter({
  children,
  clearOnInactive = true,
  shouldAnimate,
  style,
  timeoutMs,
  onAnimationComplete,
}: {
  children: string;
  clearOnInactive?: boolean | undefined;
  onAnimationComplete?: (() => void) | undefined;
  shouldAnimate: boolean;
  style?: CSSProperties | undefined;
  timeoutMs?: number | undefined;
}) {
  const animationStartedRef = useRef(shouldAnimate);
  const animating = clearOnInactive ? shouldAnimate : animationStartedRef.current;

  return (
    <span
      className="markdown-stream-char-slot"
      data-markdown-stream-char={children}
      style={style}
    >
      {onAnimationComplete ? (
        <CommaTrackedCompleteBlurGlyph
          animating={animating}
          onAnimationComplete={onAnimationComplete}
          timeoutMs={timeoutMs}
        >
          {children}
        </CommaTrackedCompleteBlurGlyph>
      ) : (
        <span
          className={cx(
            "markdown-stream-char-glyph",
            animating && "markdown-stream-char-enter"
          )}
        >
          <span className="markdown-stream-char-text">{children}</span>
        </span>
      )}
    </span>
  );
}

const clearCompleteBlurAnimationClass = (event: Event) => {
  const target = event.target;
  if (
    !(target instanceof HTMLElement) ||
    !target.classList.contains("markdown-stream-char-enter")
  ) {
    return;
  }
  target.classList.remove("markdown-stream-char-enter");
};

const clearCompleteBlurAnimationClasses = (root: HTMLElement) => {
  root
    .querySelectorAll<HTMLElement>(".markdown-stream-char-enter")
    .forEach((glyph) => glyph.classList.remove("markdown-stream-char-enter"));
};

const clearCompleteBlurAnimationClassOnNode = (node: Node) => {
  if (!(node instanceof HTMLElement)) return;
  if (node.classList.contains("markdown-stream-char-enter")) {
    node.classList.remove("markdown-stream-char-enter");
  }
};

const clearCompleteBlurAnimationClassesInNode = (node: Node) => {
  if (!(node instanceof HTMLElement)) return;
  clearCompleteBlurAnimationClassOnNode(node);
  clearCompleteBlurAnimationClasses(node);
};

function CommaTrackedCompleteBlurGlyph({
  animating,
  children,
  onAnimationComplete,
  timeoutMs,
}: {
  animating: boolean;
  children: string;
  onAnimationComplete: () => void;
  timeoutMs?: number | undefined;
}) {
  const { blurAnimation } = useContext(MarkdownStreamContext);
  const glyphRef = useRef<HTMLSpanElement>(null);
  const completedRef = useRef(!animating);
  const onAnimationCompleteRef = useRef(onAnimationComplete);
  onAnimationCompleteRef.current = onAnimationComplete;

  const completeAnimation = () => {
    if (completedRef.current) return;
    completedRef.current = true;
    glyphRef.current?.classList.remove("markdown-stream-char-enter");
    onAnimationCompleteRef.current();
  };

  useEffect(() => {
    if (!animating) {
      completedRef.current = true;
      return undefined;
    }

    completedRef.current = false;
    const glyph = glyphRef.current;
    glyph?.addEventListener("animationcancel", completeAnimation);
    glyph?.addEventListener("animationend", completeAnimation);
    const timeout = setTimeout(
      completeAnimation,
      (timeoutMs ?? blurAnimation.durationMs) + 80
    );
    return () => {
      clearTimeout(timeout);
      glyph?.removeEventListener("animationcancel", completeAnimation);
      glyph?.removeEventListener("animationend", completeAnimation);
    };
  }, [animating, blurAnimation.durationMs, timeoutMs]);

  return (
    <span
      className={cx(
        "markdown-stream-char-glyph",
        animating && "markdown-stream-char-enter"
      )}
      ref={glyphRef}
    >
      <span className="markdown-stream-char-text">{children}</span>
    </span>
  );
}

function CommaCompleteBlurText({
  className,
  content,
  queue,
  streamKey,
}: {
  className?: string | undefined;
  content: string;
  queue: CompleteBlurTextQueue;
  streamKey: string;
}) {
  const characters = stringCharacters(content);
  const startOffset = reserveCompleteBlurTextOffset(queue, content, streamKey);

  const visibleCount = clampVisibleCharacterCount(
    queue.visibleTextCharacters,
    startOffset,
    characters.length
  );
  const visibleCharacters = characters.slice(0, visibleCount);
  const rawActiveCharacterStart = Math.min(
    visibleCount,
    Math.max(0, queue.activeTextStart - startOffset)
  );
  const activeCharacterStart = moveStartToWordBoundary(
    visibleCharacters,
    rawActiveCharacterStart
  );
  const settledText = visibleCharacters.slice(0, activeCharacterStart).join("");
  const activeCharacters = visibleCharacters.slice(activeCharacterStart);
  const animatedTextBoundary = queue.animatedTextBoundaryRef.current;

  return (
    <span className={cx(commonTextClasses, className)}>
      {settledText}
      {renderCharacterRuns(
        activeCharacters,
        (character, index) => {
          const textIndex = startOffset + activeCharacterStart + index;
          const shouldAnimate =
            textIndex >= animatedTextBoundary &&
            textIndex < queue.visibleTextCharacters;
          return (
            <CommaCompleteBlurCharacter
              key={`${textIndex}:${character}`}
              clearOnInactive={false}
              shouldAnimate={shouldAnimate}
            >
              {character}
            </CommaCompleteBlurCharacter>
          );
        },
        `${startOffset}:${activeCharacterStart}`
      )}
    </span>
  );
}

function CommaAnimatedText(props: CommaAnimatedTextProps) {
  const { animation, completeBlurTextQueue } = useContext(MarkdownStreamContext);

  if (animation !== "blur") {
    return (
      <span className={cx(commonTextClasses, props.className)}>{props.content}</span>
    );
  }

  if (completeBlurTextQueue) {
    return (
      <CommaCompleteBlurText
        className={props.className}
        content={props.content}
        queue={completeBlurTextQueue}
        streamKey={props.streamKey}
      />
    );
  }

  return <CommaLocalAnimatedText {...props} />;
}

function CommaLocalAnimatedText({
  className,
  content,
  streamKey,
  streamState,
}: CommaAnimatedTextProps) {
  const { animation, blurAnimation, final, maxAnimatedCharacters, settled } =
    useContext(MarkdownStreamContext);
  const animationInputVersion = useContext(MarkdownStreamAnimationVersionContext);
  const enabled = animation === "blur" && !final && !settled && Boolean(streamKey);
  const hasPersistedInitialContent = streamState?.has(streamKey) ?? false;
  const persistedInitialContent = streamState?.get(streamKey);
  const shouldResumeFromPersistedContent =
    enabled &&
    typeof persistedInitialContent === "string" &&
    content.startsWith(persistedInitialContent) &&
    content !== persistedInitialContent;
  const shouldAnimateInitialText =
    enabled && Boolean(streamKey) && content.length > 0 && !hasPersistedInitialContent;
  const initialState = useMemo(
    () =>
      shouldResumeFromPersistedContent
        ? createAnimatedTextState(persistedInitialContent ?? "", false)
        : createAnimatedTextState(content, shouldAnimateInitialText),
    [
      content,
      persistedInitialContent,
      shouldAnimateInitialText,
      shouldResumeFromPersistedContent,
    ]
  );
  const stateRef = useRef(initialState);
  const lastAnimationInputVersionRef = useRef(animationInputVersion);
  const lastContentChangeVersionRef = useRef(animationInputVersion);
  const [renderState, setRenderState] = useState(initialState);

  const commitState = (state: AnimatedTextState) => {
    stateRef.current = state;
    setRenderState(state);
  };

  const commitSettledContent = (nextContent: string) => {
    commitState({
      activeSegments: [],
      latestContent: nextContent,
      nextSegmentId: stateRef.current.nextSegmentId,
      settledContent: nextContent,
    });
  };

  const appendAnimatedSegment = (nextContent: string, previousContent: string) => {
    const delta = nextContent.slice(previousContent.length);
    if (!delta) return;

    const currentState = stateRef.current;
    const maxActiveCharacters = Math.max(
      1,
      Math.min(maxAnimatedCharacters, blurAnimation.activeCharacters)
    );
    const deltaCharacters = stringCharacters(delta);
    const activeCharacterStart = moveStartToWordBoundary(
      deltaCharacters,
      Math.max(0, deltaCharacters.length - maxActiveCharacters)
    );
    const activeCharacters = deltaCharacters.slice(activeCharacterStart);
    const settledDelta = deltaCharacters.slice(0, activeCharacterStart).join("");
    const activeText = activeCharacters.join("");
    const nextSegment = {
      complete: false,
      id: currentState.nextSegmentId,
      text: activeText,
    };
    commitState({
      activeSegments: activeText ? [nextSegment] : [],
      latestContent: nextContent,
      nextSegmentId: currentState.nextSegmentId + (activeText ? 1 : 0),
      settledContent: previousContent + settledDelta,
    });
  };

  const settleSegment = (segmentId: number) => {
    const currentState = stateRef.current;
    const nextState = settleCompletedSegments({
      ...currentState,
      activeSegments: currentState.activeSegments.map((segment) =>
        segment.id === segmentId ? { ...segment, complete: true } : segment
      ),
    });
    commitState(nextState);
  };

  useLayoutEffect(() => {
    const inputVersionChanged =
      lastAnimationInputVersionRef.current !== animationInputVersion;
    lastAnimationInputVersionRef.current = animationInputVersion;

    if (!enabled || !streamKey || final) {
      lastContentChangeVersionRef.current = animationInputVersion;
      commitSettledContent(content);
      if (streamKey) streamState?.set(streamKey, content);
      return;
    }

    const persistedContent = streamState?.get(streamKey);
    const previousContent =
      [persistedContent, stateRef.current.latestContent]
        .filter((candidate): candidate is string => typeof candidate === "string")
        .filter((candidate) => content.startsWith(candidate))
        .toSorted((left, right) => right.length - left.length)[0] ??
      persistedContent ??
      stateRef.current.latestContent;

    if (content === stateRef.current.latestContent) {
      if (
        inputVersionChanged &&
        lastContentChangeVersionRef.current !== animationInputVersion &&
        stateRef.current.activeSegments.length > 0
      ) {
        commitSettledContent(content);
      }
      streamState?.set(streamKey, content);
      return;
    }

    lastContentChangeVersionRef.current = animationInputVersion;

    if (
      previousContent.length === 0 &&
      stateRef.current.latestContent.length === 0 &&
      content.length > 0
    ) {
      appendAnimatedSegment(content, "");
    } else if (content.startsWith(previousContent)) {
      appendAnimatedSegment(content, previousContent);
    } else if (content.startsWith(stateRef.current.latestContent)) {
      appendAnimatedSegment(content, stateRef.current.latestContent);
    } else {
      commitSettledContent(content);
    }

    streamState?.set(streamKey, content);
    // appendAnimatedSegment reads mutable animation state from refs; adding it to
    // deps would restart settled local animation bookkeeping during the stream.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [animationInputVersion, content, enabled, final, streamKey, streamState]);

  useEffect(() => {
    const lineBreakOnlySegmentIds = renderState.activeSegments
      .filter((segment) => stringCharacters(segment.text).every(isLineBreakCharacter))
      .map((segment) => segment.id);

    if (lineBreakOnlySegmentIds.length === 0) return undefined;

    const timer = setTimeout(() => {
      lineBreakOnlySegmentIds.forEach(settleSegment);
    }, 0);

    return () => clearTimeout(timer);
  }, [renderState.activeSegments]);

  const maxDelayIndex = Math.max(0, maxAnimatedCharacters - 1);

  return (
    <span className={cx(commonTextClasses, className)}>
      {renderState.settledContent}
      {renderState.activeSegments.map((segment) => {
        const animatedCharacters = Array.from(segment.text);
        const lastAnimatedIndex = (() => {
          for (let index = animatedCharacters.length - 1; index >= 0; index -= 1) {
            if (!isLineBreakCharacter(animatedCharacters[index] ?? "")) {
              return index;
            }
          }
          return -1;
        })();

        if (lastAnimatedIndex === -1) {
          return segment.text;
        }

        return renderCharacterRuns(
          animatedCharacters,
          (character, index) => {
            const last = index === animatedCharacters.length - 1;
            const lastAnimated = index === lastAnimatedIndex;
            const delayMs =
              Math.min(index, maxDelayIndex) * blurAnimation.characterDelayMs;
            return (
              <CommaCompleteBlurCharacter
                key={`${segment.id}-${index}`}
                onAnimationComplete={
                  last || lastAnimated ? () => settleSegment(segment.id) : undefined
                }
                shouldAnimate
                style={
                  {
                    "--markdown-stream-char-delay": `${delayMs}ms`,
                  } as CSSProperties
                }
                timeoutMs={delayMs + blurAnimation.durationMs}
              >
                {character}
              </CommaCompleteBlurCharacter>
            );
          },
          `${segment.id}`
        );
      })}
    </span>
  );
}

function CommaTextNode(props: CommaNodeProps<MarkdownNode>) {
  const content = firstString(props.node.content, props.node.raw);
  const config = useContext(MarkdownStreamContext);

  if (content === undefined && props.children) {
    return <span className={commonTextClasses}>{props.children}</span>;
  }

  if (config.animation === "reveal") {
    return <CommaRevealingText content={content ?? ""} />;
  }

  return (
    <CommaAnimatedText
      content={content ?? ""}
      streamKey={String(props.indexKey ?? "")}
      streamState={props.ctx?.textStreamState}
    />
  );
}

function CommaRevealingText({ content }: { content: string }) {
  const painter = useContext(MarkdownStreamTextRevealContext);
  const root = useContext(MarkdownStreamRevealRootContext);
  const { final, settled, isDark } = useContext(MarkdownStreamContext);
  const ref = useRef<HTMLSpanElement>(null);
  const previousNode = useRef<Text | null>(null);
  useLayoutEffect(() => {
    const element = ref.current;
    const node = element?.firstChild;
    if (previousNode.current && previousNode.current !== node) {
      root?.leaves.delete(previousNode.current);
      if (root) root.dirty = true;
      previousNode.current = null;
    }
    if (!element || !node || node.nodeType !== Node.TEXT_NODE) return;
    const text = node as Text;
    previousNode.current = text;
    const enabled = !final && !settled && !element.closest("pre, code, svg, .katex");
    if (enabled && painter) {
      element.style.setProperty(
        "--comma-stream-text-color",
        getComputedStyle(element).color
      );
    }
    if (root) {
      root.leaves.set(text, { node: text, content, enabled: Boolean(enabled) });
      root.dirty = true;
    }
    if (!enabled) element.style.removeProperty("--comma-stream-text-color");
  }, [content, final, settled, isDark, painter, root]);
  useLayoutEffect(
    () => () => {
      if (previousNode.current) root?.leaves.delete(previousNode.current);
      if (root) root.dirty = true;
      previousNode.current = null;
    },
    [root]
  );
  return (
    <span className={commonTextClasses} data-comma-text-reveal="" ref={ref}>
      {content}
    </span>
  );
}

function CommaTextRevealRoot({
  rootKey,
  children,
}: {
  rootKey: string;
  children: ReactNode;
}) {
  const painter = useContext(MarkdownStreamTextRevealContext);
  const root = useMemo(
    () => ({ leaves: new Map<Text, TextRevealLeaf>(), dirty: false }),
    // A document painter/root change starts a distinct registration lifetime.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [painter, rootKey]
  );
  // Descendant layout effects register the current ordinary text leaves first.
  // Paint the whole changed root once, after structural replacements commit.
  useLayoutEffect(() => {
    if (!painter || !root.dirty) return;
    root.dirty = false;
    const leaves = [...root.leaves.values()].filter((leaf) => leaf.node.isConnected);
    leaves.sort((a, b) =>
      a.node === b.node
        ? 0
        : a.node.compareDocumentPosition(b.node) & Node.DOCUMENT_POSITION_FOLLOWING
          ? -1
          : 1
    );
    painter.commitRoot(rootKey, leaves);
  });
  useLayoutEffect(() => () => painter?.unmountRoot(rootKey), [painter, rootKey]);
  return (
    <MarkdownStreamRevealRootContext.Provider value={root}>
      {children}
    </MarkdownStreamRevealRootContext.Provider>
  );
}

function CommaParagraphNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "paragraph")
    )
  ) {
    return null;
  }

  const children = nodeChildren(props.node);
  const keyPrefix = childKeyPrefix(props, "paragraph");
  const chunks: ReactNode[] = [];
  let inlineChildren: MarkdownNode[] = [];

  const flushInline = () => {
    if (inlineChildren.length === 0) return;
    const chunkIndex = chunks.length;
    chunks.push(
      <p
        key={`${keyPrefix}-inline-${chunkIndex}`}
        className="markdown-stream-copy text-markdown-text-primary"
        dir="auto"
      >
        {renderChildren(props, inlineChildren, `${keyPrefix}-inline-${chunkIndex}`)}
      </p>
    );
    inlineChildren = [];
  };

  for (const child of children) {
    if (blockChildTypes.has(child.type)) {
      flushInline();
      chunks.push(
        <span className="block" key={`${keyPrefix}-block-${chunks.length}`}>
          {renderNode(
            props.renderNode,
            props.ctx,
            child,
            `${keyPrefix}-block-${chunks.length}`
          )}
        </span>
      );
    } else {
      inlineChildren.push(child);
    }
  }

  flushInline();

  if (chunks.length > 0) return <>{chunks}</>;

  return (
    <p className="markdown-stream-copy text-markdown-text-primary" dir="auto">
      {props.children}
    </p>
  );
}

function CommaHeadingNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "heading")
    )
  ) {
    return null;
  }

  const levelValue = Number(props.node.level);
  const level = Math.min(6, Math.max(1, Number.isFinite(levelValue) ? levelValue : 1));
  const Tag = `h${level}` as ElementType;
  const sizeClasses =
    level === 1
      ? "text-xl"
      : level === 2
        ? "text-lg"
        : level === 3
          ? "text-md"
          : "text-sm";

  return (
    <Tag
      className={cx(
        "markdown-stream-heading font-semibold text-markdown-text-primary",
        sizeClasses
      )}
      dir="auto"
    >
      {renderChildren(
        props,
        nodeChildren(props.node),
        childKeyPrefix(props, "heading")
      )}
    </Tag>
  );
}

function CommaInlineChildrenNode(
  props: CommaNodeProps<MarkdownNode> & {
    as: "strong" | "em" | "del" | "mark" | "ins" | "sub" | "sup";
    className?: string;
  }
) {
  const config = useContext(MarkdownStreamContext);
  const Tag = props.as;
  const children = nodeChildren(props.node);
  const content = nodeTextContent(props.node);

  if (
    content &&
    !reserveCompleteBlurTextVisibility(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, props.as)
    )
  ) {
    return null;
  }

  return (
    <Tag className={props.className}>
      {children.length > 0
        ? renderChildren(props, children, childKeyPrefix(props, props.as))
        : props.children}
    </Tag>
  );
}

function CommaInlineCodeNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content =
    firstString(props.node.code, props.node.content, props.node.raw) ?? "";

  if (
    !reserveCompleteBlurTextVisibility(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "inline-code")
    )
  ) {
    return null;
  }

  return (
    <code className="markdown-stream-inline-code bg-markdown-bg-inline-code font-mono text-markdown-text-inline-code">
      <CommaAnimatedText
        content={content}
        streamKey={`${String(props.indexKey ?? "inline-code")}:inline-code`}
        streamState={props.ctx?.textStreamState}
      />
    </code>
  );
}

function CommaHardBreakNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = nodeTextContent(props.node);
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "hard-break")
    )
  ) {
    return null;
  }

  return <br />;
}

function CommaThematicBreakNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = nodeTextContent(props.node) || "\n";
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "thematic-break")
    )
  ) {
    return null;
  }

  return (
    <hr className="markdown-stream-rule m-0 border-0 border-t-[0.5px] border-markdown-border-table" />
  );
}

function CommaBlockquoteNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "blockquote")
    )
  ) {
    return null;
  }

  return (
    <blockquote className="markdown-stream-quote m-0 py-md pl-3xl text-markdown-text-primary">
      {renderChildren(
        props,
        nodeChildren(props.node),
        childKeyPrefix(props, "blockquote")
      )}
    </blockquote>
  );
}

function CommaListNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "list")
    )
  ) {
    return null;
  }

  const ordered = Boolean(props.node.ordered);
  const Tag = ordered ? "ol" : "ul";
  const items = Array.isArray(props.node.items)
    ? props.node.items.filter(isMarkdownNode)
    : nodeChildren(props.node);
  const start = typeof props.node.start === "number" ? props.node.start : undefined;
  const keyPrefix = childKeyPrefix(props, "list");

  return (
    <Tag
      className={cx(
        "markdown-stream-list text-markdown-text-primary",
        ordered ? "markdown-stream-list-ordered" : "markdown-stream-list-unordered"
      )}
      start={start}
    >
      {items.map((item, index) =>
        renderNode(props.renderNode, props.ctx, item, `${keyPrefix}-${index}`)
      )}
    </Tag>
  );
}

function CommaListItemNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "list-item")
    )
  ) {
    return null;
  }

  const children = nodeChildren(props.node);
  const isTaskItem = children.some(
    (child) =>
      child.type === "checkbox" ||
      child.type === "checkbox_input" ||
      ((child.type === "paragraph" || child.type === "inline") &&
        nodeChildren(child).some(
          (inlineChild) =>
            inlineChild.type === "checkbox" || inlineChild.type === "checkbox_input"
        ))
  );
  return (
    <li
      className={cx(
        "markdown-stream-list-item",
        isTaskItem && "markdown-stream-list-item-task"
      )}
    >
      {renderChildren(props, children, childKeyPrefix(props, "list-item"))}
    </li>
  );
}

function CommaLinkNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const documentPolicy = useContext(MarkdownDocumentResourceContext);
  const linkDecorator = useContext(MarkdownStreamLinkDecoratorContext);
  const candidateHref = safeHref(props.node.href);
  const href =
    documentPolicy && candidateHref && !isExternalHref(candidateHref)
      ? undefined
      : candidateHref;
  const text = asString(props.node.text);
  const children = nodeChildren(props.node);
  const content = children.length > 0 ? nodeTextContent(props.node) : text;

  if (
    content &&
    !reserveCompleteBlurTextVisibility(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "link")
    )
  ) {
    return null;
  }

  const renderedChildren =
    children.length > 0 ? (
      renderChildren(props, children, childKeyPrefix(props, "link"))
    ) : (
      <CommaAnimatedText
        content={text}
        streamKey={`${String(props.indexKey ?? "link")}:link-text`}
        streamState={props.ctx?.textStreamState}
      />
    );

  if (!href) {
    return <span>{renderedChildren}</span>;
  }

  const external = isExternalHref(href);
  const anchor = (
    <a
      className="markdown-stream-link font-medium text-markdown-text-link"
      href={href}
      onClick={
        documentPolicy
          ? (event) => {
              event.preventDefault();
              event.stopPropagation();
              documentPolicy.onOpenLink(href);
            }
          : undefined
      }
      rel={external ? "noopener noreferrer" : undefined}
      target={external ? "_blank" : undefined}
      title={asString(props.node.title) || undefined}
    >
      <MarkdownStreamInsideLinkContext.Provider value={true}>
        {renderedChildren}
      </MarkdownStreamInsideLinkContext.Provider>
    </a>
  );
  // Decorate only once the stream is final (see MarkdownStreamLinkDecorator's
  // finality guarantee): a still-streaming href may be a truncated prefix of
  // the real link, and flipping between wrapped and bare would remount the
  // anchor while the user hovers it.
  if (external && linkDecorator && config.final && !documentPolicy) {
    return <>{linkDecorator({ anchor, href })}</>;
  }
  return anchor;
}

function CommaImageNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const messages = useCommaMessages();
  const documentPolicy = useContext(MarkdownDocumentResourceContext);
  const insideLink = useContext(MarkdownStreamInsideLinkContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "image")
    )
  ) {
    return null;
  }

  const src = safeHref(props.node.src);
  const pending = Boolean(props.node.loading);
  if (!src && !pending) return null;

  // Markdown carries no intrinsic dimensions. A consistent preview frame keeps
  // later prose anchored while bytes load; the original remains one click away.
  const alt = asString(props.node.alt);
  if (documentPolicy)
    return <span>{messages.file_preview_remote_image({ name: alt || "image" })}</span>;
  const Frame = insideLink ? "span" : "a";
  return (
    <Frame
      aria-label={alt || messages.chat_image_group_preview()}
      className="markdown-stream-image-preview markdown-stream-surface"
      aria-busy={pending && !config.final}
      href={insideLink || pending ? undefined : (src ?? undefined)}
      rel={insideLink ? undefined : "noopener noreferrer"}
      target={insideLink ? undefined : "_blank"}
    >
      {pending ? (
        <span className="text-sm text-markdown-text-tool-primary">
          {alt || messages.chat_image_group_preview()}
        </span>
      ) : (
        <img
          alt={alt}
          decoding="async"
          loading="lazy"
          src={src!}
          title={asString(props.node.title) || undefined}
        />
      )}
    </Frame>
  );
}

function CommaTableNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "table")
    )
  ) {
    return null;
  }

  const header = props.node.header as { cells?: MarkdownNode[] } | undefined;
  const headerCells = Array.isArray(header?.cells)
    ? header.cells.filter(isMarkdownNode)
    : [];
  const rows = Array.isArray(props.node.rows)
    ? props.node.rows.filter(
        (row): row is { cells: MarkdownNode[] } =>
          typeof row === "object" &&
          row !== null &&
          Array.isArray((row as { cells?: unknown }).cells)
      )
    : [];
  const keyPrefix = childKeyPrefix(props, "table");

  return (
    <ScrollArea
      className="markdown-stream-surface m-0 max-w-full border-[0.5px] border-markdown-border-table bg-markdown-bg-tool"
      contentStyle={{ minWidth: "100%" }}
      edgeEffect="none"
      orientation="horizontal"
    >
      <table
        className="w-full table-fixed border-collapse text-left text-sm leading-5 text-markdown-text-primary"
        style={{
          minWidth: `${Math.max(1, headerCells.length, rows[0]?.cells.length ?? 0) * 9}rem`,
        }}
      >
        {headerCells.length > 0 ? (
          <thead className="bg-markdown-bg-table">
            <tr className="border-b-[0.5px] border-markdown-border-table">
              {headerCells.map((cell, index) => {
                if (
                  !shouldRenderCompleteBlurNode(
                    config.completeBlurTextQueue,
                    cell,
                    `${keyPrefix}-th-${index}`
                  )
                ) {
                  return null;
                }

                return (
                  <th
                    className="px-xl py-lg font-semibold"
                    key={`${keyPrefix}-th-${index}`}
                  >
                    {renderChildren(
                      props,
                      nodeChildren(cell),
                      `${keyPrefix}-th-${index}`
                    )}
                  </th>
                );
              })}
            </tr>
          </thead>
        ) : null}
        <tbody>
          {rows.map((row, rowIndex) => {
            const cells = row.cells.map((cell, cellIndex) => {
              if (
                !shouldRenderCompleteBlurNode(
                  config.completeBlurTextQueue,
                  cell,
                  `${keyPrefix}-td-${rowIndex}-${cellIndex}`
                )
              ) {
                return null;
              }

              return (
                <td
                  className="px-xl py-lg align-top"
                  key={`${keyPrefix}-td-${rowIndex}-${cellIndex}`}
                >
                  {renderChildren(
                    props,
                    nodeChildren(cell),
                    `${keyPrefix}-td-${rowIndex}-${cellIndex}`
                  )}
                </td>
              );
            });

            if (cells.every((cell) => cell === null)) return null;

            return (
              <tr
                className="border-b-[0.5px] border-markdown-border-table last:border-b-0"
                key={`${keyPrefix}-row-${rowIndex}`}
              >
                {cells}
              </tr>
            );
          })}
        </tbody>
      </table>
    </ScrollArea>
  );
}

function CommaDefinitionListNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  if (
    !shouldRenderCompleteBlurNode(
      config.completeBlurTextQueue,
      props.node,
      completeBlurReservationKey(props.indexKey, "definition-list")
    )
  ) {
    return null;
  }

  const items = Array.isArray(props.node.items)
    ? props.node.items.filter(isMarkdownNode)
    : [];
  const keyPrefix = childKeyPrefix(props, "definition-list");

  return (
    <dl className="m-0 grid gap-xl text-markdown-text-primary">
      {items.map((item, index) => {
        if (
          !shouldRenderCompleteBlurNode(
            config.completeBlurTextQueue,
            item,
            `${keyPrefix}-${index}`
          )
        ) {
          return null;
        }

        const term = Array.isArray(item.term) ? item.term.filter(isMarkdownNode) : [];
        const definition = Array.isArray(item.definition)
          ? item.definition.filter(isMarkdownNode)
          : [];

        return (
          <div className="grid gap-sm" key={`${keyPrefix}-${index}`}>
            <dt className="font-semibold">
              {renderChildren(props, term, `${keyPrefix}-${index}-term`)}
            </dt>
            <dd className="m-0 border-l-2 border-markdown-border-table pl-xl text-markdown-text-tool-primary">
              {renderChildren(props, definition, `${keyPrefix}-${index}-definition`)}
            </dd>
          </div>
        );
      })}
    </dl>
  );
}

function CommaFootnoteNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const id = asString(props.node.id);
  const hiddenContent = `[${id}]${nodeTextContent(props.node)}^`;

  if (!config.final) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      hiddenContent,
      completeBlurReservationKey(props.indexKey, "footnote-hidden")
    );
    return null;
  }

  return (
    <aside
      className="m-0 border-t-[0.5px] border-markdown-border-table pt-lg text-sm leading-5 text-markdown-text-tool-primary"
      id={id ? `footnote-${id}` : undefined}
    >
      <span className="mr-md font-medium text-markdown-text-primary">[{id}]</span>
      {renderChildren(
        props,
        nodeChildren(props.node),
        childKeyPrefix(props, "footnote")
      )}
    </aside>
  );
}

function CommaFootnoteReferenceNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const id = asString(props.node.id);
  const content = `[${id}]`;

  if (
    !reserveCompleteBlurTextVisibility(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "footnote-reference")
    )
  ) {
    return null;
  }

  return (
    <sup className="ml-0.5 text-[0.75em] leading-none">
      <a className="text-markdown-text-link hover:underline" href={`#footnote-${id}`}>
        <CommaAnimatedText
          content={content}
          streamKey={`${String(props.indexKey ?? "footnote-reference")}:footnote-ref`}
          streamState={props.ctx?.textStreamState}
        />
      </a>
    </sup>
  );
}

function CommaFootnoteAnchorNode(props: CommaNodeProps<MarkdownNode>) {
  const id = asString(props.node.id);

  return (
    <a className="ml-2 text-markdown-text-link hover:underline" href={`#fnref-${id}`}>
      ^
    </a>
  );
}

function CommaAdmonitionNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const kind = asString(props.node.kind) || asString(props.node.name) || "note";
  const title = asString(props.node.title) || kind;
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      `${title}${nodeTextContent(props.node)}`,
      completeBlurReservationKey(props.indexKey, "admonition")
    )
  ) {
    return null;
  }

  return (
    <section className="markdown-stream-surface m-0 border-[0.5px] border-markdown-border-table bg-markdown-bg-message p-xl text-markdown-text-primary">
      <div className="mb-lg text-sm font-semibold capitalize text-markdown-text-tool-primary">
        <CommaAnimatedText
          content={title}
          streamKey={`${String(props.indexKey ?? "admonition")}:title`}
          streamState={props.ctx?.textStreamState}
        />
      </div>
      {renderChildren(
        props,
        nodeChildren(props.node),
        childKeyPrefix(props, "admonition")
      )}
    </section>
  );
}

function CommaVmrContainerNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const title = asString(props.node.name) || "container";
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      `${title}${nodeTextContent(props.node)}`,
      completeBlurReservationKey(props.indexKey, "container")
    )
  ) {
    return null;
  }

  return (
    <section className="markdown-stream-surface m-0 border-[0.5px] border-markdown-border-table bg-markdown-bg-tool p-xl text-markdown-text-primary">
      <div className="mb-lg text-sm font-semibold capitalize text-markdown-text-tool-primary">
        <CommaAnimatedText
          content={title}
          streamKey={`${String(props.indexKey ?? "container")}:title`}
          streamState={props.ctx?.textStreamState}
        />
      </div>
      {renderChildren(
        props,
        nodeChildren(props.node),
        childKeyPrefix(props, "container")
      )}
    </section>
  );
}

function CommaMathInlineNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = asString(props.node.content) || asString(props.node.raw);
  const completeBlurRange = getCompleteBlurTextRange(
    config.completeBlurTextQueue,
    content,
    completeBlurReservationKey(props.indexKey, "math-inline")
  );

  if (!completeBlurRange.visible) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "math-inline")
    );
    return null;
  }

  if (config.completeBlurTextQueue && !completeBlurRange.complete) {
    return (
      <code className="markdown-stream-inline-code bg-markdown-bg-inline-code font-mono text-markdown-text-inline-code">
        <CommaAnimatedText
          content={content}
          streamKey={`${String(props.indexKey ?? "math-inline")}:math-inline`}
          streamState={props.ctx?.textStreamState}
        />
      </code>
    );
  }

  if (config.completeBlurTextQueue) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "math-inline")
    );
  }

  const node = {
    ...props.node,
    type: "math_inline",
    content,
    raw: asString(props.node.raw) || content,
  } as MathInlineRenderNode;

  return <MathInlineNode node={node} />;
}

function CommaMathBlockNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = asString(props.node.content) || asString(props.node.raw);
  const completeBlurRange = getCompleteBlurTextRange(
    config.completeBlurTextQueue,
    content,
    completeBlurReservationKey(props.indexKey, "math-block")
  );

  if (!completeBlurRange.visible) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "math-block")
    );
    return null;
  }

  if (config.completeBlurTextQueue && !completeBlurRange.complete) {
    return (
      <ScrollArea
        className="markdown-stream-surface m-0 border-[0.5px] border-markdown-border-table bg-markdown-bg-tool"
        orientation="horizontal"
        edgeEffect="none"
        contentStyle={{ minWidth: "100%" }}
      >
        <pre className="m-0 p-lg font-mono text-sm leading-5 text-markdown-text-primary">
          <code>
            <CommaAnimatedText
              content={content}
              streamKey={`${String(props.indexKey ?? "math-block")}:math-block`}
              streamState={props.ctx?.textStreamState}
            />
          </code>
        </pre>
      </ScrollArea>
    );
  }

  if (config.completeBlurTextQueue) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "math-block")
    );
  }

  const node = {
    ...props.node,
    type: "math_block",
    content,
    raw: asString(props.node.raw) || content,
  } as MathBlockRenderNode;

  return (
    <ScrollArea
      className="markdown-stream-surface m-0 border-[0.5px] border-markdown-border-table bg-markdown-bg-tool p-md text-markdown-text-primary"
      orientation="horizontal"
      edgeEffect="none"
      contentStyle={{ minWidth: "100%" }}
    >
      <MathBlockNode node={node} />
    </ScrollArea>
  );
}

function CommaEmojiNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = asString(props.node.name) || asString(props.node.markup);
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "emoji")
    )
  ) {
    return null;
  }

  return (
    <CommaAnimatedText
      content={content}
      streamKey={`${String(props.indexKey ?? "emoji")}:emoji`}
      streamState={props.ctx?.textStreamState}
    />
  );
}

function CommaReferenceNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = asString(props.node.id);
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "reference")
    )
  ) {
    return null;
  }

  return (
    <span className="mx-xxs rounded-xs bg-markdown-bg-inline-code px-sm py-xxs text-xs text-markdown-text-inline-primary">
      <CommaAnimatedText
        content={content}
        streamKey={`${String(props.indexKey ?? "reference")}:reference`}
        streamState={props.ctx?.textStreamState}
      />
    </span>
  );
}

function CommaHtmlNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const content = asString(props.node.content) || asString(props.node.raw);
  if (
    !shouldRenderCompleteBlurContent(
      config.completeBlurTextQueue,
      content,
      completeBlurReservationKey(props.indexKey, "html")
    )
  ) {
    return null;
  }

  return (
    <code className="markdown-stream-inline-code bg-markdown-bg-inline-code font-mono text-markdown-text-inline-code">
      <CommaAnimatedText
        content={content}
        streamKey={`${String(props.indexKey ?? "html")}:html`}
        streamState={props.ctx?.textStreamState}
      />
    </code>
  );
}

type CodeHighlightObserverGroup = {
  observer: IntersectionObserver;
  targets: Map<Element, () => void>;
};

const codeHighlightObserverGroups = new Map<
  Element | null,
  CodeHighlightObserverGroup
>();

function observeCodeHighlightActivation(element: Element, activate: () => void) {
  if (typeof IntersectionObserver !== "function") {
    activate();
    return () => {};
  }

  const root = element.closest('[data-slot="scroll-area-viewport"]');
  let group = codeHighlightObserverGroups.get(root);
  if (!group) {
    const targets = new Map<Element, () => void>();
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting && entry.intersectionRatio <= 0) continue;
          const targetActivation = targets.get(entry.target);
          if (!targetActivation) continue;
          targets.delete(entry.target);
          observer.unobserve(entry.target);
          targetActivation();
        }
        if (targets.size === 0) {
          observer.disconnect();
          codeHighlightObserverGroups.delete(root);
        }
      },
      { root, rootMargin: "480px 0px" }
    );
    group = { observer, targets };
    codeHighlightObserverGroups.set(root, group);
  }

  group.targets.set(element, activate);
  group.observer.observe(element);
  const observerGroup = group;

  return () => {
    if (!observerGroup.targets.delete(element)) return;
    observerGroup.observer.unobserve(element);
    if (observerGroup.targets.size > 0) return;
    observerGroup.observer.disconnect();
    codeHighlightObserverGroups.delete(root);
  };
}

interface CodeHighlightInput {
  scopeKey: string;
  source: string;
  language: string;
  theme: string;
}

export function codeTokenStyle(token: ShikiHighlightToken): CSSProperties {
  const fontStyle = token.fontStyle ?? 0;
  return {
    color: token.color,
    backgroundColor: token.bgColor,
    ...(fontStyle > 0 && fontStyle & 1 ? { fontStyle: "italic" } : {}),
    ...(fontStyle > 0 && fontStyle & 2 ? { fontWeight: "bold" } : {}),
    ...(fontStyle > 0 && fontStyle & 12
      ? {
          textDecoration: [
            fontStyle & 4 ? "underline" : "",
            fontStyle & 8 ? "line-through" : "",
          ]
            .filter(Boolean)
            .join(" "),
        }
      : {}),
  };
}

function CommaHighlightedCodeBlock({
  animateFallback,
  code,
  deferHighlight,
  language,
  isDark,
  streamKey,
  streamState,
  darkTheme,
  lightTheme,
  onRendered,
}: {
  animateFallback: boolean;
  code: string;
  deferHighlight: boolean;
  language: string;
  isDark: boolean;
  streamKey: string;
  streamState?: RenderContext["textStreamState"];
  darkTheme?: string;
  lightTheme?: string;
  onRendered: () => void;
  themes?: readonly string[];
}) {
  const config = useContext(MarkdownStreamContext);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const onRenderedRef = useRef(onRendered);
  const [highlight, setHighlight] = useState<{
    input: CodeHighlightInput;
    result: ShikiHighlightResult;
  } | null>(null);
  const [failure, setFailure] = useState<{
    input: CodeHighlightInput;
    message: string;
  } | null>(null);
  const schedulerRef = useRef<ReturnType<
    typeof createCoalescedAsyncRender<CodeHighlightInput, ShikiHighlightResult>
  > | null>(null);
  const [highlightActivated, setHighlightActivated] = useState(
    () => typeof IntersectionObserver !== "function"
  );
  onRenderedRef.current = onRendered;
  const theme = isDark
    ? (darkTheme ?? "vitesse-dark")
    : (lightTheme ?? "vitesse-light");
  const shikiLanguage = normalizeHighlightLanguage(language);
  const scopeKey = JSON.stringify([streamKey, theme, shikiLanguage]);

  useEffect(() => {
    const scheduler = createCoalescedAsyncRender<
      CodeHighlightInput,
      ShikiHighlightResult
    >({
      render: (input) =>
        renderCodeHighlightInWorker(input.source, input.language, input.theme),
      onResult: (result, input) => {
        setHighlight({ input, result });
        setFailure(null);
      },
      onError: (error, input) => {
        setFailure({
          input,
          message: error instanceof Error ? error.message : String(error),
        });
      },
    });
    schedulerRef.current = scheduler;
    return () => {
      scheduler.dispose();
      schedulerRef.current = null;
    };
  }, []);

  useLayoutEffect(() => {
    if (highlightActivated) return;
    const surface = surfaceRef.current;
    if (!surface) return;
    return observeCodeHighlightActivation(surface, () => setHighlightActivated(true));
  }, [highlightActivated]);

  const highlightDeferred = deferHighlight || !highlightActivated;
  useEffect(() => {
    setHighlight((previous) =>
      previous?.input.scopeKey === scopeKey && code.startsWith(previous.input.source)
        ? previous
        : null
    );
    setFailure((previous) =>
      previous?.input.scopeKey === scopeKey && previous.input.source === code
        ? previous
        : null
    );
    if (highlightDeferred) return;
    schedulerRef.current?.update({
      scopeKey,
      source: code,
      language: shikiLanguage,
      theme,
    });
  }, [code, highlightDeferred, scopeKey, shikiLanguage, theme]);

  const visibleHighlight =
    !highlightDeferred &&
    highlight?.input.scopeKey === scopeKey &&
    code.startsWith(highlight.input.source)
      ? highlight.result
      : undefined;
  const highlightError =
    failure?.input.scopeKey === scopeKey && failure.input.source === code
      ? failure.message
      : undefined;
  const lines = useMemo(
    () => highlightedCodeLines(code, visibleHighlight),
    [code, visibleHighlight]
  );

  useLayoutEffect(() => {
    onRenderedRef.current();
  }, [highlight, highlightDeferred]);

  return (
    <div className="code-block-content" ref={surfaceRef}>
      <ScrollArea
        contentStyle={{ minWidth: "100%" }}
        edgeEffect="none"
        onContentResize={onRendered}
        orientation="horizontal"
      >
        <div
          className={cx(
            "code-block-render",
            !visibleHighlight && "code-block-render-pending"
          )}
        >
          <pre
            className={cx(
              "shiki m-0 font-mono",
              !visibleHighlight && "shiki-fallback code-fallback-plain"
            )}
            data-highlight-error={highlightError}
            data-theme={visibleHighlight?.themeName}
            style={{
              color: visibleHighlight?.fg,
              backgroundColor: visibleHighlight?.bg,
            }}
          >
            <code>
              {animateFallback && !visibleHighlight && config.animation === "blur" ? (
                <CommaAnimatedText
                  content={code}
                  streamKey={streamKey}
                  streamState={streamState}
                />
              ) : (
                lines.map((line, index) => (
                  <span className="line" key={index}>
                    {line.map((token) => (
                      <span key={token.offset} style={codeTokenStyle(token)}>
                        {token.content}
                      </span>
                    ))}
                    {index < lines.length - 1 ? "\n" : null}
                  </span>
                ))
              )}
            </code>
          </pre>
        </div>
      </ScrollArea>
    </div>
  );
}

function CommaCodeBlockNode(props: CommaNodeProps<MarkdownNode>) {
  const language = normalizeLanguage(props.node.language);
  if (language === "mermaid") {
    return <CommaMermaidNode {...props} />;
  }

  return <CommaStandardCodeBlockNode {...props} />;
}

function CommaStandardCodeBlockNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const code = codeBlockContent(props.node);
  const language = normalizeLanguage(props.node.language);
  const loading = Boolean(props.node.loading);
  const completeBlurRange = getCompleteBlurTextRange(
    config.completeBlurTextQueue,
    code,
    completeBlurReservationKey(props.indexKey, "code-block")
  );
  const blockVisible = completeBlurRange.visible;
  const blockComplete = !config.completeBlurTextQueue || completeBlurRange.complete;

  if (!blockVisible) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      code,
      completeBlurReservationKey(props.indexKey, "code-block")
    );
    return null;
  }

  if (config.completeBlurTextQueue && blockComplete) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      code,
      completeBlurReservationKey(props.indexKey, "code-block")
    );
  }

  return (
    <CommaStandardCodeBlock
      animateFallback={!config.completeBlurTextQueue || !blockComplete}
      code={code}
      config={config}
      ctx={props.ctx}
      deferHighlight={!blockComplete}
      indexKey={props.indexKey}
      language={language}
      loading={loading}
    />
  );
}

interface CommaStandardCodeBlockProps {
  animateFallback: boolean;
  code: string;
  config: MarkdownStreamContextValue;
  ctx?: RenderContext | undefined;
  deferHighlight: boolean;
  indexKey: unknown;
  language: string;
  loading: boolean;
}

function CommaCopyStateIcon({ copied }: { copied: boolean }) {
  return (
    <span
      aria-hidden="true"
      className="t-icon-swap size-2xl"
      data-state={copied ? "b" : "a"}
      data-swap-blur="none"
    >
      <span className="t-icon inline-flex size-2xl" data-icon="a">
        <CopyIcon className="size-2xl" />
      </span>
      <span className="t-icon inline-flex size-2xl" data-icon="b">
        <CheckIcon className="size-2xl text-fg-success-primary" />
      </span>
    </span>
  );
}

const CommaStandardCodeBlock = memo(
  function CommaStandardCodeBlock({
    animateFallback,
    code,
    config,
    ctx,
    deferHighlight,
    indexKey,
    language,
    loading,
  }: CommaStandardCodeBlockProps) {
    const messages = useCommaMessages();
    const [copied, setCopied] = useState(false);
    const [expanded, setExpanded] = useState(false);
    const [collapsible, setCollapsible] = useState(false);
    const [highlightRenderRevision, setHighlightRenderRevision] = useState(0);
    const codeBodyRef = useRef<HTMLDivElement>(null);
    const resetTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const info = useMemo(
      () => ({ code, language, loading }),
      [code, language, loading]
    );
    const codeLines = useMemo(() => code.split(/\r\n|\r|\n/), [code]);
    const codeNeedsPreviewWindow = codeLines.length > codeBlockPreviewLineCount;
    const highlightedCode = useMemo(
      () =>
        codeNeedsPreviewWindow && !expanded
          ? codeLines.slice(0, codeBlockPreviewLineCount).join("\n")
          : code,
      [code, codeLines, codeNeedsPreviewWindow, expanded]
    );
    const darkTheme = firstString(ctx?.codeBlockThemes?.darkTheme);
    const lightTheme = firstString(ctx?.codeBlockThemes?.lightTheme);
    const themes = asStringArray(ctx?.codeBlockThemes?.themes);
    const codeHighlightProps = {
      ...(darkTheme ? { darkTheme } : {}),
      ...(lightTheme ? { lightTheme } : {}),
      ...(themes ? { themes } : {}),
    };

    useEffect(
      () => () => {
        if (resetTimer.current) clearTimeout(resetTimer.current);
      },
      []
    );

    const measureCollapsibility = useCallback(() => {
      const codeBody = codeBodyRef.current;
      if (!codeBody) return;
      const codeContent = codeBody.querySelector<HTMLElement>(".code-block-content");
      const contentHeight = codeContent?.scrollHeight ?? codeBody.scrollHeight;
      const nextCollapsible =
        codeNeedsPreviewWindow || contentHeight > codeBlockCollapsedHeightPx;
      setCollapsible(nextCollapsible);
      if (!nextCollapsible) setExpanded(false);
    }, [codeNeedsPreviewWindow]);

    const handleHighlightRendered = useCallback(() => {
      setHighlightRenderRevision((revision) => revision + 1);
    }, []);

    useLayoutEffect(() => {
      measureCollapsibility();
    }, [code, highlightRenderRevision, loading, measureCollapsibility]);

    const copyCode = async () => {
      if (config.clipboard) {
        await config.clipboard.writeText(code);
      } else if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(code);
      } else {
        throw new Error("Clipboard write is unavailable in this runtime.");
      }
      config.onCopyCode?.(info);
      setCopied(true);
      if (resetTimer.current) clearTimeout(resetTimer.current);
      resetTimer.current = setTimeout(() => setCopied(false), 1400);
    };

    const showHeader = config.showCodeBlockHeader || config.showCodeBlockCopy;
    return (
      <figure
        className="markdown-stream-code-block markdown-stream-surface m-0 overflow-hidden bg-markdown-bg-table"
        data-code-expanded={expanded ? "true" : "false"}
      >
        {showHeader ? (
          <figcaption className="flex min-h-5xl items-center justify-between gap-lg px-lg py-xxs text-sm text-markdown-text-tool-primary">
            <div className="min-w-0 truncate font-medium text-secondary">
              {config.showCodeBlockHeader
                ? (config.renderCodeBlockHeader?.(info) ?? language)
                : null}
            </div>
            {config.showCodeBlockCopy ? (
              <button
                aria-label={
                  copied
                    ? messages.markdown_code_copied()
                    : messages.markdown_copy_code()
                }
                className="markdown-stream-control inline-flex size-3xl shrink-0 items-center justify-center rounded-sm text-markdown-text-tool-primary outline-none focus-visible:shadow-focus-gray-shadow-xs"
                onClick={copyCode}
                title={
                  copied ? messages.markdown_copied() : messages.markdown_copy_code()
                }
                type="button"
              >
                <CommaCopyStateIcon copied={copied} />
              </button>
            ) : null}
          </figcaption>
        ) : null}
        <div
          aria-busy={loading}
          className={cx(
            "markdown-stream-code-body relative bg-markdown-bg-table text-markdown-text-primary",
            collapsible && !expanded && "markdown-stream-code-body-collapsed",
            collapsible && expanded && "markdown-stream-code-body-expanded"
          )}
          data-language={language}
          ref={codeBodyRef}
        >
          {collapsible ? (
            <>
              <Button
                aria-expanded={expanded}
                className="markdown-stream-code-expand h-auto py-xs pl-xs pr-md text-xs"
                hierarchy="secondary-gray"
                iconLeading={
                  expanded ? (
                    <ChevronTopSmallIcon aria-hidden />
                  ) : (
                    <ChevronDownSmallIcon aria-hidden />
                  )
                }
                onPress={() => setExpanded((current) => !current)}
                size="sm"
              >
                {expanded
                  ? messages.markdown_collapse_code()
                  : messages.markdown_expand_code({
                      count: code.length === 0 ? 0 : codeLines.length,
                    })}
              </Button>
            </>
          ) : null}
          <CommaHighlightedCodeBlock
            {...codeHighlightProps}
            animateFallback={animateFallback}
            code={highlightedCode}
            deferHighlight={deferHighlight}
            isDark={config.isDark}
            language={language}
            onRendered={handleHighlightRendered}
            streamKey={`${String(indexKey ?? "code")}:code:${language}`}
            streamState={ctx?.textStreamState}
          />
          {collapsible && !expanded ? (
            <div aria-hidden className="markdown-stream-code-fade" />
          ) : null}
        </div>
      </figure>
    );
  },
  (previous, next) =>
    previous.animateFallback === next.animateFallback &&
    previous.code === next.code &&
    previous.config === next.config &&
    previous.deferHighlight === next.deferHighlight &&
    String(previous.indexKey ?? "") === String(next.indexKey ?? "") &&
    previous.language === next.language &&
    previous.loading === next.loading &&
    previous.ctx === next.ctx
);

function CommaMermaidNode(props: CommaNodeProps<MarkdownNode>) {
  const config = useContext(MarkdownStreamContext);
  const documentPolicy = useContext(MarkdownDocumentResourceContext);
  const code = codeBlockContent(props.node);
  if (documentPolicy)
    return (
      <ScrollArea edgeEffect="none">
        <pre>{code}</pre>
      </ScrollArea>
    );
  const loading = Boolean(props.node.loading);
  const completeBlurRange = getCompleteBlurTextRange(
    config.completeBlurTextQueue,
    code,
    completeBlurReservationKey(props.indexKey, "mermaid")
  );
  const blockVisible = completeBlurRange.visible;
  const blockComplete = !config.completeBlurTextQueue || completeBlurRange.complete;

  if (!blockVisible) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      code,
      completeBlurReservationKey(props.indexKey, "mermaid")
    );
    return null;
  }

  if (config.completeBlurTextQueue && blockComplete) {
    reserveHiddenCompleteBlurText(
      config.completeBlurTextQueue,
      code,
      completeBlurReservationKey(props.indexKey, "mermaid")
    );
  }

  return (
    <CommaMermaidBlock
      animateFallback={!config.completeBlurTextQueue || !blockComplete}
      code={code}
      config={config}
      ctx={props.ctx}
      deferPreview={!blockComplete || loading}
      indexKey={props.indexKey}
      loading={loading}
    />
  );
}

interface CommaMermaidBlockProps {
  animateFallback: boolean;
  code: string;
  config: MarkdownStreamContextValue;
  ctx?: RenderContext | undefined;
  deferPreview: boolean;
  indexKey: unknown;
  loading: boolean;
}

const CommaMermaidBlock = memo(
  function CommaMermaidBlock({
    animateFallback,
    code,
    config,
    ctx,
    deferPreview,
    indexKey,
    loading,
  }: CommaMermaidBlockProps) {
    const messages = useCommaMessages();
    const language = "mermaid";
    const [mode, setMode] = useState<MermaidMode>("preview");
    const [svg, setSvg] = useState("");
    const [error, setError] = useState<string | null>(null);
    const [rendering, setRendering] = useState(false);
    const [copied, setCopied] = useState(false);
    const reactId = useId();
    const renderCounter = useRef(0);
    const resetTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const isDark = config.isDark;
    const showHeader = config.showCodeBlockHeader || config.showCodeBlockCopy;
    const canRenderPreview = code.trim().length > 0;
    const renderIdPrefix = useMemo(
      () => `comma-mermaid-${reactId.replace(/[^a-zA-Z0-9_-]/g, "")}`,
      [reactId]
    );

    useEffect(
      () => () => {
        if (resetTimer.current) clearTimeout(resetTimer.current);
      },
      []
    );

    useEffect(() => {
      let cancelled = false;
      const trimmedCode = code.trim();

      if (deferPreview || !trimmedCode) {
        setSvg("");
        setError(null);
        setRendering(false);
        return;
      }

      setRendering(true);

      const timer = window.setTimeout(
        () => {
          const render = async () => {
            try {
              const moduleValue = await import("mermaid");
              if (cancelled) return;

              const mermaid = resolveMermaidApi(moduleValue);
              if (!mermaid) {
                throw new Error(messages.markdown_renderer_unavailable());
              }

              mermaid.initialize?.({
                startOnLoad: false,
                securityLevel: "strict",
                suppressErrorRendering: true,
                htmlLabels: false,
                flowchart: { htmlLabels: false },
                ...mermaidThemeConfig(isDark),
              });

              const renderId = `${renderIdPrefix}-${renderCounter.current++}`;
              const result = await mermaid.render(
                renderId,
                withMermaidThemeInit(trimmedCode, isDark)
              );
              if (cancelled) return;

              const nextSvg = sanitizeMermaidSvg(result.svg ?? "");
              if (!nextSvg) {
                throw new Error(messages.markdown_empty_diagram_error());
              }

              setSvg(nextSvg);
              setError(null);
            } catch (caught) {
              if (cancelled) return;
              setError(caught instanceof Error ? caught.message : String(caught));
            } finally {
              if (!cancelled) setRendering(false);
            }
          };

          void render();
        },
        loading ? 180 : 0
      );

      return () => {
        cancelled = true;
        window.clearTimeout(timer);
      };
    }, [code, deferPreview, isDark, loading, messages, renderIdPrefix]);

    const copyCode = async () => {
      if (config.clipboard) {
        await config.clipboard.writeText(code);
      } else if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(code);
      } else {
        throw new Error("Clipboard write is unavailable in this runtime.");
      }
      config.onCopyCode?.({ code, language, loading });
      setCopied(true);
      if (resetTimer.current) clearTimeout(resetTimer.current);
      resetTimer.current = setTimeout(() => setCopied(false), 1400);
    };

    return (
      <figure
        className="markdown-stream-code-block markdown-stream-mermaid markdown-stream-surface m-0 overflow-hidden bg-markdown-bg-table"
        data-mode={mode}
      >
        {showHeader ? (
          <figcaption className="flex min-h-5xl items-center justify-between gap-lg px-lg py-xxs text-sm text-markdown-text-tool-primary">
            <div className="min-w-0 truncate font-medium text-secondary">
              {config.showCodeBlockHeader
                ? (config.renderCodeBlockHeader?.({ code, language, loading }) ??
                  "Mermaid")
                : null}
            </div>
            <div className="markdown-stream-mermaid-toolbar flex shrink-0 items-center gap-md">
              <fieldset
                aria-label={messages.markdown_mermaid_display_mode()}
                className="m-0 flex items-center gap-md border-0 p-0"
              >
                <button
                  aria-pressed={mode === "preview"}
                  className={cx(
                    "markdown-stream-control inline-flex h-3xl items-center rounded-xs px-md text-xs font-medium outline-none focus-visible:z-10 focus-visible:shadow-focus-gray-shadow-xs",
                    mode === "preview"
                      ? "markdown-stream-control-active text-markdown-text-primary"
                      : "markdown-stream-control-inactive"
                  )}
                  onClick={() => setMode("preview")}
                  type="button"
                >
                  {messages.markdown_preview()}
                </button>
                <button
                  aria-pressed={mode === "source"}
                  className={cx(
                    "markdown-stream-control inline-flex h-3xl items-center rounded-xs px-md text-xs font-medium outline-none focus-visible:z-10 focus-visible:shadow-focus-gray-shadow-xs",
                    mode === "source"
                      ? "markdown-stream-control-active text-markdown-text-primary"
                      : "markdown-stream-control-inactive"
                  )}
                  onClick={() => setMode("source")}
                  type="button"
                >
                  {messages.markdown_source()}
                </button>
              </fieldset>
              {config.showCodeBlockCopy ? (
                <button
                  aria-label={
                    copied
                      ? messages.markdown_mermaid_copied()
                      : messages.markdown_copy_mermaid()
                  }
                  className="markdown-stream-control inline-flex size-3xl items-center justify-center rounded-sm text-markdown-text-tool-primary outline-none focus-visible:z-10 focus-visible:shadow-focus-gray-shadow-xs"
                  onClick={copyCode}
                  title={
                    copied
                      ? messages.markdown_copied()
                      : messages.markdown_copy_mermaid()
                  }
                  type="button"
                >
                  <CommaCopyStateIcon copied={copied} />
                </button>
              ) : null}
            </div>
          </figcaption>
        ) : null}
        {mode === "source" ? (
          <ScrollArea
            orientation="both"
            edgeEffect="none"
            viewportClassName="max-h-[420px]"
            contentStyle={{ minWidth: "100%" }}
          >
            <pre className="markdown-stream-code-source m-0 font-mono text-markdown-text-primary">
              <code>
                {animateFallback ? (
                  <CommaAnimatedText
                    content={code}
                    streamKey={`${String(indexKey ?? "mermaid")}:mermaid:source`}
                    streamState={ctx?.textStreamState}
                  />
                ) : (
                  code
                )}
              </code>
            </pre>
          </ScrollArea>
        ) : (
          <ScrollArea
            aria-busy={rendering || loading}
            className="markdown-stream-diagram-preview bg-markdown-bg-table"
            contentClassName="px-2xl py-xl"
            contentStyle={{ minWidth: "100%" }}
            edgeEffect="none"
            orientation="both"
          >
            {svg ? (
              <div
                className="markdown-stream-mermaid-svg"
                dangerouslySetInnerHTML={{ __html: svg }}
              />
            ) : canRenderPreview ? (
              <pre className="markdown-stream-code-preview-fallback m-0 whitespace-pre-wrap font-mono text-markdown-text-tool-primary">
                <code>
                  {animateFallback ? (
                    <CommaAnimatedText
                      content={code}
                      streamKey={`${String(indexKey ?? "mermaid")}:mermaid:preview`}
                      streamState={ctx?.textStreamState}
                    />
                  ) : (
                    code
                  )}
                </code>
              </pre>
            ) : null}
            {rendering ? (
              <div className="mt-3 text-xs leading-4 text-markdown-text-tool-primary">
                {messages.markdown_rendering_diagram()}
              </div>
            ) : null}
            {error && !svg ? (
              <div className="mt-lg rounded-xs bg-markdown-bg-inline-code px-md py-xs text-xs leading-4 text-markdown-text-tool-primary">
                {error}
              </div>
            ) : null}
          </ScrollArea>
        )}
      </figure>
    );
  },
  (previous, next) =>
    previous.animateFallback === next.animateFallback &&
    previous.code === next.code &&
    previous.config === next.config &&
    previous.deferPreview === next.deferPreview &&
    String(previous.indexKey ?? "") === String(next.indexKey ?? "") &&
    previous.loading === next.loading &&
    previous.ctx === next.ctx
);

function CommaCheckboxNode(props: CommaNodeProps<MarkdownNode>) {
  return (
    <input
      checked={Boolean(props.node.checked)}
      className="markdown-stream-checkbox mr-md size-xl align-[-2px]"
      disabled
      readOnly
      type="checkbox"
    />
  );
}

function CommaUnknownNode(props: CommaNodeProps<MarkdownNode>) {
  return <span>{asString(props.node.raw)}</span>;
}

function CommaEmphasisNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="em" />;
}

function CommaHighlightNode(props: CommaNodeProps<MarkdownNode>) {
  return (
    <CommaInlineChildrenNode
      {...props}
      as="mark"
      className="rounded-xxs bg-warning-100 px-xs"
    />
  );
}

function CommaInsertNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="ins" />;
}

function CommaStrikethroughNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="del" />;
}

function CommaStrongNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="strong" className="font-semibold" />;
}

function CommaSubscriptNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="sub" />;
}

function CommaSuperscriptNode(props: CommaNodeProps<MarkdownNode>) {
  return <CommaInlineChildrenNode {...props} as="sup" />;
}

function CommaInlineElementNode({ node }: CommaNodeProps<MarkdownNode>) {
  const inlineElements = useContext(MarkdownStreamInlineElementsContext);
  const key = markdownNodeAttribute(node, "data-key");
  return key ? (inlineElements.get(key) ?? null) : null;
}

function markdownNodeAttribute(node: MarkdownNode, name: string) {
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

const commaMarkdownComponents = {
  admonition: memoCommaNode(CommaAdmonitionNode),
  blockquote: memoCommaNode(CommaBlockquoteNode),
  checkbox: memoCommaNode(CommaCheckboxNode),
  checkbox_input: memoCommaNode(CommaCheckboxNode),
  code_block: memoCommaNode(CommaCodeBlockNode),
  "comma-inline": memoCommaNode(CommaInlineElementNode),
  d2: memoCommaNode(CommaCodeBlockNode),
  definition_list: memoCommaNode(CommaDefinitionListNode),
  emphasis: memoCommaNode(CommaEmphasisNode),
  emoji: memoCommaNode(CommaEmojiNode),
  footnote: memoCommaNode(CommaFootnoteNode),
  footnote_anchor: memoCommaNode(CommaFootnoteAnchorNode),
  footnote_reference: memoCommaNode(CommaFootnoteReferenceNode),
  hardbreak: memoCommaNode(CommaHardBreakNode),
  heading: memoCommaNode(CommaHeadingNode),
  highlight: memoCommaNode(CommaHighlightNode),
  image: memoCommaNode(CommaImageNode),
  html_block: memoCommaNode(CommaHtmlNode),
  html_inline: memoCommaNode(CommaHtmlNode),
  infographic: memoCommaNode(CommaCodeBlockNode),
  inline_code: memoCommaNode(CommaInlineCodeNode),
  insert: memoCommaNode(CommaInsertNode),
  link: memoCommaNode(CommaLinkNode),
  list: memoCommaNode(CommaListNode),
  list_item: memoCommaNode(CommaListItemNode),
  math_block: memoCommaNode(CommaMathBlockNode),
  math_inline: memoCommaNode(CommaMathInlineNode),
  mermaid: memoCommaNode(CommaMermaidNode),
  paragraph: memoCommaNode(CommaParagraphNode),
  reference: memoCommaNode(CommaReferenceNode),
  strikethrough: memoCommaNode(CommaStrikethroughNode),
  strong: memoCommaNode(CommaStrongNode),
  subscript: memoCommaNode(CommaSubscriptNode),
  superscript: memoCommaNode(CommaSuperscriptNode),
  table: memoCommaNode(CommaTableNode),
  text: memoCommaNode(CommaTextNode),
  text_special: memoCommaNode(CommaTextNode),
  thematic_break: memoCommaNode(CommaThematicBreakNode),
  unknown: memoCommaNode(CommaUnknownNode),
  vmr_container: memoCommaNode(CommaVmrContainerNode),
};

setCustomComponents(commaMarkdownComponents);

const getBlurStreamBatchSize = (backlog: number) => {
  if (backlog <= 0) return 0;
  return Math.min(28, Math.max(1, Math.ceil(backlog / 16)));
};

const useStreamContent = ({
  animation,
  blurAnimation,
  content,
  enabled,
  mode,
}: {
  animation: MarkdownStreamAnimation;
  blurAnimation: RequiredBlurAnimationOptions;
  content: string;
  enabled: boolean;
  mode: "queued" | "smooth";
}) => {
  const initialVisibleContent =
    enabled && animation === "blur" && mode === "queued" ? "" : content;
  const initialPlaybackComplete =
    initialVisibleContent === content || content.length === 0;
  const [visibleContent, setVisibleContent] = useState(initialVisibleContent);
  const [playbackComplete, setPlaybackComplete] = useState(initialPlaybackComplete);
  const playbackCompleteRef = useRef(initialPlaybackComplete);
  const blurAnimationRef = useRef(blurAnimation);
  blurAnimationRef.current = blurAnimation;
  const lastQueuedCharacterAtRef = useRef<number | null>(null);
  const visibleContentRef = useRef(initialVisibleContent);
  const targetContentRef = useRef(content);
  const schedulingModeRef = useRef(mode);
  const scheduledWorkRef = useRef<{
    id: number;
    type: "frame" | "timeout";
  } | null>(null);

  const commitPlaybackComplete = (nextPlaybackComplete: boolean) => {
    if (playbackCompleteRef.current === nextPlaybackComplete) return;
    playbackCompleteRef.current = nextPlaybackComplete;
    setPlaybackComplete(nextPlaybackComplete);
  };

  const cancelScheduledWork = () => {
    if (scheduledWorkRef.current === null) return;
    if (
      scheduledWorkRef.current.type === "frame" &&
      typeof window !== "undefined" &&
      window.cancelAnimationFrame
    ) {
      window.cancelAnimationFrame(scheduledWorkRef.current.id);
    } else {
      clearTimeout(scheduledWorkRef.current.id);
    }
    scheduledWorkRef.current = null;
  };

  const commitVisibleContent = (nextContent: string) => {
    const previousContent = visibleContentRef.current;
    if (
      nextContent.length > previousContent.length &&
      nextContent.startsWith(previousContent)
    ) {
      lastQueuedCharacterAtRef.current = Date.now();
    }
    visibleContentRef.current = nextContent;
    setVisibleContent(nextContent);
  };

  const getQueuedCharacterDelay = () => {
    const gapMs = blurAnimationRef.current.characterDelayMs;
    if (gapMs <= 0 || lastQueuedCharacterAtRef.current === null) return 0;
    return Math.max(0, gapMs - (Date.now() - lastQueuedCharacterAtRef.current));
  };

  const scheduleFrame = () => {
    if (scheduledWorkRef.current !== null) return;

    const runFrame = () => {
      scheduledWorkRef.current = null;

      const current = visibleContentRef.current;
      const target = targetContentRef.current;
      if (current === target) return;

      if (!target.startsWith(current)) {
        commitVisibleContent(target);
        return;
      }

      const backlog = target.length - current.length;
      const batchSize = getBlurStreamBatchSize(backlog);
      const nextContent = target.slice(0, current.length + batchSize);
      commitVisibleContent(nextContent);

      if (nextContent !== target) {
        scheduleFrame();
      }
    };

    if (typeof window !== "undefined" && window.requestAnimationFrame) {
      scheduledWorkRef.current = {
        id: window.requestAnimationFrame(runFrame),
        type: "frame",
      };
    } else {
      scheduledWorkRef.current = {
        id: setTimeout(runFrame, 16) as unknown as number,
        type: "timeout",
      };
    }
  };

  const scheduleQueuedCharacter = (delayMs: number) => {
    if (scheduledWorkRef.current !== null) return;

    scheduledWorkRef.current = {
      id: setTimeout(() => {
        scheduledWorkRef.current = null;

        const current = visibleContentRef.current;
        const target = targetContentRef.current;
        if (current === target) {
          commitPlaybackComplete(true);
          return;
        }

        if (!target.startsWith(current)) {
          lastQueuedCharacterAtRef.current = null;
          commitVisibleContent("");
          if (target.length > 0) {
            commitPlaybackComplete(false);
            scheduleQueuedCharacter(getQueuedCharacterDelay());
          } else {
            commitPlaybackComplete(true);
          }
          return;
        }

        const nextContent = target.slice(0, current.length + 1);
        commitVisibleContent(nextContent);

        if (nextContent !== target) {
          scheduleQueuedCharacter(blurAnimationRef.current.characterDelayMs);
        } else {
          commitPlaybackComplete(true);
        }
      }, delayMs) as unknown as number,
      type: "timeout",
    };
  };

  useEffect(() => cancelScheduledWork, []);

  const playbackActive = enabled && animation === "blur";

  useEffect(() => {
    if (!playbackActive) {
      // Fast path: the returned content is derived directly from the prop, so
      // only refs need to track it — writing state here would schedule a
      // second (wasted) render for every stream chunk while disabled.
      cancelScheduledWork();
      targetContentRef.current = content;
      lastQueuedCharacterAtRef.current = null;
      visibleContentRef.current = content;
      commitPlaybackComplete(true);
      return;
    }

    if (schedulingModeRef.current !== mode) {
      cancelScheduledWork();
      schedulingModeRef.current = mode;
    }

    // Re-align state with the ref timeline after a disabled stretch (during
    // which state was intentionally left stale).
    if (visibleContentRef.current !== visibleContent) {
      setVisibleContent(visibleContentRef.current);
    }

    const visibleContentValue = visibleContentRef.current;
    targetContentRef.current = content;

    if (mode === "queued") {
      if (!content.startsWith(visibleContentValue)) {
        cancelScheduledWork();
        lastQueuedCharacterAtRef.current = null;
        commitVisibleContent("");
      }
      if (visibleContentRef.current !== content) {
        commitPlaybackComplete(false);
        scheduleQueuedCharacter(getQueuedCharacterDelay());
      } else {
        commitPlaybackComplete(true);
      }
      return;
    }

    if (!content.startsWith(visibleContentValue)) {
      cancelScheduledWork();
      lastQueuedCharacterAtRef.current = null;
      commitVisibleContent(content);
      commitPlaybackComplete(true);
      return;
    }

    commitPlaybackComplete(true);
    scheduleFrame();
    // Scheduling helpers use refs for current target/visible content. Listing
    // them as deps would recreate stream work on every state tick.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [animation, content, enabled, mode]);

  // While playback is inactive the state machine is bypassed entirely: the
  // output derives straight from the prop so a content change costs one
  // render instead of a stale render plus an effect-driven second one.
  return {
    playbackComplete: playbackActive ? playbackComplete : true,
    visibleContent: playbackActive ? visibleContent : content,
  };
};

const useCompleteBlurTextPlayback = ({
  blurAnimation,
  content,
  enabled,
}: {
  blurAnimation: RequiredBlurAnimationOptions;
  content: string;
  enabled: boolean;
}) => {
  const initialPlaybackComplete = !enabled || content.length === 0;
  const [visibleTextCharacters, setVisibleTextCharacters] = useState(0);
  const [playbackComplete, setPlaybackComplete] = useState(initialPlaybackComplete);
  const activeRef = useRef(false);
  const animatedTextBoundaryRef = useRef(0);
  const blurAnimationRef = useRef(blurAnimation);
  blurAnimationRef.current = blurAnimation;
  const contentRef = useRef(content);
  const lastVisibleCharacterAtRef = useRef<number | null>(null);
  const playbackCompleteRef = useRef(initialPlaybackComplete);
  const playbackGenerationRef = useRef(0);
  const targetTextCharactersRef = useRef(0);
  const textOffsetRef = useRef(0);
  const visibleTextCharactersRef = useRef(0);
  const scheduledWorkRef = useRef<{
    generation: number;
    id: number;
    type: "advance" | "complete";
  } | null>(null);

  const cancelScheduledWork = () => {
    if (scheduledWorkRef.current === null) return;
    clearTimeout(scheduledWorkRef.current.id);
    scheduledWorkRef.current = null;
  };

  const commitPlaybackComplete = (nextPlaybackComplete: boolean) => {
    if (playbackCompleteRef.current === nextPlaybackComplete) return;
    playbackCompleteRef.current = nextPlaybackComplete;
    setPlaybackComplete(nextPlaybackComplete);
  };

  const commitVisibleTextCharacters = (nextVisibleTextCharacters: number) => {
    const previousVisibleTextCharacters = visibleTextCharactersRef.current;
    if (previousVisibleTextCharacters === nextVisibleTextCharacters) return;
    visibleTextCharactersRef.current = nextVisibleTextCharacters;
    setVisibleTextCharacters(nextVisibleTextCharacters);
  };

  const getVisibleCharacterDelay = () => {
    const gapMs = blurAnimationRef.current.characterDelayMs;
    if (gapMs <= 0 || lastVisibleCharacterAtRef.current === null) return 0;
    const remainingMs = Math.max(
      0,
      gapMs - (Date.now() - lastVisibleCharacterAtRef.current)
    );
    if (remainingMs === 0) return 0;
    return gapMs < minBatchedCharacterFrameMs
      ? minBatchedCharacterFrameMs
      : remainingMs;
  };

  const scheduleCompletion = () => {
    if (scheduledWorkRef.current !== null) return;
    const generation = playbackGenerationRef.current;
    scheduledWorkRef.current = {
      id: setTimeout(() => {
        if (playbackGenerationRef.current !== generation) return;
        scheduledWorkRef.current = null;
        commitPlaybackComplete(true);
      }, blurAnimationRef.current.durationMs) as unknown as number,
      generation,
      type: "complete",
    };
  };

  const advanceVisibleCharacters = () => {
    const targetTextCharacters = targetTextCharactersRef.current;
    if (visibleTextCharactersRef.current < targetTextCharacters) {
      const gapMs = blurAnimationRef.current.characterDelayMs;
      const backlog = targetTextCharacters - visibleTextCharactersRef.current;
      const now = Date.now();
      const previousStartedAt = lastVisibleCharacterAtRef.current;
      const elapsedMs =
        previousStartedAt === null ? 0 : Math.max(0, now - previousStartedAt);
      const timedCharacters =
        gapMs <= 0
          ? backlog
          : previousStartedAt === null
            ? 1
            : Math.max(1, Math.floor(elapsedMs / gapMs));
      const catchUpCharacters =
        gapMs > 0 &&
        gapMs < minBatchedCharacterFrameMs &&
        previousStartedAt !== null &&
        backlog > blurAnimationRef.current.activeCharacters
          ? Math.min(
              maxCatchUpCharactersPerFrame,
              Math.ceil((backlog - blurAnimationRef.current.activeCharacters) / 8)
            )
          : 0;
      const dueCharacters = Math.max(timedCharacters, catchUpCharacters);
      const nextVisibleTextCharacters = Math.min(
        targetTextCharacters,
        visibleTextCharactersRef.current + dueCharacters
      );

      if (gapMs <= 0) {
        lastVisibleCharacterAtRef.current = now;
      } else if (previousStartedAt === null) {
        lastVisibleCharacterAtRef.current = now;
      } else {
        lastVisibleCharacterAtRef.current = previousStartedAt + dueCharacters * gapMs;
      }

      commitVisibleTextCharacters(nextVisibleTextCharacters);
      if (nextVisibleTextCharacters < targetTextCharacters) {
        scheduleAdvance(getVisibleCharacterDelay());
      } else {
        scheduleCompletion();
      }
      return;
    }
    scheduleCompletion();
  };

  const scheduleAdvance = (delayMs: number) => {
    if (scheduledWorkRef.current?.type === "complete") {
      cancelScheduledWork();
    }
    if (scheduledWorkRef.current !== null) return;

    if (delayMs <= 0) {
      advanceVisibleCharacters();
      return;
    }

    const generation = playbackGenerationRef.current;
    scheduledWorkRef.current = {
      id: setTimeout(() => {
        if (playbackGenerationRef.current !== generation) return;
        scheduledWorkRef.current = null;
        advanceVisibleCharacters();
      }, delayMs) as unknown as number,
      generation,
      type: "advance",
    };
  };

  useLayoutEffect(() => cancelScheduledWork, []);

  useLayoutEffect(() => {
    if (!enabled || !activeRef.current) {
      cancelScheduledWork();
      playbackGenerationRef.current += 1;
      targetTextCharactersRef.current = 0;
      lastVisibleCharacterAtRef.current = null;
      commitVisibleTextCharacters(0);
      animatedTextBoundaryRef.current = 0;
      commitPlaybackComplete(true);
      contentRef.current = content;
      return;
    }

    const targetTextCharacters = textOffsetRef.current;
    const previousContent = contentRef.current;
    const contentChanged = previousContent !== content;
    const contentReplaced = contentChanged && !content.startsWith(previousContent);
    contentRef.current = content;
    targetTextCharactersRef.current = targetTextCharacters;

    if (contentReplaced) {
      cancelScheduledWork();
      playbackGenerationRef.current += 1;
      // A non-prefix update is a replacement, not another streamed suffix.
      // Keep the previously committed tree readable until this layout commit,
      // then present the replacement atomically instead of replaying it from
      // one character and producing a near-empty painted frame.
      animatedTextBoundaryRef.current = targetTextCharacters;
      lastVisibleCharacterAtRef.current = null;
      commitVisibleTextCharacters(targetTextCharacters);
      commitPlaybackComplete(true);
      return;
    }

    if (visibleTextCharactersRef.current > targetTextCharacters) {
      cancelScheduledWork();
      animatedTextBoundaryRef.current = Math.min(
        animatedTextBoundaryRef.current,
        targetTextCharacters
      );
      commitVisibleTextCharacters(targetTextCharacters);
      commitPlaybackComplete(true);
      return;
    }

    animatedTextBoundaryRef.current = Math.max(
      animatedTextBoundaryRef.current,
      visibleTextCharactersRef.current
    );

    if (visibleTextCharactersRef.current < targetTextCharacters) {
      commitPlaybackComplete(false);
      if (scheduledWorkRef.current?.type === "complete") {
        cancelScheduledWork();
      }
      if (scheduledWorkRef.current !== null) return;
      scheduleAdvance(getVisibleCharacterDelay());
      return;
    }

    if (targetTextCharacters === 0) {
      cancelScheduledWork();
      animatedTextBoundaryRef.current = 0;
      commitPlaybackComplete(true);
      return;
    }

    if (!playbackCompleteRef.current) {
      scheduleCompletion();
    }
  });

  const prepareRender = (active: boolean) => {
    activeRef.current = active;
    if (active) {
      textOffsetRef.current = 0;
    }
  };

  const pendingContentChange =
    enabled && content.length > 0 && contentRef.current !== content;

  return {
    animatedTextBoundaryRef,
    playbackComplete: playbackComplete && !pendingContentChange,
    prepareRender,
    targetTextCharacters: targetTextCharactersRef.current,
    textOffsetRef,
    visibleTextCharacters,
  };
};

export const MarkdownStream = ({
  content = "",
  nodes,
  final = false,
  streamId,
  className,
  blockPresentation = "document",
  animation: animationOption,
  ensureBlurAnimation = false,
  showCursor = false,
  smoothStreaming = "auto",
  showCodeBlockHeader = true,
  showCodeBlockCopy = true,
  maxAnimatedCharacters = 220,
  blurAnimation: blurAnimationOptions,
  renderCodeBlockHeader,
  onCopyCode,
  clipboard,
  inlineElements,
  documentResourcePolicy,
  htmlPolicy = "escape",
  isDark = false,
  ...props
}: MarkdownStreamProps) => {
  // High-frequency streamed output is immediately readable. Blur playback is
  // retained only when a caller explicitly requests it.
  const animation = animationOption ?? (ensureBlurAnimation ? "blur" : "none");
  const generatedId = useId().replace(/:/g, "");
  const customId = streamId ?? `comma-markdown-stream-${generatedId}`;
  // Normalize so an empty Map (or a caller re-creating equivalent empty Maps)
  // behaves exactly like "no inline elements": the parse pipeline and the
  // element context must not churn when a message carries no elements.
  const normalizedInlineElements =
    inlineElements !== undefined && inlineElements.size > 0
      ? inlineElements
      : emptyInlineElements;
  const hasInlineElements = normalizedInlineElements !== emptyInlineElements;
  const customHtmlTags = useMemo(() => {
    const tags = props.customHtmlTags;
    const parseTags = props.parseOptions?.customHtmlTags;
    if (!hasInlineElements && !parseTags?.length) return tags;
    return Array.from(
      new Set([
        ...(tags ?? []),
        ...(parseTags ?? []),
        ...(hasInlineElements ? ["comma-inline"] : []),
      ])
    );
  }, [hasInlineElements, props.customHtmlTags, props.parseOptions?.customHtmlTags]);
  const blurAnimation = useMemo(
    () => normalizeBlurAnimation(blurAnimationOptions),
    [blurAnimationOptions]
  );
  const completeBlurEnabled =
    nodes === undefined && animation === "blur" && ensureBlurAnimation;
  const shouldSmoothStreamContent = smoothStreaming === true && !completeBlurEnabled;
  const streamContent = useStreamContent({
    animation,
    blurAnimation,
    content,
    enabled: nodes === undefined && shouldSmoothStreamContent && !final,
    mode: "smooth",
  });
  const rendererContent = completeBlurEnabled ? content : streamContent.visibleContent;
  const completeBlurPlayback = useCompleteBlurTextPlayback({
    blurAnimation,
    content: rendererContent,
    enabled: completeBlurEnabled,
  });
  const completeBlurTextReached =
    rendererContent.length === 0 ||
    (completeBlurPlayback.targetTextCharacters > 0 &&
      completeBlurPlayback.visibleTextCharacters >=
        completeBlurPlayback.targetTextCharacters);
  const renderFinal =
    final &&
    (!completeBlurEnabled ||
      (rendererContent === content &&
        (completeBlurPlayback.playbackComplete || completeBlurTextReached)));
  const completeBlurTextQueue =
    completeBlurEnabled && !renderFinal
      ? (() => {
          const maxActiveCharacters = Math.max(
            1,
            Math.min(maxAnimatedCharacters, blurAnimation.activeCharacters)
          );
          return {
            activeTextStart: Math.max(
              0,
              completeBlurPlayback.visibleTextCharacters - maxActiveCharacters
            ),
            animatedTextBoundaryRef: completeBlurPlayback.animatedTextBoundaryRef,
            textOffsetsByStreamKey: new Map(),
            textOffsetRef: completeBlurPlayback.textOffsetRef,
            visibleTextCharacters: completeBlurPlayback.visibleTextCharacters,
          };
        })()
      : undefined;
  completeBlurPlayback.prepareRender(Boolean(completeBlurTextQueue));
  const completeBlurLiveTextOffsetRef = useRef(0);
  const animationInputVersionRef = useRef(0);
  const animationInputRef = useRef<{
    content: string;
    final: boolean;
    nodes: NodeRendererProps["nodes"] | undefined;
  } | null>(null);
  const previousAnimationInput = animationInputRef.current;
  if (
    !previousAnimationInput ||
    previousAnimationInput.content !== rendererContent ||
    previousAnimationInput.final !== renderFinal ||
    previousAnimationInput.nodes !== nodes
  ) {
    animationInputVersionRef.current += 1;
    animationInputRef.current = {
      content: rendererContent,
      final: renderFinal,
      nodes,
    };
  }
  const animationInputVersion = animationInputVersionRef.current;
  const stableCompleteBlurTextBoundary = completeBlurTextQueue?.activeTextStart;
  const usePartitionedRenderer = nodes === undefined;
  const partitionedNodes = usePartitionedMarkdownNodes({
    content: rendererContent,
    customHtmlTags,
    customId,
    customMarkdownIt: props.customMarkdownIt,
    enabled: usePartitionedRenderer,
    final: renderFinal,
    parseOptions: props.parseOptions,
    stableTextBoundary: stableCompleteBlurTextBoundary,
  });
  const textReveal = useMemo(
    () => (animation === "reveal" ? createTextReveal(maxAnimatedCharacters) : null),
    // The painter belongs to this document/parser lifetime, even when the next
    // document happens to use the same presentation options.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [animation, customId, maxAnimatedCharacters, partitionedNodes.renderEpoch]
  );
  useLayoutEffect(() => () => textReveal?.flush(), [textReveal]);
  useLayoutEffect(() => {
    if (renderFinal) textReveal?.flush();
  }, [renderFinal, textReveal]);
  const revealRootKeys = useMemo(
    () =>
      textReveal
        ? (nodes ?? partitionedNodes.nodes).map((_, index) => `root:${index}`)
        : [],
    // Match DocumentSlot's root index within the same document lifetime. Source
    // offsets belong to parsing; switching an equivalent tree's input format
    // must not give already displayed words a second presentation identity.
    [nodes, partitionedNodes.nodes, textReveal]
  );
  useLayoutEffect(() => {
    textReveal?.retainRoots(new Set(revealRootKeys));
  }, [textReveal, revealRootKeys]);
  if (completeBlurTextQueue && usePartitionedRenderer) {
    completeBlurPlayback.textOffsetRef.current = partitionedNodes.totalTextCharacters;
    completeBlurLiveTextOffsetRef.current = partitionedNodes.stableTextCharacters;
  }
  const liveCompleteBlurTextQueue = useMemo(
    () =>
      completeBlurTextQueue && usePartitionedRenderer
        ? {
            ...completeBlurTextQueue,
            textOffsetRef: completeBlurLiveTextOffsetRef,
          }
        : completeBlurTextQueue,
    [completeBlurTextQueue, usePartitionedRenderer]
  );
  const contextValue = useMemo<MarkdownStreamContextValue>(
    () => ({
      animation,
      blurAnimation,
      completeBlurTextQueue: liveCompleteBlurTextQueue,
      ensureBlurAnimation,
      final: renderFinal,
      isDark,
      maxAnimatedCharacters,
      showCodeBlockHeader,
      showCodeBlockCopy,
      settled: false,
      renderCodeBlockHeader,
      onCopyCode,
      clipboard,
    }),
    [
      animation,
      blurAnimation,
      liveCompleteBlurTextQueue,
      ensureBlurAnimation,
      isDark,
      renderFinal,
      maxAnimatedCharacters,
      showCodeBlockHeader,
      showCodeBlockCopy,
      renderCodeBlockHeader,
      onCopyCode,
      clipboard,
    ]
  );
  const settledContextValue = useMemo<MarkdownStreamContextValue>(
    () => ({
      animation,
      blurAnimation,
      completeBlurTextQueue: undefined,
      ensureBlurAnimation,
      final: renderFinal,
      isDark,
      maxAnimatedCharacters,
      showCodeBlockHeader,
      showCodeBlockCopy,
      settled: true,
      renderCodeBlockHeader,
      onCopyCode,
      clipboard,
    }),
    [
      animation,
      blurAnimation,
      ensureBlurAnimation,
      isDark,
      renderFinal,
      maxAnimatedCharacters,
      showCodeBlockHeader,
      showCodeBlockCopy,
      renderCodeBlockHeader,
      onCopyCode,
      clipboard,
    ]
  );
  const renderRoot = useCallback(
    (element: ReactNode, index: number) => {
      const settled = usePartitionedRenderer && index < partitionedNodes.stableCount;
      const renderedRoot = (
        <MarkdownStreamContext.Provider
          value={settled ? settledContextValue : contextValue}
        >
          <MarkdownStreamAnimationVersionContext.Provider
            value={settled ? 0 : animationInputVersion}
          >
            {element}
          </MarkdownStreamAnimationVersionContext.Provider>
        </MarkdownStreamContext.Provider>
      );
      if (!textReveal) return renderedRoot;
      return (
        <CommaTextRevealRoot rootKey={revealRootKeys[index]!}>
          {renderedRoot}
        </CommaTextRevealRoot>
      );
    },
    [
      usePartitionedRenderer,
      partitionedNodes.stableCount,
      revealRootKeys,
      settledContextValue,
      contextValue,
      animationInputVersion,
      textReveal,
    ]
  );

  const rootStyle = {
    "--markdown-stream-char-blur": `${blurAnimation.blurRadiusPx}px`,
    "--markdown-stream-char-duration": `${blurAnimation.durationMs}ms`,
    "--markdown-stream-char-start-opacity": blurAnimation.initialOpacity,
    "--markdown-stream-char-translate-y": `${blurAnimation.translateYEm}em`,
  } as CSSProperties;
  const rootRef = useRef<HTMLDivElement>(null);
  const activeBlurRoot = animation === "blur" && !renderFinal;

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root || !activeBlurRoot) return undefined;

    root.addEventListener("animationcancel", clearCompleteBlurAnimationClass);
    root.addEventListener("animationend", clearCompleteBlurAnimationClass);
    return () => {
      root.removeEventListener("animationcancel", clearCompleteBlurAnimationClass);
      root.removeEventListener("animationend", clearCompleteBlurAnimationClass);
    };
  }, [activeBlurRoot]);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root || !activeBlurRoot) return undefined;

    const reducedMotionQuery = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    let reducedMotionObserver: MutationObserver | undefined;
    let reducedMotionActive = false;
    const updateReducedMotion = () => {
      const matches =
        Boolean(reducedMotionQuery?.matches) ||
        document.documentElement.getAttribute("data-comma-reduced-motion") === "true";
      if (reducedMotionActive) {
        clearCompleteBlurAnimationClasses(root);
      }
      reducedMotionObserver?.disconnect();
      reducedMotionObserver = undefined;
      reducedMotionActive = matches;
      if (!matches) return;

      clearCompleteBlurAnimationClasses(root);
      if (typeof MutationObserver !== "undefined") {
        reducedMotionObserver = new MutationObserver((records) => {
          records.forEach((record) => {
            if (record.type === "attributes") {
              clearCompleteBlurAnimationClassOnNode(record.target);
              return;
            }
            record.addedNodes.forEach(clearCompleteBlurAnimationClassesInNode);
          });
        });
        reducedMotionObserver.observe(root, {
          attributeFilter: ["class"],
          attributes: true,
          childList: true,
          subtree: true,
        });
      }
    };
    const handleReducedMotionChange = () => {
      updateReducedMotion();
    };
    if (reducedMotionQuery) {
      reducedMotionQuery.addEventListener("change", handleReducedMotionChange);
    }
    const manualReducedMotionObserver =
      typeof MutationObserver === "undefined"
        ? undefined
        : new MutationObserver(updateReducedMotion);
    manualReducedMotionObserver?.observe(document.documentElement, {
      attributeFilter: ["data-comma-reduced-motion"],
      attributes: true,
    });
    updateReducedMotion();

    return () => {
      if (reducedMotionActive) {
        clearCompleteBlurAnimationClasses(root);
      }
      reducedMotionObserver?.disconnect();
      manualReducedMotionObserver?.disconnect();
      reducedMotionQuery?.removeEventListener("change", handleReducedMotionChange);
    };
  }, [activeBlurRoot]);

  return (
    <MarkdownDocumentResourceContext.Provider value={documentResourcePolicy}>
      <MarkdownStreamInlineElementsContext.Provider value={normalizedInlineElements}>
        <MarkdownStreamContext.Provider value={contextValue}>
          <MarkdownStreamAnimationVersionContext.Provider value={animationInputVersion}>
            <div
              className={cx(
                "markdown-stream text-markdown-text-primary",
                blockPresentation === "bubbles" && "markdown-stream--bubbles",
                className
              )}
              ref={rootRef}
              style={rootStyle}
            >
              <MarkdownStreamTextRevealContext.Provider value={textReveal}>
                {textReveal && !renderFinal ? <style>{textReveal.css}</style> : null}
                <MarkdownDocumentRenderer
                  {...props}
                  blockPresentation={blockPresentation}
                  {...(customHtmlTags ? { customHtmlTags } : {})}
                  customId={customId}
                  fade={false}
                  final={renderFinal}
                  htmlPolicy={htmlPolicy}
                  indexKey={partitionedNodes.renderEpoch}
                  isDark={isDark}
                  liveRootStart={
                    usePartitionedRenderer ? partitionedNodes.stableCount : 0
                  }
                  nodes={nodes ?? partitionedNodes.nodes}
                  renderCodeBlocksAsPre
                  sourceMode={usePartitionedRenderer ? "content" : "nodes"}
                  typewriter={showCursor}
                  wrapRoot={renderRoot}
                />
              </MarkdownStreamTextRevealContext.Provider>
            </div>
          </MarkdownStreamAnimationVersionContext.Provider>
        </MarkdownStreamContext.Provider>
      </MarkdownStreamInlineElementsContext.Provider>
    </MarkdownDocumentResourceContext.Provider>
  );
};
