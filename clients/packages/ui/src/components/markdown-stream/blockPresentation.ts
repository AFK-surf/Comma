import type { BaseNode } from "stream-markdown-parser";

export type MarkdownBlockPresentation = "document" | "bubbles";

export interface MarkdownPresentationSlot {
  rootIndices: number[];
  /** Undefined leaves the ordinary document presentation unchanged. */
  kind?: string;
}

const proseRoots = new Set([
  "paragraph",
  "heading",
  "blockquote",
  "list",
  "definition_list",
  "footnote",
]);
const standaloneBlocks = new Set([
  "code_block",
  "table",
  "math_block",
  "mermaid",
  "d2",
  "infographic",
  "html_block",
  "admonition",
  "vmr_container",
  "image",
]);

/**
 * Presentation only: keep the complete parsed document and its original root
 * indices. A nested special block keeps its list/quote together so numbering,
 * indentation, and citation context survive the bubble boundary.
 */
export function markdownPresentationSlots(
  nodes: readonly BaseNode[],
  presentation: MarkdownBlockPresentation
): MarkdownPresentationSlot[] {
  if (presentation === "document") {
    return nodes.map((_, index) => ({ rootIndices: [index] }));
  }

  const slots: MarkdownPresentationSlot[] = [];
  let startsGroup = true;
  nodes.forEach((node, index) => {
    if (node.type === "thematic_break") {
      startsGroup = true;
      return;
    }
    const prose = proseRoots.has(node.type) && !containsStandaloneBlock(node);
    const previous = slots.at(-1);
    if (!startsGroup && prose && previous?.kind === "prose") {
      previous.rootIndices.push(index);
    } else {
      slots.push({ rootIndices: [index], kind: prose ? "prose" : node.type });
    }
    startsGroup = false;
  });
  return slots;
}

function containsStandaloneBlock(node: BaseNode): boolean {
  if (standaloneBlocks.has(node.type)) return true;
  // These are the parser's structural child fields, not arbitrary custom data.
  const record = node as BaseNode & Record<string, unknown>;
  for (const field of ["children", "items", "rows", "cells", "header"]) {
    const value = record[field];
    const children = Array.isArray(value) ? value : [value];
    for (const child of children) {
      if (
        child &&
        typeof child === "object" &&
        "type" in child &&
        typeof child.type === "string" &&
        containsStandaloneBlock(child as BaseNode)
      ) {
        return true;
      }
    }
  }
  return false;
}
