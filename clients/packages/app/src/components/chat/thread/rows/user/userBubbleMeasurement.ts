import { flushSync } from "react-dom";
import {
  scheduleLayoutRead,
  type CancelUiTimer,
  type LayoutRead,
} from "@comma/ui/clock";

/**
 * Reads a laid-out bubble: whether its content overflows the clamp, and the
 * block size an expanded bubble opens to. It reads only, so every bubble of a
 * frame measures one layout (`scheduleLayoutRead`).
 */
export function readUserBubble(bubble: HTMLElement, content: HTMLElement) {
  // Absent outside a send's measurement, where removing it changes nothing.
  bubble.removeAttribute("data-outgoing-measurement");
  const { contentBlockSize, overflowing } = readBubbleBlock(bubble, content);
  return {
    // A collapsed bubble does not need the expanded size. Writing it would
    // restyle the whole text in the frame that measures it.
    expandedBlockSize:
      bubble.dataset.expanded === "true" ? contentBlockSize : undefined,
    overflowing,
  };
}

/** The same overflow test, read without writing to the bubble. */
export function userBubbleOverflows(bubble: HTMLElement, content: HTMLElement) {
  return readBubbleBlock(bubble, content).overflowing;
}

function readBubbleBlock(bubble: HTMLElement, content: HTMLElement) {
  const bubbleStyle = getComputedStyle(bubble);
  const paddingBlock =
    Number.parseFloat(bubbleStyle.paddingTop) +
    Number.parseFloat(bubbleStyle.paddingBottom);
  const contentBlockSize = content.scrollHeight;
  const collapsedBlockSize = Number.parseFloat(
    bubbleStyle.getPropertyValue("--comma-chat-user-bubble-collapsed-block-size")
  );
  return {
    contentBlockSize,
    overflowing:
      Number.isFinite(collapsedBlockSize) &&
      contentBlockSize + paddingBlock > collapsedBlockSize + 1,
  };
}

/** Text at least this long fills more than the collapsed bubble with its head alone. */
const LONG_TEXT_LENGTH = 12_000;
const HEAD_LENGTH = 6_000;

/**
 * Splits a very long message after a line near its start. The collapsed
 * bubble clips everything past the head, so the tail renders only once it can
 * be seen; sending such a message then lays out the head, not the whole text.
 * A message without a later line break stays whole: a split inside a line
 * would break that line in two.
 */
export function splitLongUserText(text: string) {
  if (text.length < LONG_TEXT_LENGTH) return undefined;
  const lineEnd = text.indexOf("\n", HEAD_LENGTH);
  if (lineEnd < 0 || lineEnd >= text.length - 1) return undefined;
  return { head: text.slice(0, lineEnd + 1), tail: text.slice(lineEnd + 1) };
}

/** Lays out a deferred tail from now on. Returns whether it was deferred. */
export function revealUserBubbleTail(tail: HTMLElement | null) {
  if (!tail || tail.dataset.revealed === "true") return false;
  tail.dataset.revealed = "true";
  return true;
}

/** The block size an expanded bubble opens to: its whole content. */
export function setUserBubbleExpandedSize(
  content: HTMLElement,
  blockSize = content.scrollHeight
) {
  content.style.setProperty(
    "--comma-chat-user-bubble-expanded-block-size",
    `${blockSize}px`
  );
}

/**
 * Runs `read` after mount and on every size change, in the frame's shared
 * layout read phase, and commits the writes it returns before paint. Returns
 * the teardown.
 */
export function observeUserBubble(
  content: Element,
  remProbe: Element | null,
  read: LayoutRead
) {
  // Measure after the mount task, then commit the disclosure before paint.
  // Coalesce font readiness with the first measurement, including StrictMode.
  let active = true;
  let measureFrame: CancelUiTimer | undefined;
  const scheduleMeasure = () => {
    if (!active || measureFrame !== undefined) return;
    measureFrame = scheduleLayoutRead(() => {
      measureFrame = undefined;
      if (document.fonts?.status === "loading") {
        void document.fonts.ready.then(scheduleMeasure);
      }
      const write = read();
      return write && (() => flushSync(write));
    });
  };
  scheduleMeasure();
  if (typeof ResizeObserver === "undefined") {
    return () => {
      active = false;
      if (measureFrame !== undefined) measureFrame();
    };
  }
  // Re-measure on any content box change — width from layout, height from
  // wrapped-text growth — and on root font-size changes via the 1rem probe.
  // A clamped overflowing bubble keeps a constant box when the root font
  // size grows, so the probe is the only signal that the scrollHeight (and
  // with it the expand control's necessity) changed.
  const observedSizes = new Map<Element, { height: number; width: number }>();
  const observer = new ResizeObserver((entries) => {
    let changed = false;
    for (const entry of entries) {
      const nextSize = {
        height: entry.contentRect.height,
        width: entry.contentRect.width,
      };
      const previous = observedSizes.get(entry.target);
      if (
        !previous ||
        Math.abs(nextSize.width - previous.width) > 0.5 ||
        Math.abs(nextSize.height - previous.height) > 0.5
      ) {
        if (previous) changed = true;
        observedSizes.set(entry.target, nextSize);
      }
    }
    if (changed) scheduleMeasure();
  });
  observer.observe(content);
  if (remProbe) observer.observe(remProbe);
  return () => {
    active = false;
    if (measureFrame !== undefined) measureFrame();
    observer.disconnect();
  };
}
