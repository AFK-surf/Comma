import type { ReactNode } from "react";
import {
  createMarkdownStreamDocumentNodes,
  type MarkdownStreamDocumentFragment,
  type MarkdownStreamInlineElements,
  type MarkdownStreamNodes,
} from "@comma/ui";

const RESERVED_INLINE_TAG = /<(?=\/?comma-inline(?:[\s/>]))/gi;
const INLINE_SENTINEL = "\u0000";
const INLINE_SENTINEL_PATTERN = new RegExp(
  `${INLINE_SENTINEL}([0-9a-z]+)${INLINE_SENTINEL}`,
  "g"
);

type InlineReplacement = {
  key: string;
  markup: string;
  block: boolean;
};

export type CompiledTrustedInlineDocument = {
  content: string;
  inlineElements: MarkdownStreamInlineElements;
  nodes: MarkdownStreamNodes;
};

/**
 * Compiles ordered trusted parts into one Markdown document with typed inline
 * elements spliced in. The parts are a single running document: markdown text
 * concatenates, and paragraph boundaries are Markdown's own — a blank line
 * inside the text. Chat messages and the briefing summary both author that
 * way (the recommendation catalog pins it for the briefing), so structure
 * lives in the text and never in how the author happened to chunk the parts.
 */
export function compileTrustedInlineDocument<Part>(
  parts: readonly Part[],
  options: {
    markdownText: (part: Part) => string | undefined;
    renderInline: (part: Part, index: number) => ReactNode;
    isBlock?: (part: Part) => boolean;
    sanitizeMarkdown?: (markdown: string) => string;
  }
): CompiledTrustedInlineDocument {
  const candidateInlineElements = new Map<string, ReactNode>();
  const replacements = new Map<string, InlineReplacement>();
  let source = "";

  parts.forEach((part, index) => {
    const markdown = options.markdownText(part);
    if (markdown !== undefined) {
      source += escapeInlineSentinels(markdown);
      return;
    }

    const key = `element-${index.toString(36)}`;
    const sentinel = inlineSentinel(index);
    candidateInlineElements.set(key, options.renderInline(part, index));
    replacements.set(sentinel, {
      key,
      block: options.isBlock?.(part) ?? false,
      markup: `<comma-inline data-key="${key}"></comma-inline>`,
    });
    source += sentinel;
  });

  const sanitizedSource = options.sanitizeMarkdown?.(source) ?? source;
  const compiled = compileSanitizedSource(
    sanitizedSource,
    replacements,
    candidateInlineElements
  );

  return {
    content: compiled.content,
    inlineElements: compiled.inlineElements,
    nodes: createMarkdownStreamDocumentNodes(compiled.fragments),
  };
}

export function escapeReservedInlineTags(text: string) {
  const escaped = text.replace(RESERVED_INLINE_TAG, "&lt;");
  const danglingTagStart = escaped.lastIndexOf("<");
  if (danglingTagStart <= escaped.lastIndexOf(">")) return escaped;
  const possibleReservedTag = escaped.slice(danglingTagStart + 1).toLowerCase();
  if (
    possibleReservedTag.length === 0 ||
    !["comma-inline", "/comma-inline"].some((tag) =>
      tag.startsWith(possibleReservedTag)
    )
  ) {
    return escaped;
  }
  return `${escaped.slice(0, danglingTagStart)}&lt;${escaped.slice(danglingTagStart + 1)}`;
}

function compileSanitizedSource(
  source: string,
  replacements: ReadonlyMap<string, InlineReplacement>,
  candidateInlineElements: ReadonlyMap<string, ReactNode>
) {
  const fragments: MarkdownStreamDocumentFragment[] = [];
  const inlineElements = new Map<string, ReactNode>();
  let content = "";
  let offset = 0;

  for (const match of source.matchAll(INLINE_SENTINEL_PATTERN)) {
    const index = match.index;
    const markdown = escapeReservedInlineTags(source.slice(offset, index));
    appendMarkdownFragment(fragments, markdown);
    content += markdown;

    const replacement = replacements.get(match[0]);
    if (replacement) {
      fragments.push({
        key: replacement.key,
        type: replacement.block ? "block" : "inline",
      });
      content += replacement.markup;
      if (candidateInlineElements.has(replacement.key)) {
        inlineElements.set(
          replacement.key,
          candidateInlineElements.get(replacement.key)
        );
      }
    }
    offset = index + match[0].length;
  }

  const trailingMarkdown = escapeReservedInlineTags(source.slice(offset));
  appendMarkdownFragment(fragments, trailingMarkdown);
  content += trailingMarkdown;
  return { content, fragments, inlineElements };
}

function appendMarkdownFragment(
  fragments: MarkdownStreamDocumentFragment[],
  text: string
) {
  if (!text) return;
  const previous = fragments.at(-1);
  if (previous?.type === "markdown") {
    previous.text += text;
    return;
  }
  fragments.push({ text, type: "markdown" });
}

function inlineSentinel(index: number) {
  return `${INLINE_SENTINEL}${index.toString(36)}${INLINE_SENTINEL}`;
}

function escapeInlineSentinels(text: string) {
  return text.replaceAll(INLINE_SENTINEL, "�");
}
