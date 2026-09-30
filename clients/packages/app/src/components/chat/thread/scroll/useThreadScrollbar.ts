import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { useStickToBottom } from "./useStickToBottom";
import type { ThreadTurnWindow } from "../navigation/useThreadTurnWindow";
import { hasMeaningfulChatOverflow, type ChatThreadGeometry } from "./threadGeometry";

type ScrollEnableBehavior = "anchor-latest" | "follow-bottom" | "preserve";
type Follow = ReturnType<typeof useStickToBottom>;

export type ThreadScrollbar = ReturnType<typeof useThreadScrollbar>;

export function useThreadScrollbar({
  follow: { anchorTurn, handleContentResize, scrollRootRef, scrollToBottom },
  latestTurnKey,
  messageKey,
  readThreadGeometry,
  reconcileViewport,
  variant,
}: {
  follow: Pick<
    Follow,
    "anchorTurn" | "handleContentResize" | "scrollRootRef" | "scrollToBottom"
  >;
  latestTurnKey: string | undefined;
  messageKey: string;
  readThreadGeometry: (viewport: HTMLElement) => ChatThreadGeometry;
  reconcileViewport: ThreadTurnWindow["reconcileViewport"];
  variant: "default" | "side-chat";
}) {
  const [scrollEnabled, setScrollEnabled] = useState(variant !== "default");
  const previousScrollEnabledRef = useRef(scrollEnabled);
  const reconciledMessageKeyRef = useRef<string | undefined>(undefined);
  const pendingScrollEnableBehaviorRef = useRef<ScrollEnableBehavior | null>(null);
  const hasThreadOverflow = useCallback(() => {
    const viewport = scrollRootRef.current;
    return viewport !== null && hasMeaningfulChatOverflow(readThreadGeometry(viewport));
  }, [readThreadGeometry, scrollRootRef]);
  const updateScrollEnabled = useCallback(
    (
      behavior: ScrollEnableBehavior = "anchor-latest",
      measured?: ChatThreadGeometry
    ) => {
      if (variant !== "default") {
        setScrollEnabled(true);
        return;
      }

      const viewport = scrollRootRef.current;
      if (!viewport) {
        return;
      }

      const geometry = measured ?? readThreadGeometry(viewport);
      const nextEnabled = hasMeaningfulChatOverflow(geometry);
      if (nextEnabled && !previousScrollEnabledRef.current) {
        if (
          behavior === "follow-bottom" ||
          pendingScrollEnableBehaviorRef.current === null
        ) {
          pendingScrollEnableBehaviorRef.current = behavior;
        }
      } else if (!nextEnabled) {
        pendingScrollEnableBehaviorRef.current = null;
      }
      setScrollEnabled((current) => (current === nextEnabled ? current : nextEnabled));
    },
    [readThreadGeometry, scrollRootRef, variant]
  );

  useLayoutEffect(() => {
    if (reconciledMessageKeyRef.current === messageKey) {
      return;
    }
    reconciledMessageKeyRef.current = messageKey;
    updateScrollEnabled("follow-bottom");
    reconcileViewport();
  }, [messageKey, reconcileViewport, updateScrollEnabled]);

  useLayoutEffect(() => {
    const previousEnabled = previousScrollEnabledRef.current;
    previousScrollEnabledRef.current = scrollEnabled;
    if (variant !== "default" || previousEnabled === scrollEnabled) {
      return;
    }

    if (scrollEnabled) {
      const behavior = pendingScrollEnableBehaviorRef.current;
      pendingScrollEnableBehaviorRef.current = null;
      if (behavior === "follow-bottom") {
        scrollToBottom();
      } else if (behavior !== "preserve" && latestTurnKey) {
        anchorTurn(latestTurnKey);
      } else if (behavior !== "preserve") {
        handleContentResize();
      }
    } else {
      scrollToBottom();
    }
  }, [
    anchorTurn,
    handleContentResize,
    latestTurnKey,
    scrollEnabled,
    scrollToBottom,
    variant,
  ]);

  return { hasThreadOverflow, scrollEnabled, updateScrollEnabled };
}
