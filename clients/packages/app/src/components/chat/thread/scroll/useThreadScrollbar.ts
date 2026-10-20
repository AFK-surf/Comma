import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { useStickToBottom } from "./useStickToBottom";
import type { ThreadTurnWindow } from "../navigation/useThreadTurnWindow";
import { hasMeaningfulChatOverflow, type ChatThreadGeometry } from "./threadGeometry";

type ScrollEnableBehavior = "anchor-latest" | "follow-bottom" | "preserve";
type Follow = ReturnType<typeof useStickToBottom>;

export type ThreadScrollbar = ReturnType<typeof useThreadScrollbar>;

export function useThreadScrollbar({
  follow: {
    anchorTurn,
    handleContentResize,
    isFollowing,
    scrollRootRef,
    scrollToBottom,
  },
  latestTurnKey,
  messageKey,
  presentingOutgoing,
  readThreadGeometry,
  reconcileViewport,
}: {
  follow: Pick<
    Follow,
    | "anchorTurn"
    | "handleContentResize"
    | "isFollowing"
    | "scrollRootRef"
    | "scrollToBottom"
  >;
  latestTurnKey: string | undefined;
  messageKey: string;
  /** A sent message is flying to its slot: the transcript's layout is mid-animation. */
  presentingOutgoing: boolean;
  readThreadGeometry: (viewport: HTMLElement) => ChatThreadGeometry;
  reconcileViewport: ThreadTurnWindow["reconcileViewport"];
}) {
  const [scrollEnabled, setScrollEnabled] = useState(false);
  const previousScrollEnabledRef = useRef(scrollEnabled);
  const reconciledMessageKeyRef = useRef<string | undefined>(undefined);
  const pendingScrollEnableBehaviorRef = useRef<ScrollEnableBehavior | null>(null);
  const presentingOutgoingRef = useRef(presentingOutgoing);
  presentingOutgoingRef.current = presentingOutgoing;
  const hasThreadOverflow = useCallback(() => {
    const viewport = scrollRootRef.current;
    return viewport !== null && hasMeaningfulChatOverflow(readThreadGeometry(viewport));
  }, [readThreadGeometry, scrollRootRef]);
  const updateScrollEnabled = useCallback(
    (
      behavior: ScrollEnableBehavior = "anchor-latest",
      measured?: ChatThreadGeometry,
      launch = false
    ) => {
      const viewport = scrollRootRef.current;
      if (!viewport) {
        return;
      }
      // Whether the thread scrolls changes its layout (the latest turn's reserve), so a
      // send decides it once, from the settled layout, as the message launches
      // (decideForOutgoingLaunch). A flight's growing slot is not the transcript's
      // size: deciding from it mid-flight moved the landed message a second time.
      if (presentingOutgoingRef.current && !launch) {
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
    [readThreadGeometry, scrollRootRef]
  );

  /**
   * Decides scrolling for a message about to launch, while its slot still has its full
   * height: the layout the flight lands in. The launch anchors its turn itself, so
   * enabling scrolling here moves nothing.
   */
  const decideForOutgoingLaunch = useCallback(
    () => updateScrollEnabled("preserve", undefined, true),
    [updateScrollEnabled]
  );

  // What changed while a message flew (a reply arriving, history loading) is decided
  // once it has landed; the layout the launch decided from is then the settled one.
  const wasPresentingOutgoingRef = useRef(presentingOutgoing);
  useLayoutEffect(() => {
    const wasPresenting = wasPresentingOutgoingRef.current;
    wasPresentingOutgoingRef.current = presentingOutgoing;
    if (wasPresenting && !presentingOutgoing) updateScrollEnabled("preserve");
  }, [presentingOutgoing, updateScrollEnabled]);

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
    if (previousEnabled === scrollEnabled) {
      return;
    }

    if (scrollEnabled) {
      // A reader who left the tail keeps their place when the thread starts to
      // scroll: what arrived shows in the unseen pill, as in a thread that scrolls.
      const behavior = isFollowing()
        ? pendingScrollEnableBehaviorRef.current
        : "preserve";
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
    isFollowing,
    latestTurnKey,
    scrollEnabled,
    scrollToBottom,
  ]);

  return {
    decideForOutgoingLaunch,
    hasThreadOverflow,
    scrollEnabled,
    updateScrollEnabled,
  };
}
