import { useLayoutEffect, type RefObject } from "react";
import { findTextHighlights } from "./searchText";

export const TASK_PREVIEW_SEARCH_HIGHLIGHT = "comma-task-preview-search-match";
export const TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY =
  "task-preview-search-highlight-overlay";
export const TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT = "task-preview-search-highlight-rect";

const MESSAGE_SELECTOR =
  '[data-slot="chat-user-output"], [data-slot="chat-assistant-output"]';
const BLOCK_BOUNDARY_TAGS = new Set([
  "ADDRESS",
  "ARTICLE",
  "ASIDE",
  "BLOCKQUOTE",
  "BR",
  "DD",
  "DIV",
  "DL",
  "DT",
  "FIGCAPTION",
  "FIGURE",
  "FOOTER",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HEADER",
  "HR",
  "LI",
  "MAIN",
  "NAV",
  "OL",
  "P",
  "PRE",
  "SECTION",
  "TABLE",
  "TBODY",
  "TD",
  "TFOOT",
  "TH",
  "THEAD",
  "TR",
  "UL",
]);
const SKIPPED_TAGS = new Set([
  "BUTTON",
  "INPUT",
  "SCRIPT",
  "SELECT",
  "STYLE",
  "SVG",
  "TEXTAREA",
]);
const TEXT_BOUNDARY = "\u0000";

type TextSegment = {
  end: number;
  node: Text;
  start: number;
};

type SearchableText = {
  segments: TextSegment[];
  text: string;
};

/**
 * Paints query matches over the rendered preview without changing renderer-owned
 * DOM. In particular, anchors and the spans Shiki owns stay intact.
 */
export function usePreviewSearchHighlight(
  rootRef: RefObject<HTMLElement | null>,
  overlayRef: RefObject<HTMLElement | null>,
  query: string
) {
  useLayoutEffect(() => {
    const root = rootRef.current;
    const overlay = overlayRef.current;
    const HighlightConstructor =
      typeof window === "undefined" ? undefined : window.Highlight;
    const registry = typeof CSS === "undefined" ? undefined : CSS.highlights;
    if (!root || !overlay || !query.trim()) {
      return undefined;
    }

    const usesNativeHighlight =
      typeof HighlightConstructor === "function" && Boolean(registry);
    let animationFrame: number | undefined;
    let disposed = false;
    let ranges: Range[] = [];
    let shouldRefreshRanges = true;
    let ownedHighlight: Highlight | null = null;

    const clearOwnedHighlight = () => {
      if (
        registry &&
        ownedHighlight &&
        registry.get(TASK_PREVIEW_SEARCH_HIGHLIGHT) === ownedHighlight
      ) {
        registry.delete(TASK_PREVIEW_SEARCH_HIGHLIGHT);
      }
      ownedHighlight = null;
    };

    const paint = () => {
      animationFrame = undefined;
      if (disposed) return;

      if (shouldRefreshRanges) {
        ranges = taskPreviewSearchRanges(root, query);
        shouldRefreshRanges = false;
      }
      if (!usesNativeHighlight) {
        paintFallbackOverlay(root, overlay, ranges);
        return;
      }
      if (ranges.length === 0 || !registry || !HighlightConstructor) {
        clearOwnedHighlight();
        return;
      }

      const highlight = new HighlightConstructor(...ranges);
      registry.set(TASK_PREVIEW_SEARCH_HIGHLIGHT, highlight);
      ownedHighlight = highlight;
    };

    const schedulePaint = () => {
      if (disposed) return;
      if (animationFrame !== undefined) return;
      animationFrame = window.requestAnimationFrame(paint);
    };

    const scheduleRangeRefresh = () => {
      shouldRefreshRanges = true;
      schedulePaint();
    };

    const observer = new MutationObserver((records) => {
      if (records.every((record) => overlay.contains(record.target))) {
        return;
      }
      scheduleRangeRefresh();
    });
    observer.observe(root, {
      characterData: true,
      childList: true,
      subtree: true,
    });
    if (!usesNativeHighlight) {
      root.addEventListener("scroll", schedulePaint, true);
      window.addEventListener("resize", schedulePaint);
      void root.ownerDocument.fonts?.ready.then(schedulePaint);
    }
    paint();

    return () => {
      disposed = true;
      observer.disconnect();
      if (!usesNativeHighlight) {
        root.removeEventListener("scroll", schedulePaint, true);
        window.removeEventListener("resize", schedulePaint);
        overlay.replaceChildren();
      }
      if (animationFrame !== undefined) {
        window.cancelAnimationFrame(animationFrame);
      }
      clearOwnedHighlight();
    };
  }, [overlayRef, query, rootRef]);
}

function paintFallbackOverlay(
  root: HTMLElement,
  overlay: HTMLElement,
  ranges: readonly Range[]
) {
  const rootBounds = root.getBoundingClientRect();
  const fragment = root.ownerDocument.createDocumentFragment();

  for (const range of ranges) {
    if (!range.startContainer.isConnected || !range.endContainer.isConnected) {
      continue;
    }
    const clientRects =
      typeof range.getClientRects === "function" ? range.getClientRects() : [];
    for (const clientRect of clientRects) {
      const left = Math.max(clientRect.left, rootBounds.left);
      const top = Math.max(clientRect.top, rootBounds.top);
      const right = Math.min(clientRect.right, rootBounds.right);
      const bottom = Math.min(clientRect.bottom, rootBounds.bottom);
      if (right <= left || bottom <= top) continue;

      const marker = root.ownerDocument.createElement("span");
      marker.className = "comma-task-preview-search-highlight-rect";
      marker.dataset.slot = TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT;
      marker.style.left = `${left - rootBounds.left}px`;
      marker.style.top = `${top - rootBounds.top}px`;
      marker.style.width = `${right - left}px`;
      marker.style.height = `${bottom - top}px`;
      fragment.append(marker);
    }
  }

  overlay.replaceChildren(fragment);
}

export function taskPreviewSearchRanges(root: HTMLElement, query: string): Range[] {
  const ranges: Range[] = [];
  root.querySelectorAll<HTMLElement>(MESSAGE_SELECTOR).forEach((message) => {
    const searchable = searchableText(message);
    ranges.push(...rangesForSearchableText(searchable, query));
  });
  return ranges;
}

function searchableText(root: HTMLElement): SearchableText {
  const segments: TextSegment[] = [];
  let text = "";

  const appendBoundary = () => {
    if (text.length > 0 && !text.endsWith(TEXT_BOUNDARY)) {
      text += TEXT_BOUNDARY;
    }
  };

  const visit = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const value = node.nodeValue ?? "";
      if (!value) return;
      const start = text.length;
      text += value;
      segments.push({ end: text.length, node: node as Text, start });
      return;
    }
    if (!(node instanceof HTMLElement)) return;

    if (shouldSkipElement(node)) {
      appendBoundary();
      return;
    }

    const blockBoundary =
      BLOCK_BOUNDARY_TAGS.has(node.tagName) || node.classList.contains("block");
    if (blockBoundary) appendBoundary();
    node.childNodes.forEach(visit);
    if (blockBoundary) appendBoundary();
  };

  visit(root);
  return { segments, text };
}

function shouldSkipElement(element: HTMLElement) {
  return (
    SKIPPED_TAGS.has(element.tagName) ||
    element.hidden ||
    element.getAttribute("aria-hidden") === "true" ||
    element.classList.contains("hidden") ||
    element.classList.contains("comma-chat-assistant-source-label")
  );
}

function rangesForSearchableText(searchable: SearchableText, query: string): Range[] {
  if (!searchable.text || searchable.segments.length === 0) return [];

  const ranges: Range[] = [];
  let startSegmentIndex = 0;
  let endSegmentIndex = 0;

  for (const highlight of findTextHighlights(searchable.text, query)) {
    while (
      startSegmentIndex < searchable.segments.length &&
      highlight.start >= searchable.segments[startSegmentIndex]!.end
    ) {
      startSegmentIndex += 1;
    }
    endSegmentIndex = Math.max(endSegmentIndex, startSegmentIndex);
    while (
      endSegmentIndex < searchable.segments.length &&
      highlight.end > searchable.segments[endSegmentIndex]!.end
    ) {
      endSegmentIndex += 1;
    }

    const startSegment = searchable.segments[startSegmentIndex];
    const endSegment = searchable.segments[endSegmentIndex];
    if (
      !startSegment ||
      !endSegment ||
      highlight.start < startSegment.start ||
      highlight.end <= endSegment.start
    ) {
      continue;
    }

    const range = startSegment.node.ownerDocument.createRange();
    range.setStart(startSegment.node, highlight.start - startSegment.start);
    range.setEnd(endSegment.node, highlight.end - endSegment.start);
    ranges.push(range);
  }

  return ranges;
}
