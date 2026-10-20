import type { ReactNode } from "react";
import { partsDocument, partsDocumentNodes } from "@comma/core/markdown";
import type {
  MarkdownStreamInlineElements,
  MarkdownStreamNodes,
} from "@comma/ui/components/markdown-stream";

export { escapeReservedInlineTags } from "@comma/core/markdown";

export type CompiledTrustedInlineDocument = {
  content: string;
  inlineElements: MarkdownStreamInlineElements;
  nodes: MarkdownStreamNodes;
};

/**
 * Compiles ordered trusted parts into one Markdown document with typed inline
 * elements spliced in (the core's `partsDocument`): the parts are a single
 * running document, and each element part is drawn by `renderInline`.
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
  const document = partsDocument(parts, options);
  const inlineElements = new Map<string, ReactNode>();
  for (const [key, index] of document.elements)
    inlineElements.set(key, options.renderInline(parts[index]!, index));
  return {
    content: document.content,
    inlineElements,
    nodes: partsDocumentNodes(document),
  };
}
