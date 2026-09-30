import { flushSync } from "react-dom";

/** Measures a laid-out bubble and reports whether its content overflows the clamp. */
export function measureUserBubble(bubble: HTMLElement, content: HTMLElement) {
  bubble.removeAttribute("data-outgoing-measurement");
  const bubbleStyle = getComputedStyle(bubble);
  const paddingBlock =
    Number.parseFloat(bubbleStyle.paddingTop) +
    Number.parseFloat(bubbleStyle.paddingBottom);
  const fullBubbleHeight = content.scrollHeight + paddingBlock;
  const collapsedBubbleHeight = Number.parseFloat(
    bubbleStyle.getPropertyValue("--comma-chat-user-bubble-collapsed-block-size")
  );
  content.style.setProperty(
    "--comma-chat-user-bubble-expanded-block-size",
    `${content.scrollHeight}px`
  );
  return (
    Number.isFinite(collapsedBubbleHeight) &&
    fullBubbleHeight > collapsedBubbleHeight + 1
  );
}

/** The same overflow test, read without writing to the bubble. */
export function userBubbleOverflows(bubble: HTMLElement, content: HTMLElement) {
  const bubbleStyle = getComputedStyle(bubble);
  const paddingBlock =
    Number.parseFloat(bubbleStyle.paddingTop) +
    Number.parseFloat(bubbleStyle.paddingBottom);
  const collapsedBlockSize = Number.parseFloat(
    bubbleStyle.getPropertyValue("--comma-chat-user-bubble-collapsed-block-size")
  );
  return (
    Number.isFinite(collapsedBlockSize) &&
    content.scrollHeight + paddingBlock > collapsedBlockSize + 1
  );
}

/** Runs `measure` after mount and on every size change; returns the teardown. */
export function observeUserBubble(
  content: Element,
  remProbe: Element | null,
  measure: () => void
) {
  // Measure after the mount task, then commit the disclosure before paint.
  // Coalesce font readiness with the first measurement, including StrictMode.
  let active = true;
  let measureFrame: number | undefined;
  const scheduleMeasure = () => {
    if (!active || measureFrame !== undefined) return;
    measureFrame = window.requestAnimationFrame(() => {
      measureFrame = undefined;
      if (document.fonts?.status === "loading") {
        void document.fonts.ready.then(scheduleMeasure);
      }
      flushSync(measure);
    });
  };
  scheduleMeasure();
  if (typeof ResizeObserver === "undefined") {
    return () => {
      active = false;
      if (measureFrame !== undefined) window.cancelAnimationFrame(measureFrame);
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
    if (measureFrame !== undefined) window.cancelAnimationFrame(measureFrame);
    observer.disconnect();
  };
}
