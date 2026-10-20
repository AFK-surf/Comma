// A document authored as ordered parts: Markdown text that runs on as one document (paragraph boundaries are the
// text's own blank lines), and application-owned elements between the texts, each in its own place (`element-<n>`,
// `n` the part's index in base 36). The parts become the fragments `documentNodes` parses, and the text a renderer
// shows when it parses the document itself.
import {
  documentNodes,
  type MarkdownDocumentFragment,
  type MarkdownDocumentNodes,
} from "./document.ts";

const RESERVED_INLINE_TAG = /<(?=\/?comma-inline(?:[\s/>]))/gi;
const INLINE_SENTINEL = "\u0000";
const INLINE_SENTINEL_PATTERN = new RegExp(
  `${INLINE_SENTINEL}([0-9a-z]+)${INLINE_SENTINEL}`,
  "g"
);

export type PartsDocument = {
  /** The document as Markdown, an element as its `<comma-inline>` tag. */
  content: string;
  fragments: MarkdownDocumentFragment[];
  /** The elements the document kept (one a sanitizer dropped is not), by key: the index of their part. */
  elements: Map<string, number>;
};

/** The key of the element part at `index`. */
export const elementKey = (index: number) => `element-${index.toString(36)}`;

export function partsDocument<Part>(
  parts: readonly Part[],
  options: {
    markdownText: (part: Part) => string | undefined;
    isBlock?: (part: Part) => boolean;
    sanitizeMarkdown?: (markdown: string) => string;
  }
): PartsDocument {
  const replacements = new Map<
    string,
    { key: string; block: boolean; index: number }
  >();
  let source = "";
  parts.forEach((part, index) => {
    const markdown = options.markdownText(part);
    if (markdown !== undefined) {
      source += escapeInlineSentinels(markdown);
      return;
    }
    const sentinel = `${INLINE_SENTINEL}${index.toString(36)}${INLINE_SENTINEL}`;
    replacements.set(sentinel, {
      key: elementKey(index),
      block: options.isBlock?.(part) ?? false,
      index,
    });
    source += sentinel;
  });
  source = options.sanitizeMarkdown?.(source) ?? source;

  const fragments: MarkdownDocumentFragment[] = [];
  const elements = new Map<string, number>();
  let content = "";
  let offset = 0;
  for (const match of source.matchAll(INLINE_SENTINEL_PATTERN)) {
    const markdown = escapeReservedInlineTags(source.slice(offset, match.index));
    appendMarkdownFragment(fragments, markdown);
    content += markdown;
    const replacement = replacements.get(match[0]);
    if (replacement) {
      fragments.push({
        key: replacement.key,
        type: replacement.block ? "block" : "inline",
      });
      content += `<comma-inline data-key="${replacement.key}"></comma-inline>`;
      elements.set(replacement.key, replacement.index);
    }
    offset = match.index + match[0].length;
  }
  const trailing = escapeReservedInlineTags(source.slice(offset));
  appendMarkdownFragment(fragments, trailing);
  content += trailing;
  return { content, fragments, elements };
}

/** The parsed document of `parts`. */
export function partsDocumentNodes(document: PartsDocument): MarkdownDocumentNodes {
  return documentNodes(document.fragments);
}

/** Text that cannot open or close an application element's tag. */
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

function appendMarkdownFragment(fragments: MarkdownDocumentFragment[], text: string) {
  if (!text) return;
  const previous = fragments.at(-1);
  if (previous?.type === "markdown") {
    previous.text += text;
    return;
  }
  fragments.push({ text, type: "markdown" });
}

function escapeInlineSentinels(text: string) {
  return text.replaceAll(INLINE_SENTINEL, "�");
}
