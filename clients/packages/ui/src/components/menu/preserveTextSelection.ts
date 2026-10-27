export const CONTEXT_SELECTION_HIGHLIGHT = "comma-context-selection";

/**
 * Marks the element around a painted highlight's ranges: only it and what it
 * holds style the highlight (styles.css). Chromium computes a highlight's style
 * for every element a `::highlight()` rule reaches, on every restyle, whether
 * anything is painted or not.
 */
export const CONTEXT_SELECTION_SCOPE_ATTRIBUTE = "data-comma-context-selection";

// How many painted highlights hold each scope, so overlapping ones share it.
const scopeHolds = new Map<Element, number>();
const scopesOf = new WeakMap<Highlight, Element[]>();

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
  const scopes = [
    ...new Set(
      connected.flatMap((range) => {
        const around = range.commonAncestorContainer;
        const element = around instanceof Element ? around : around.parentElement;
        return element ? [element] : [];
      })
    ),
  ];
  for (const scope of scopes) {
    scopeHolds.set(scope, (scopeHolds.get(scope) ?? 0) + 1);
    scope.setAttribute(CONTEXT_SELECTION_SCOPE_ATTRIBUTE, "");
  }
  scopesOf.set(highlight, scopes);
  registry.set(CONTEXT_SELECTION_HIGHLIGHT, highlight);
  return highlight;
}

export function clearContextSelectionHighlight(highlight: Highlight | null) {
  if (!highlight) return;
  // A newer highlight may have replaced this one in the registry; its scopes
  // are still this one's to release.
  for (const scope of scopesOf.get(highlight) ?? []) {
    const holds = (scopeHolds.get(scope) ?? 1) - 1;
    if (holds > 0) {
      scopeHolds.set(scope, holds);
    } else {
      scopeHolds.delete(scope);
      scope.removeAttribute(CONTEXT_SELECTION_SCOPE_ATTRIBUTE);
    }
  }
  scopesOf.delete(highlight);
  const registry = typeof CSS === "undefined" ? undefined : CSS.highlights;
  if (!registry) return;
  if (registry.get(CONTEXT_SELECTION_HIGHLIGHT) !== highlight) return;
  registry.delete(CONTEXT_SELECTION_HIGHLIGHT);
}
