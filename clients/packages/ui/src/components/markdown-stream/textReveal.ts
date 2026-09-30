import { matchTextIdentity } from "./textRevealIdentity";

// Paint the arriving tail without splitting the browser's text shaping run.
// One frame callback and at most 220 grapheme ranges per streaming document;
// no geometry reads, per-character timers, or second content playback queue.
const DURATION_MS = 150;
const STAGGER_MS = 10;
const MAX_STAGGER_MS = 90;
const LEVELS = 16;
const MAX_CHARACTERS = 220;
let nextPainterId = 0;

const reducedMotion = () =>
  window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ||
  document.documentElement.dataset.commaReducedMotion === "true";

interface RevealedGrapheme {
  node: Text;
  start: number;
  end: number;
  startsAt: number;
  range: Range;
  root: string;
  rootOffset: number;
}

export interface TextRevealLeaf {
  node: Text;
  content: string;
  enabled: boolean;
}

export function createTextReveal(maxCharacters: number) {
  const prefix = `comma-text-reveal-${nextPainterId++}`;
  const names = Array.from({ length: LEVELS }, (_, index) => `${prefix}-${index}`);
  const limit = Number.isFinite(maxCharacters)
    ? Math.max(0, Math.min(MAX_CHARACTERS, Math.trunc(maxCharacters)))
    : MAX_CHARACTERS;
  const segmenter =
    typeof Intl.Segmenter === "function"
      ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
      : undefined;
  let active: RevealedGrapheme[] = [];
  let frame: number | undefined;
  let highlights: Highlight[] | undefined;
  // Keep text only when a virtualized root leaves the DOM, never detached DOM
  // trees or per-character history. The document owns this ledger's lifetime.
  const rootText = new Map<string, string>();
  const retiringRoots = new Set<string>();

  const supported = () =>
    typeof CSS !== "undefined" &&
    Boolean(CSS.highlights) &&
    typeof Highlight === "function" &&
    typeof requestAnimationFrame === "function" &&
    Boolean(segmenter);

  const clearPaint = () => {
    if (frame !== undefined) cancelAnimationFrame(frame);
    frame = undefined;
    if (highlights) names.forEach((name) => CSS.highlights.delete(name));
    highlights = undefined;
  };

  const flush = () => {
    active = [];
    retiringRoots.clear();
    clearPaint();
  };

  const paint = (now: number, collectUnmounted = true) => {
    if (reducedMotion()) {
      flush();
      return;
    }
    active = active.filter(
      (glyph) =>
        now < glyph.startsAt + DURATION_MS &&
        (!collectUnmounted ||
          (!retiringRoots.has(glyph.root) &&
            glyph.node.isConnected &&
            glyph.end <= glyph.node.length))
    );
    if (collectUnmounted) retiringRoots.clear();
    if (active.length === 0) {
      retiringRoots.clear();
      clearPaint();
      return;
    }
    if (!highlights) {
      highlights = names.map((name) => {
        const highlight = new Highlight();
        CSS.highlights.set(name, highlight);
        return highlight;
      });
    }
    highlights.forEach((highlight) => highlight.clear());
    for (const glyph of active) {
      // Another root in this same React commit may not have reclaimed its
      // replacement nodes yet. Keep its age but never paint a retired range.
      if (
        retiringRoots.has(glyph.root) ||
        !glyph.node.isConnected ||
        glyph.end > glyph.node.length
      )
        continue;
      // Text.data replacement by React resets live Range offsets. Restore the
      // offsets, retaining the original time, before the browser paints.
      glyph.range.setStart(glyph.node, glyph.start);
      glyph.range.setEnd(glyph.node, glyph.end);
      const progress = Math.max(0, Math.min(1, (now - glyph.startsAt) / DURATION_MS));
      const eased = progress * progress * (3 - 2 * progress);
      const level = Math.min(LEVELS - 1, Math.floor(eased * LEVELS));
      highlights[level]!.add(glyph.range);
    }
    if (frame === undefined) {
      frame = requestAnimationFrame((time) => {
        frame = undefined;
        paint(time);
      });
    }
  };

  const settledRules = names
    .map(
      (name) =>
        `[data-comma-text-reveal]::highlight(${name}) { color: var(--comma-stream-text-color); }`
    )
    .join("\n");

  return {
    // A highlight's currentColor follows highlight inheritance, not the source
    // text color. The existing text span supplies its computed source color.
    css:
      names
        .map(
          (name, index) =>
            `[data-comma-text-reveal]::highlight(${name}) { color: color-mix(in srgb, var(--comma-stream-text-color) ${((index + 1) / LEVELS) * 100}%, transparent); }`
        )
        .join("\n") +
      `\n@media (prefers-reduced-motion: reduce) { ${settledRules} }\n` +
      names
        .map(
          (name) =>
            `[data-comma-reduced-motion="true"] [data-comma-text-reveal]::highlight(${name}) { color: var(--comma-stream-text-color); }`
        )
        .join("\n"),
    flush,
    retainRoots(keys: ReadonlySet<string>) {
      for (const key of rootText.keys()) {
        if (!keys.has(key)) rootText.delete(key);
      }
      active = active.filter((glyph) => keys.has(glyph.root));
      if (highlights) paint(performance.now(), false);
    },
    unmountRoot(root: string) {
      // React can replace a root wrapper in the same commit that confirms its
      // Markdown structure. Keep ages until the existing next paint so the new
      // wrapper can reclaim them; a real unmount is removed at that paint.
      if (active.some((glyph) => glyph.root === root)) retiringRoots.add(root);
    },
    commitRoot(root: string, leaves: readonly TextRevealLeaf[]) {
      retiringRoots.delete(root);
      const content = leaves.map((leaf) => leaf.content).join("");
      const previous = rootText.get(root) ?? "";
      rootText.set(root, content);
      const priorActive = new Map(
        active
          .filter((glyph) => glyph.root === root)
          .map((glyph) => [glyph.rootOffset, glyph])
      );
      active = active.filter((glyph) => glyph.root !== root);
      if (!supported() || reducedMotion() || limit === 0) {
        paint(performance.now(), false);
        return;
      }
      const identity = matchTextIdentity(previous, content);
      const now = performance.now();
      const candidates: RevealedGrapheme[] = [];
      const arriving = new Set<RevealedGrapheme>();
      let rootEnd = content.length;
      let inspected = 0;
      // Only the newest bounded tail needs grapheme segmentation. All earlier
      // text remains clear regardless of root size or the number of chunks.
      for (let index = leaves.length - 1; index >= 0 && inspected < limit; index--) {
        const leaf = leaves[index]!;
        const rootStart = rootEnd - leaf.content.length;
        rootEnd = rootStart;
        if (!leaf.enabled || !leaf.node.isConnected) continue;
        const segments = segmenter!.segment(leaf.content);
        let offset = leaf.content.length - 1;
        while (offset >= 0 && inspected < limit) {
          const segment = segments.containing(offset);
          if (!segment) break;
          inspected++;
          const rootOffset = rootStart + segment.index;
          const inherited = identity.spans.find(
            (span) =>
              rootOffset >= span.currentStart &&
              rootOffset < span.currentStart + span.length
          );
          const previousOffset = inherited
            ? inherited.previousStart + rootOffset - inherited.currentStart
            : undefined;
          const old =
            previousOffset === undefined ? undefined : priorActive.get(previousOffset);
          if (old && now < old.startsAt + DURATION_MS) {
            candidates.push({
              ...old,
              node: leaf.node,
              start: segment.index,
              end: segment.index + segment.segment.length,
              rootOffset,
            });
          } else if (!inherited && identity.complete) {
            const glyph: RevealedGrapheme = {
              node: leaf.node,
              start: segment.index,
              end: segment.index + segment.segment.length,
              root,
              rootOffset,
              startsAt: now,
              range: leaf.node.ownerDocument.createRange(),
            };
            candidates.push(glyph);
            arriving.add(glyph);
          }
          offset = segment.index - 1;
        }
      }
      let stagger = 0;
      for (const glyph of candidates.toReversed()) {
        if (arriving.has(glyph)) {
          glyph.startsAt += Math.min(stagger++ * STAGGER_MS, MAX_STAGGER_MS);
        }
        active.push(glyph);
      }
      if (active.length > limit) active = active.slice(-limit);
      paint(now, false);
    },
  };
}

export type TextReveal = ReturnType<typeof createTextReveal>;
