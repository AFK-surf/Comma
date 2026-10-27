import { useCallback, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { flushSync } from "react-dom";
import { scheduleLayoutRead, type CancelUiTimer } from "../../../clock";
import { isReducedMotionEnabled } from "../../../tokens";
import {
  AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MAX_HEIGHT_PX,
  AI_INPUT_TEXTAREA_MIN_HEIGHT_PX,
} from "../styles";
import type { CompactBox } from "./measurement";
import { readPromptLayout } from "./readPromptLayout";
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
 * size ahead of the frame that paints it. A value written from outside (a
 * restored draft, an accepted suggestion) is measured in the layout pass that
 * writes it, so motion that follows sees the layout settled.
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
  const frame = useRef<CancelUiTimer | undefined>(undefined);

  /** One layout read (`readPromptLayout`); returns the commit of only what changed. */
  const readLayout = useCallback((): (() => void) | undefined => {
    const current = latest.current;
    const layout = readPromptLayout(current, { compactBox, narrowestWidth });
    if (!layout) return undefined;
    if (layout.kind === "switch") {
      return () => {
        // The layout effect below measures again once the switch commits.
        if (synced.current && layout.width > 0) pendingPromptLeft.current = layout.left;
        synced.current = true;
        setSmallUsesDefaultLayout(layout.expanded);
      };
    }
    const { explicitHeight, extras, height, prompt } = layout;
    return () => {
      synced.current = true;
      if (explicitHeight) prompt.style.height = `${height}px`;
      else if (prompt.style.height) prompt.style.removeProperty("height");
      setPromptHeight((previous) => (previous === height ? previous : height));
      reportHeights(current, height, extras, reported);
    };
  }, []);

  /** Reads and commits at once; safe in layout effects. */
  const measureNow = useCallback(() => readLayout()?.(), [readLayout]);

  /** Coalesces reads into the next frame's shared read phase, committed before it paints. */
  const requestMeasure = useCallback(() => {
    if (frame.current !== undefined) return;
    frame.current = scheduleLayoutRead(() => {
      frame.current = undefined;
      const commit = readLayout();
      return commit && (() => flushSync(commit));
    });
  }, [readLayout]);

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
  // transitions home. It stays on the prompt itself: the accepted-suggestion
  // wave waits for it to settle.
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
      frame.current();
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
