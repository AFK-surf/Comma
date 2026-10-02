import { useCallback, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { flushSync } from "react-dom";
import { isReducedMotionEnabled } from "../../../tokens";
import {
  AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MIN_HEIGHT_PX,
} from "../styles";
import {
  nextSmallUsesDefaultLayout,
  trackNarrowest,
  type CompactBox,
} from "./measurement";
import { readCollapsedPrompt } from "./readCollapsedPrompt";
import { readRichPrompt } from "./readRichPrompt";
import {
  reportHeights,
  type AiInputLayoutHeights,
  type HeightReportTarget,
} from "./reportHeights";

export type { AiInputLayoutHeights };

export interface AiInputAutoSizeOptions extends HeightReportTarget {
  hasValue: boolean;
  isSmall: boolean;
  maxHeightOverride: number | undefined;
  measurementWidthMode: "rendered" | "narrowest";
  minHeightOverride: number | undefined;
  promptRef: RefObject<HTMLElement | null>;
}

/**
 * Sizes the prompt and switches the small composer between compact and
 * expanded.
 *
 * CSS sizes the rich editor between its min and max height, so an edit is
 * never collapsed and restored to be measured. An edit's read waits for the
 * next animation frame, where it shares that frame's layout; only a changed
 * answer commits, before the frame paints, so the resize transition starts
 * with the text. A host that sizes itself from the reported heights (a native
 * window around the composer) reads at the edit instead, so it hears the new
 * size ahead of the frame that paints it. A value written from outside (such
 * as a restored draft) is measured in the layout pass that writes it, so
 * motion that follows sees the layout settled.
 */
export function useAiInputAutoSize(options: AiInputAutoSizeOptions) {
  const { isSmall, maxHeightOverride, measurementWidthMode, minHeightOverride } =
    options;
  const [smallUsesDefaultLayout, setSmallUsesDefaultLayout] = useState(false);
  const textareaMinHeight =
    minHeightOverride ??
    (isSmall
      ? smallUsesDefaultLayout
        ? AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX
        : AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX
      : AI_INPUT_TEXTAREA_MIN_HEIGHT_PX);
  const textareaMaxHeight =
    maxHeightOverride ??
    (isSmall ? AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX : AI_INPUT_TEXTAREA_MAX_HEIGHT_PX);
  const [promptHeight, setPromptHeight] = useState(textareaMinHeight);

  const inputs = {
    ...options,
    smallUsesDefaultLayout,
    textareaMaxHeight,
    textareaMinHeight,
  };
  const latest = useRef(inputs);
  useLayoutEffect(() => {
    latest.current = inputs;
  });
  const compactBox = useRef<CompactBox | undefined>(undefined);
  const narrowestWidth = useRef<number | undefined>(undefined);
  const reported = useRef<AiInputLayoutHeights | undefined>(undefined);
  const synced = useRef(false);
  const pendingPromptLeft = useRef<number | null>(null);
  const frame = useRef<number | undefined>(undefined);

  /** One layout read that commits only what changed; safe in layout effects. */
  const measureNow = useCallback(() => {
    const current = latest.current;
    const prompt = current.promptRef.current;
    if (!prompt) return;
    const expanded = current.smallUsesDefaultLayout;
    const compact = current.isSmall && !expanded;
    const narrowest =
      current.measurementWidthMode === "narrowest"
        ? trackNarrowest(prompt, narrowestWidth)
        : undefined;
    const measurement =
      prompt instanceof HTMLTextAreaElement || narrowest !== undefined
        ? readCollapsedPrompt(prompt, {
            compact,
            compactBox,
            expanded,
            hasValue: current.hasValue,
            narrowestWidth: narrowest,
          })
        : readRichPrompt(prompt, { compact, compactBox, hasValue: current.hasValue });
    const nextExpanded =
      current.isSmall && nextSmallUsesDefaultLayout(expanded, measurement);
    if (nextExpanded !== expanded) {
      // The layout effect below measures again once the switch commits.
      if (synced.current && measurement.width > 0) {
        pendingPromptLeft.current = measurement.left;
      }
      synced.current = true;
      setSmallUsesDefaultLayout(nextExpanded);
      return;
    }
    synced.current = true;
    const height = Math.min(
      Math.max(measurement.height, current.textareaMinHeight),
      current.textareaMaxHeight
    );
    if (measurement.explicitHeight) prompt.style.height = `${height}px`;
    else if (prompt.style.height) prompt.style.removeProperty("height");
    setPromptHeight((previous) => (previous === height ? previous : height));
    reportHeights(current, height, reported);
  }, []);

  /** Coalesces reads into one in the next frame, before it paints. */
  const requestMeasure = useCallback(() => {
    if (frame.current !== undefined) return;
    frame.current = window.requestAnimationFrame(() => {
      frame.current = undefined;
      flushSync(measureNow);
    });
  }, [measureNow]);

  /** An edit's read: at the edit when a host sizes itself from it. */
  const measureEdit = useCallback(() => {
    const { onLayoutHeightChange, onTextareaHeightChange } = latest.current;
    if (onLayoutHeightChange || onTextareaHeightChange) measureNow();
    else requestMeasure();
  }, [measureNow, requestMeasure]);

  // Layout inputs changed, or the small layout switched: measure the
  // committed layout before it paints.
  useLayoutEffect(measureNow, [
    isSmall,
    maxHeightOverride,
    measureNow,
    measurementWidthMode,
    minHeightOverride,
    smallUsesDefaultLayout,
  ]);

  // A size change without an edit (window, sidebar, font) measures again.
  useLayoutEffect(() => {
    const prompt = options.promptRef.current;
    if (!prompt || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(requestMeasure);
    observer.observe(prompt);
    return () => observer.disconnect();
  }, [options.promptRef, requestMeasure]);

  // The switch slides the prompt from where it was, starting in the frame
  // the resize starts: the flush commits the offset, so the transform then
  // transitions home. It stays on the prompt itself.
  useLayoutEffect(() => {
    const previousLeft = pendingPromptLeft.current;
    const prompt = options.promptRef.current;
    if (previousLeft === null || !prompt) return;
    pendingPromptLeft.current = null;
    const deltaX = previousLeft - prompt.getBoundingClientRect().left;
    if (Math.abs(deltaX) < 0.5 || isReducedMotionEnabled()) return;
    prompt.style.transition = "none";
    prompt.style.transform = `translateX(${deltaX}px)`;
    void prompt.offsetWidth;
    prompt.style.removeProperty("transition");
    prompt.style.transform = "translateX(0)";
  }, [options.promptRef, smallUsesDefaultLayout]);

  // Forget the cancelled frame too: a remount (Strict Mode replays effects)
  // must be able to ask for the next one.
  useLayoutEffect(
    () => () => {
      if (frame.current === undefined) return;
      window.cancelAnimationFrame(frame.current);
      frame.current = undefined;
    },
    []
  );

  return {
    measureEdit,
    measureNow,
    promptHeight,
    requestMeasure,
    smallUsesDefaultLayout,
    textareaMaxHeight,
    textareaMinHeight,
    usesCompactLayout: isSmall && !smallUsesDefaultLayout,
  };
}
