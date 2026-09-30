export const CONTEXT_SELECTION_HIGHLIGHT = "comma-context-selection";

export function snapshotLiveTextSelection(): Range[] {
  if (typeof window === "undefined") return [];
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return [];

  const ranges: Range[] = [];
  for (let index = 0; index < selection.rangeCount; index += 1) {
    ranges.push(selection.getRangeAt(index).cloneRange());
  }
  return ranges;
}

export function paintContextSelectionHighlight(
  ranges: readonly Range[]
): Highlight | null {
  const HighlightCtor = typeof window === "undefined" ? undefined : window.Highlight;
  const registry = typeof CSS === "undefined" ? undefined : CSS.highlights;
  const connected = ranges.filter(
    (range) => range.startContainer.isConnected && range.endContainer.isConnected
  );
  if (typeof HighlightCtor !== "function" || !registry || connected.length === 0) {
    return null;
  }
  const highlight = new HighlightCtor(...connected);
  registry.set(CONTEXT_SELECTION_HIGHLIGHT, highlight);
  return highlight;
}

export function clearContextSelectionHighlight(highlight: Highlight | null) {
  const registry = typeof CSS === "undefined" ? undefined : CSS.highlights;
  if (!registry || !highlight) return;
  if (registry.get(CONTEXT_SELECTION_HIGHLIGHT) !== highlight) return;
  registry.delete(CONTEXT_SELECTION_HIGHLIGHT);
}
