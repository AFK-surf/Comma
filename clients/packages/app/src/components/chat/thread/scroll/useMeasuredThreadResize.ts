import type { ScrollAreaMetrics } from "@comma/ui";
import { useCallback, useRef } from "react";
import type { useStickToBottom } from "./useStickToBottom";
import type { ThreadTurnWindow } from "../navigation/useThreadTurnWindow";
import type { ChatThreadGeometry } from "./threadGeometry";
import type { ThreadScrollbar } from "./useThreadScrollbar";

type Follow = ReturnType<typeof useStickToBottom>;

export type MeasuredThreadResize = ReturnType<typeof useMeasuredThreadResize>;

export function useMeasuredThreadResize({
  follow: {
    handleContentResize,
    handleScrollMetrics,
    handleViewportResize,
    scrollRootRef,
  },
  readThreadGeometry,
  scrollbar: { updateScrollEnabled },
  turnWindow: { hasMeasuredContentRef, reconcileViewport },
}: {
  follow: Pick<
    Follow,
    | "handleContentResize"
    | "handleScrollMetrics"
    | "handleViewportResize"
    | "scrollRootRef"
  >;
  readThreadGeometry: (viewport: HTMLElement) => ChatThreadGeometry;
  scrollbar: Pick<ThreadScrollbar, "updateScrollEnabled">;
  turnWindow: Pick<ThreadTurnWindow, "hasMeasuredContentRef" | "reconcileViewport">;
}) {
  const measuredResizeGeometryRef = useRef("");
  /**
   * One read pass, then the follow write, then only what has to observe it.
   * Overflow is a pure function of the measurement already taken, and the
   * turn-window metrics reuse its heights — a scroll write moves the offset,
   * not the content — so `scrollTop` is the single post-write read.
   */
  const reconcileMeasuredResize = useCallback(
    (settleFollow: () => void, fillViewport = false) => {
      const viewport = scrollRootRef.current;
      if (!viewport) {
        return;
      }

      const geometry = readThreadGeometry(viewport);
      const geometryKey = `${geometry.viewportClientHeight}:${geometry.threadScrollHeight}:${geometry.latestTurnScrollHeight}`;
      if (measuredResizeGeometryRef.current !== geometryKey) {
        measuredResizeGeometryRef.current = geometryKey;
        updateScrollEnabled("anchor-latest", geometry);
        settleFollow();
      } else if (!fillViewport) {
        return;
      }
      // Initial viewport measurement precedes child Markdown layout. Once
      // content has been measured, a viewport-only resize can safely fill too.
      reconcileViewport(
        {
          clientHeight: geometry.viewportClientHeight,
          scrollHeight: geometry.viewportScrollHeight,
          scrollTop: viewport.scrollTop,
        },
        fillViewport
      );
    },
    [readThreadGeometry, reconcileViewport, scrollRootRef, updateScrollEnabled]
  );
  const handleMeasuredContentResize = useCallback(() => {
    hasMeasuredContentRef.current = true;
    reconcileMeasuredResize(handleContentResize, true);
  }, [handleContentResize, hasMeasuredContentRef, reconcileMeasuredResize]);
  const handleMeasuredViewportResize = useCallback(() => {
    reconcileMeasuredResize(handleViewportResize, hasMeasuredContentRef.current);
  }, [handleViewportResize, hasMeasuredContentRef, reconcileMeasuredResize]);
  const handleThreadMetrics = useCallback(
    (metrics: ScrollAreaMetrics) => {
      handleScrollMetrics(metrics);
      reconcileViewport(metrics);
    },
    [handleScrollMetrics, reconcileViewport]
  );
  return {
    handleMeasuredContentResize,
    handleMeasuredViewportResize,
    handleThreadMetrics,
  };
}
