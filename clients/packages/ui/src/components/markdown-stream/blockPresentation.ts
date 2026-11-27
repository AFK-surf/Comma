import type { BaseNode } from "stream-markdown-parser";

export type MarkdownBlockPresentation = "document" | "bubbles";

export interface MarkdownPresentationSlot {
  rootIndices: number[];
  /** Undefined leaves the ordinary document presentation unchanged. */
  kind?: string;
}

export interface MarkdownPresentationOptions {
  /** True when the host renders relative document pictures via `renderPicture`. */
  hasPictureRenderer?: boolean;
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

function isSafeImageHref(href: unknown): boolean {
  if (typeof href !== "string") return false;
  const value = href.trim();
  if (!value) return false;
  if (
    value.startsWith("#") ||
    value.startsWith("/") ||
    value.startsWith("./") ||
    value.startsWith("../")
  ) {
    return true;
  }
  try {
    const url = new URL(value);
    return (
      url.protocol === "http:" ||
      url.protocol === "https:" ||
      url.protocol === "mailto:"
    );
  } catch {
    return false;
  }
}

function isRenderableImageNode(node: BaseNode, hasPictureRenderer: boolean): boolean {
  if (hasPictureRenderer) return true;
  const record = node as BaseNode & { src?: unknown; loading?: unknown };
  if (record.loading) return true;
  return isSafeImageHref(record.src);
}

function isEmptyRenderedRoot(node: BaseNode, hasPictureRenderer: boolean): boolean {
  if (node.type === "image") {
    return !isRenderableImageNode(node, hasPictureRenderer);
  }
  if (node.type === "paragraph") {
    const children = (node as BaseNode & { children?: unknown }).children;
    if (!Array.isArray(children) || children.length === 0) return false;
    let sawDroppedImage = false;
    for (const child of children) {
      if (!child || typeof child !== "object" || !("type" in child)) {
        return false;
      }
      const typed = child as BaseNode & { content?: unknown };
      if (typed.type === "image") {
        if (isRenderableImageNode(typed, hasPictureRenderer)) return false;
        sawDroppedImage = true;
      } else if (
        typed.type === "text" &&
        typeof typed.content === "string" &&
        typed.content.trim() === ""
      ) {
        continue;
      } else {
        return false;
      }
    }
    return sawDroppedImage;
  }
  return false;
}

/**
 * Presentation only: keep the complete parsed document and its original root
 * indices. A nested special block keeps its list/quote together so numbering,
 * indentation, and citation context survive the bubble boundary.
 */
export function markdownPresentationSlots(
  nodes: readonly BaseNode[],
  presentation: MarkdownBlockPresentation,
  options?: MarkdownPresentationOptions
): MarkdownPresentationSlot[] {
  if (presentation === "document") {
    return nodes.map((_, index) => ({ rootIndices: [index] }));
  }

  const hasPictureRenderer = Boolean(options?.hasPictureRenderer);
  const slots: MarkdownPresentationSlot[] = [];
  let startsGroup = true;
  nodes.forEach((node, index) => {
    if (node.type === "thematic_break") {
      startsGroup = true;
      return;
    }
    if (isEmptyRenderedRoot(node, hasPictureRenderer)) {
      return;
    }
    const prose =
      proseRoots.has(node.type) && !containsStandaloneBlock(node, hasPictureRenderer);
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

function containsStandaloneBlock(node: BaseNode, hasPictureRenderer: boolean): boolean {
  if (node.type === "image") {
    return isRenderableImageNode(node, hasPictureRenderer);
  }
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
        containsStandaloneBlock(child as BaseNode, hasPictureRenderer)
      ) {
        return true;
      }
    }
  }
  return false;
}
