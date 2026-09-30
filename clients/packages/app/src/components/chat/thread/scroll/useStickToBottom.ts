import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { isReducedMotionEnabled } from "@comma/ui";
import { isCommaSurfacePaused } from "../../../commaSurfacePause";

const BOTTOM_EPSILON_PX = 1;
const INTERACTION_SETTLE_MS = 1_000;
const TURN_TOP_INSET_PROPERTY = "--comma-chat-thread-top-inset";

type FollowMode = "away" | "following";
type ScrollIntentDirection = "away" | "toward";
type Interaction =
  | { kind: "idle" }
  | { id: number; kind: "away"; lastScrollTop: number }
  | { id: number; kind: "continuous"; lastScrollTop: number }
  | { id: number; kind: "settling"; lastScrollTop: number }
  | { id: number; kind: "toward"; lastScrollTop: number };

type StickState = {
  deferredUnseen: number;
  followMode: FollowMode;
  interaction: Interaction;
  unseen: number;
};

type ScrollGeometry = {
  distanceFromBottom: number;
  maxScrollTop: number;
  scrollTop: number;
};

type AnchoredTurn = {
  element: HTMLElement;
  key: string;
  target: number | undefined;
};

export function useStickToBottom(
  dependencyKey: string,
  options: {
    anchorKey?: string | undefined;
    forceKey?: string | undefined;
    followTarget?: "newest-turn" | "bottom" | undefined;
    /**
     * The newest turn's anchor element, handed over by whoever renders it.
     * Following it runs on every content resize — once a frame while a turn
     * streams — and finding it by attribute selector costs a walk of the
     * whole mounted transcript each time.
     */
    resolveNewestTurn: () => HTMLElement | null;
  }
) {
  const followTarget = options.followTarget ?? "newest-turn";
  const rootRef = useRef<HTMLDivElement>(null);
  const resolveNewestTurnRef = useRef(options.resolveNewestTurn);
  const previousDependencyKey = useRef(dependencyKey);
  const previousForceKey = useRef(options.forceKey);
  const previousAnchorKey = useRef(options.anchorKey);
  const initializedRef = useRef(false);
  const anchoredTurnRef = useRef<AnchoredTurn | null>(null);
  // Whether the reader has *asked* for the tail — the unseen-messages pill,
  // or a scroll gesture they carried to the exact bottom. Resting there
  // because nothing has pushed you off it is not the same thing, so this
  // stays false through mount and through an anchor that fails to resolve.
  const bottomPinnedRef = useRef(false);
  const nextInteractionIdRef = useRef(1);
  const interactionTimeoutRef = useRef<number | null>(null);
  const retainedFocusRef = useRef<Element | null>(null);
  const revealFocusRef = useRef<Element | null>(null);
  const revealRef = useRef<{ cancel: () => void; reconcile: () => void } | null>(null);
  const focusReconcileFrameRef = useRef<number | null>(null);
  const maxScrollTopRef = useRef(0);
  const stateRef = useRef<StickState>({
    deferredUnseen: 0,
    followMode: "following",
    interaction: { kind: "idle" },
    unseen: 0,
  });
  const [unseenCount, setUnseenCount] = useState(0);

  useLayoutEffect(() => {
    resolveNewestTurnRef.current = options.resolveNewestTurn;
  });

  const viewport = useCallback(() => {
    const root = rootRef.current;
    if (root?.getAttribute("data-slot") === "scroll-area-viewport") {
      return root;
    }

    return (
      root?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]') ?? null
    );
  }, []);

  const measure = useCallback((node: HTMLElement): ScrollGeometry => {
    const maxScrollTop = Math.max(0, node.scrollHeight - node.clientHeight);
    maxScrollTopRef.current = maxScrollTop;
    return {
      distanceFromBottom: Math.max(0, maxScrollTop - node.scrollTop),
      maxScrollTop,
      scrollTop: node.scrollTop,
    };
  }, []);

  const readMaxScrollTop = useCallback((node: HTMLElement) => {
    const maxScrollTop = Math.max(0, node.scrollHeight - node.clientHeight);
    maxScrollTopRef.current = maxScrollTop;
    return maxScrollTop;
  }, []);

  // ScrollArea mutates interaction styles before downstream scroll handlers
  // run. Keep those hot paths layout-read-free: synchronously reading
  // scrollHeight there would restyle every highlighted token in the transcript.
  const measureScrollPosition = useCallback((node: HTMLElement): ScrollGeometry => {
    const maxScrollTop = maxScrollTopRef.current;
    return {
      distanceFromBottom: Math.max(0, maxScrollTop - node.scrollTop),
      maxScrollTop,
      scrollTop: node.scrollTop,
    };
  }, []);

  const isAtBottom = useCallback(
    (geometry: ScrollGeometry) => geometry.distanceFromBottom <= BOTTOM_EPSILON_PX,
    []
  );

  const publishUnseen = useCallback((next: number) => {
    stateRef.current.unseen = next;
    setUnseenCount(next);
  }, []);

  const clearInteractionTimeout = useCallback(() => {
    if (interactionTimeoutRef.current !== null) {
      window.clearTimeout(interactionTimeoutRef.current);
      interactionTimeoutRef.current = null;
    }
  }, []);

  const clearFocusReconcileFrame = useCallback(() => {
    if (focusReconcileFrameRef.current !== null) {
      window.cancelAnimationFrame(focusReconcileFrameRef.current);
      focusReconcileFrameRef.current = null;
    }
  }, []);

  const clearRetainedFocus = useCallback(() => {
    retainedFocusRef.current = null;
    clearFocusReconcileFrame();
  }, [clearFocusReconcileFrame]);

  const cancelReveal = useCallback(() => {
    const reveal = revealRef.current;
    revealRef.current = null;
    reveal?.cancel();
  }, []);
  const isRevealingMessage = useCallback(() => revealRef.current !== null, []);
  const isFollowing = useCallback(
    () => stateRef.current.followMode === "following",
    []
  );

  // A layout write only. Semantic follow/intent state is changed by the callers.
  const syncBottom = useCallback(() => {
    const node = viewport();
    if (node) {
      const maxScrollTop = readMaxScrollTop(node);
      node.scrollTop = maxScrollTop;
    }
  }, [readMaxScrollTop, viewport]);

  const turnAnchorTarget = useCallback(
    (node: HTMLElement, turnKey: string, refresh = false) => {
      let anchored = anchoredTurnRef.current;
      if (
        anchored?.key !== turnKey ||
        !anchored.element.isConnected ||
        !node.contains(anchored.element)
      ) {
        const element = findTurnAnchor(node, turnKey);
        if (!element) return undefined;
        anchored = { element, key: turnKey, target: undefined };
        anchoredTurnRef.current = anchored;
      }

      if (refresh || anchored.target === undefined) {
        const viewportBox = node.getBoundingClientRect();
        const anchorBox = anchored.element.getBoundingClientRect();
        anchored.target = Math.max(
          0,
          node.scrollTop +
            anchorBox.top -
            viewportBox.top -
            readTurnTopInset(anchored.element, node)
        );
      }
      return Math.min(anchored.target, readMaxScrollTop(node));
    },
    [readMaxScrollTop]
  );

  const followingTarget = useCallback(
    (node: HTMLElement, refreshAnchor = false) => {
      const anchoredTurn = anchoredTurnRef.current;
      if (anchoredTurn) {
        const target = turnAnchorTarget(node, anchoredTurn.key, refreshAnchor);
        if (target !== undefined) return target;
        anchoredTurnRef.current = null;
      }

      const maxScrollTop = readMaxScrollTop(node);
      // An explicit ask for the tail outranks the newest-turn rule: overriding
      // it would drag the reader back up on the next streamed chunk, which is
      // exactly what they just asked to stop.
      if (bottomPinnedRef.current || followTarget === "bottom") return maxScrollTop;
      const newest = resolveNewestTurnRef.current();
      if (!newest) return maxScrollTop;
      return newestTurnTopTarget(node, newest, maxScrollTop);
    },
    [followTarget, readMaxScrollTop, turnAnchorTarget]
  );

  const clearInteraction = useCallback(() => {
    clearInteractionTimeout();
    stateRef.current.interaction = { kind: "idle" };
  }, [clearInteractionTimeout]);

  const commitDeferredUnseen = useCallback(() => {
    const state = stateRef.current;
    if (state.deferredUnseen === 0) {
      return;
    }
    const nextUnseen = state.unseen + state.deferredUnseen;
    state.deferredUnseen = 0;
    publishUnseen(nextUnseen);
  }, [publishUnseen]);

  const enterAway = useCallback(
    (preserveInteraction = false) => {
      const state = stateRef.current;
      state.followMode = "away";
      bottomPinnedRef.current = false;
      if (!preserveInteraction) {
        clearInteraction();
      }
      commitDeferredUnseen();
    },
    [clearInteraction, commitDeferredUnseen]
  );

  const stopFollowing = useCallback(() => {
    cancelReveal();
    anchoredTurnRef.current = null;
    clearRetainedFocus();
    enterAway();
  }, [cancelReveal, clearRetainedFocus, enterAway]);

  const revealElement = useCallback(
    (
      target: HTMLElement,
      content: HTMLElement,
      onRevealed: (scrolled: boolean) => void,
      {
        hasEarlierMessages = false,
        onCancel,
      }: { hasEarlierMessages?: boolean; onCancel?: (() => void) | undefined } = {}
    ) => {
      const node = viewport();
      if (!node?.contains(target)) return false;
      stopFollowing();
      const view = node.getBoundingClientRect();
      const box = content.getBoundingClientRect();
      const inset = 24; // Clear the transcript's edge masks and composer edge.
      const requestedTop = node.scrollTop + box.top - view.top - inset;
      // A clipped history prefix is not the start of the conversation. Mount
      // its context before scrolling instead of clamping against that boundary.
      if (requestedTop < 0 && hasEarlierMessages) return false;

      // This focus transfers keyboard navigation, not scroll ownership. The
      // ordinary focus keeper would snap an offscreen target into view before
      // smooth scrolling starts (and oscillate for a viewport-tall message).
      revealFocusRef.current = target;
      target.tabIndex = -1;
      target.focus({ preventScroll: true });
      revealFocusRef.current = null;

      // Align every explicit reply jump to the same reading inset, including
      // targets already visible farther down the viewport.
      let top = Math.min(readMaxScrollTop(node), Math.max(0, requestedTop));
      if (Math.abs(top - node.scrollTop) <= BOTTOM_EPSILON_PX) {
        onRevealed(false);
        return true;
      }
      const behavior = isReducedMotionEnabled() ? "instant" : "smooth";

      // One native scroll and one completion listener per explicit reveal.
      // Gestures, another reveal, normal focus, and unmount cancel both.
      let finishFrame: number | null = null;
      const finish = () => {
        // A prefix restore can queue scrollend before this smooth scroll starts.
        // It must not release navigation ownership or flash the target early.
        if (Math.abs(node.scrollTop - top) > BOTTOM_EPSILON_PX) return;
        if (finishFrame !== null) return;
        // Let the commit's Markdown layout settle, including an instant reveal
        // under reduced motion, before releasing the resize correction.
        finishFrame = window.requestAnimationFrame(() => {
          finishFrame = null;
          revealRef.current?.reconcile();
          if (Math.abs(node.scrollTop - top) > BOTTOM_EPSILON_PX) return;
          node.removeEventListener("scrollend", finish);
          revealRef.current = null;
          if (target.isConnected) onRevealed(true);
          else onCancel?.();
        });
      };
      revealRef.current = {
        cancel: () => {
          if (finishFrame !== null) window.cancelAnimationFrame(finishFrame);
          node.removeEventListener("scrollend", finish);
          node.scrollTo({ top: node.scrollTop, behavior: "instant" });
          onCancel?.();
        },
        reconcile: () => {
          // Newly mounted Markdown can grow before the scroll finishes. Use
          // ScrollArea's shared resize notification to keep the destination
          // attached to the message, without another observer or polling loop.
          const nextView = node.getBoundingClientRect();
          const nextBox = content.getBoundingClientRect();
          const nextTop = Math.min(
            readMaxScrollTop(node),
            Math.max(0, node.scrollTop + nextBox.top - nextView.top - inset)
          );
          if (Math.abs(nextTop - top) > BOTTOM_EPSILON_PX) {
            top = nextTop;
            node.scrollTo({ top, behavior });
          }
        },
      };
      node.addEventListener("scrollend", finish);
      node.scrollTo({ top, behavior });
      return true;
    },
    [readMaxScrollTop, stopFollowing, viewport]
  );

  const followDuringInteraction = useCallback(() => {
    const state = stateRef.current;
    state.followMode = "following";
    bottomPinnedRef.current = true;
    state.deferredUnseen = 0;
    publishUnseen(0);
  }, [publishUnseen]);

  const forceFollow = useCallback(
    (pinBottom = false) => {
      cancelReveal();
      anchoredTurnRef.current = null;
      bottomPinnedRef.current = pinBottom;
      clearInteraction();
      clearRetainedFocus();
      stateRef.current = {
        deferredUnseen: 0,
        followMode: "following",
        interaction: { kind: "idle" },
        unseen: 0,
      };
      publishUnseen(0);
      syncBottom();
    },
    [cancelReveal, clearInteraction, clearRetainedFocus, publishUnseen, syncBottom]
  );

  const pinToBottom = useCallback(() => forceFollow(true), [forceFollow]);

  /**
   * Put a turn at the top of the scrollport.
   *
   * `follow` says what the reader meant by it. Anchoring the turn they just
   * sent keeps them on the conversation, so the tail still pulls them along.
   * Jumping back to an older turn is the opposite errand — they went to read
   * something — and answering it with "following" hands the live run the right
   * to drag them out of it again. That reading stands until they ask for the
   * tail, by scrolling to it or pressing the unseen pill; until then a new
   * message announces itself and stays where it is.
   */
  const anchorTurn = useCallback(
    (turnKey: string, { follow = true }: { follow?: boolean } = {}) => {
      cancelReveal();
      // IM surfaces follow the newest bubble, including a just-sent message.
      // Explicit history reveals still place their requested turn at the top.
      if (follow && followTarget === "bottom") {
        forceFollow(true);
        return;
      }
      const node = viewport();
      if (!node) return;

      const target = turnAnchorTarget(node, turnKey);
      if (target === undefined) {
        // A turn we cannot find is a jump we cannot make. Falling to the tail
        // is right when the tail was the errand; when the reader asked for
        // history it would strand them exactly where they left.
        if (follow) forceFollow();
        return;
      }

      clearInteraction();
      clearRetainedFocus();
      bottomPinnedRef.current = false;
      stateRef.current = {
        deferredUnseen: 0,
        followMode: follow ? "following" : "away",
        interaction: { kind: "idle" },
        unseen: 0,
      };
      publishUnseen(0);
      node.scrollTop = target;
    },
    [
      cancelReveal,
      clearInteraction,
      clearRetainedFocus,
      followTarget,
      forceFollow,
      publishUnseen,
      turnAnchorTarget,
      viewport,
    ]
  );

  const ensureFocusedTargetVisible = useCallback(() => {
    const node = viewport();
    const target = retainedFocusRef.current;
    const activeElement = document.activeElement;
    if (
      !node ||
      !target ||
      !node.contains(target) ||
      !(target === activeElement || target.contains(activeElement))
    ) {
      retainedFocusRef.current = null;
      return false;
    }

    const viewportRect = node.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    if (targetRect.top < viewportRect.top) {
      node.scrollTop = Math.max(
        0,
        node.scrollTop - (viewportRect.top - targetRect.top)
      );
    } else if (targetRect.bottom > viewportRect.bottom) {
      node.scrollTop += targetRect.bottom - viewportRect.bottom;
    }
    return true;
  }, [viewport]);

  const followingWouldHideFocusedTarget = useCallback(
    (node: HTMLElement, targetScrollTop: number) => {
      const target = retainedFocusRef.current;
      const activeElement = document.activeElement;
      if (
        !target ||
        target === node ||
        !node.contains(target) ||
        !(target === activeElement || target.contains(activeElement))
      ) {
        retainedFocusRef.current = null;
        return false;
      }

      const geometry = measureScrollPosition(node);
      const projectedScrollDelta = targetScrollTop - geometry.scrollTop;
      const viewportRect = node.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      return (
        targetRect.top - projectedScrollDelta < viewportRect.top ||
        targetRect.bottom - projectedScrollDelta > viewportRect.bottom
      );
    },
    [measureScrollPosition]
  );

  const reconcileRetainedFocus = useCallback(() => {
    focusReconcileFrameRef.current = null;
    if (stateRef.current.followMode === "away") {
      ensureFocusedTargetVisible();
    }
  }, [ensureFocusedTargetVisible]);

  const reconcileFollowingLayout = useCallback(
    (refreshAnchor = false) => {
      const node = viewport();
      if (!node) return true;
      const target = followingTarget(node, refreshAnchor);
      if (followingWouldHideFocusedTarget(node, target)) {
        enterAway();
        ensureFocusedTargetVisible();
        return false;
      }

      node.scrollTop = target;
      return true;
    },
    [
      ensureFocusedTargetVisible,
      enterAway,
      followingTarget,
      followingWouldHideFocusedTarget,
      viewport,
    ]
  );

  const settleInteraction = useCallback(
    (interactionId: number) => {
      const state = stateRef.current;
      if (state.interaction.kind === "idle" || state.interaction.id !== interactionId) {
        return;
      }

      interactionTimeoutRef.current = null;
      state.interaction = { kind: "idle" };
      if (state.followMode === "following") {
        if (reconcileFollowingLayout()) {
          state.deferredUnseen = 0;
          publishUnseen(0);
        }
      } else {
        commitDeferredUnseen();
      }
    },
    [commitDeferredUnseen, publishUnseen, reconcileFollowingLayout]
  );

  const scheduleInteractionSettlement = useCallback(
    (interactionId: number) => {
      clearInteractionTimeout();
      interactionTimeoutRef.current = window.setTimeout(
        () => settleInteraction(interactionId),
        INTERACTION_SETTLE_MS
      );
    },
    [clearInteractionTimeout, settleInteraction]
  );

  const handleScrollIntent = useCallback(
    (direction: ScrollIntentDirection = "away") => {
      cancelReveal();
      const node = viewport();
      if (!node) {
        return;
      }

      anchoredTurnRef.current = null;
      clearRetainedFocus();
      if (maxScrollTopRef.current === 0) {
        // ConversationThread captures intent as the wheel arrives, before
        // anything has touched styles for it (the browser scrolls the wheel
        // itself), so an unseeded cache can be read here without forcing a
        // post-style-change layout on the hot path.
        readMaxScrollTop(node);
      }
      const geometry = measureScrollPosition(node);

      if (direction === "away") {
        if (geometry.maxScrollTop <= BOTTOM_EPSILON_PX) {
          return;
        }
        if (stateRef.current.followMode === "away" || !isAtBottom(geometry)) {
          enterAway();
          return;
        }

        clearInteraction();
        const interactionId = nextInteractionIdRef.current++;
        stateRef.current.interaction = {
          id: interactionId,
          kind: "away",
          lastScrollTop: geometry.scrollTop,
        };
        scheduleInteractionSettlement(interactionId);
        return;
      }

      if (isAtBottom(geometry)) {
        forceFollow(true);
        return;
      }

      // Following can hold a long reply at its top, above the actual bottom.
      // Let the reader move down without restoring that anchor after settlement.
      enterAway();
      const interactionId = nextInteractionIdRef.current++;
      stateRef.current.interaction = {
        id: interactionId,
        kind: "toward",
        lastScrollTop: geometry.scrollTop,
      };
      scheduleInteractionSettlement(interactionId);
    },
    [
      cancelReveal,
      clearInteraction,
      clearRetainedFocus,
      enterAway,
      forceFollow,
      isAtBottom,
      measureScrollPosition,
      readMaxScrollTop,
      scheduleInteractionSettlement,
      viewport,
    ]
  );

  const handleScrollGestureStart = useCallback(() => {
    cancelReveal();
    const node = viewport();
    if (!node) {
      return;
    }

    anchoredTurnRef.current = null;
    clearRetainedFocus();
    clearInteraction();
    stateRef.current.interaction = {
      id: nextInteractionIdRef.current++,
      kind: "continuous",
      lastScrollTop: node.scrollTop,
    };
  }, [cancelReveal, clearInteraction, clearRetainedFocus, viewport]);

  const handleScrollGestureEnd = useCallback(() => {
    const interaction = stateRef.current.interaction;
    if (interaction.kind !== "continuous") {
      return;
    }

    stateRef.current.interaction = {
      ...interaction,
      kind: "settling",
    };
    scheduleInteractionSettlement(interaction.id);
  }, [scheduleInteractionSettlement]);

  const commitScrollGeometry = useCallback(
    (geometry: ScrollGeometry) => {
      const node = viewport();
      if (!node) {
        return;
      }

      const state = stateRef.current;
      const interaction = state.interaction;
      if (
        maxScrollTopRef.current === 0 &&
        interaction.kind === "idle" &&
        state.followMode === "following"
      ) {
        // Initial/programmatic scrolls have no preceding intent event. Resolve
        // their geometry outside the user-scroll hot path and seed the cache.
        reconcileFollowingLayout();
        return;
      }
      if (
        interaction.kind === "away" ||
        interaction.kind === "continuous" ||
        interaction.kind === "settling"
      ) {
        if (Math.abs(geometry.scrollTop - interaction.lastScrollTop) <= 1) {
          return;
        }
        interaction.lastScrollTop = geometry.scrollTop;
        if (isAtBottom(geometry)) {
          if (interaction.kind !== "away") {
            followDuringInteraction();
          }
        } else {
          enterAway(true);
        }
        return;
      }

      if (interaction.kind === "toward") {
        interaction.lastScrollTop = geometry.scrollTop;
        if (isAtBottom(geometry)) {
          forceFollow(true);
        }
        return;
      }

      if (state.followMode === "following") {
        if (!isAtBottom(geometry)) {
          reconcileFollowingLayout();
        } else if (state.unseen !== 0) {
          publishUnseen(0);
        }
        return;
      }

      ensureFocusedTargetVisible();
    },
    [
      ensureFocusedTargetVisible,
      enterAway,
      followDuringInteraction,
      forceFollow,
      isAtBottom,
      publishUnseen,
      reconcileFollowingLayout,
      viewport,
    ]
  );

  const handleScroll = useCallback(() => {
    const node = viewport();
    if (!node) return;
    commitScrollGeometry(measureScrollPosition(node));
  }, [commitScrollGeometry, measureScrollPosition, viewport]);

  const handleScrollMetrics = useCallback(
    (metrics: { maxScrollTop: number; scrollTop: number }) => {
      const maxScrollTop = Math.max(0, metrics.maxScrollTop);
      maxScrollTopRef.current = maxScrollTop;
      commitScrollGeometry({
        distanceFromBottom: Math.max(0, maxScrollTop - metrics.scrollTop),
        maxScrollTop,
        scrollTop: metrics.scrollTop,
      });
    },
    [commitScrollGeometry]
  );

  const handleFocusChange = useCallback(
    (target: Element | null) => {
      if (target && target === revealFocusRef.current) return;
      cancelReveal();
      const node = viewport();
      if (!node || !target) {
        return;
      }

      anchoredTurnRef.current = null;
      const geometry = measure(node);
      const viewportRect = node.getBoundingClientRect();
      const targetRect = target.getBoundingClientRect();
      const targetIsOutsideViewport =
        targetRect.top < viewportRect.top || targetRect.bottom > viewportRect.bottom;
      if (
        stateRef.current.followMode === "following" &&
        isAtBottom(geometry) &&
        !targetIsOutsideViewport
      ) {
        clearFocusReconcileFrame();
        retainedFocusRef.current = target;
        return;
      }

      clearInteraction();
      retainedFocusRef.current = target;
      enterAway();
      ensureFocusedTargetVisible();
      clearFocusReconcileFrame();
      focusReconcileFrameRef.current =
        window.requestAnimationFrame(reconcileRetainedFocus);
    },
    [
      cancelReveal,
      clearFocusReconcileFrame,
      clearInteraction,
      ensureFocusedTargetVisible,
      enterAway,
      isAtBottom,
      measure,
      reconcileRetainedFocus,
      viewport,
    ]
  );

  const reconcilePassiveLayout = useCallback(
    (refreshAnchor = false) => {
      if (isCommaSurfacePaused(viewport())) return;
      const state = stateRef.current;
      if (state.followMode === "away") {
        ensureFocusedTargetVisible();
        return;
      }
      if (state.interaction.kind !== "idle") {
        return;
      }
      reconcileFollowingLayout(refreshAnchor);
    },
    [ensureFocusedTargetVisible, reconcileFollowingLayout, viewport]
  );
  const handleContentResize = useCallback(() => {
    const node = viewport();
    if (node) measure(node);
    revealRef.current?.reconcile();
    reconcilePassiveLayout(true);
  }, [measure, reconcilePassiveLayout, viewport]);
  const handleViewportResize = useCallback(() => {
    const node = viewport();
    if (node) measure(node);
    revealRef.current?.reconcile();
    reconcilePassiveLayout(true);
  }, [measure, reconcilePassiveLayout, viewport]);

  useLayoutEffect(() => {
    if (!initializedRef.current) {
      initializedRef.current = true;
      forceFollow();
      const frame = window.requestAnimationFrame(() => {
        const state = stateRef.current;
        if (state.followMode === "following" && state.interaction.kind === "idle") {
          syncBottom();
        }
      });
      return () => window.cancelAnimationFrame(frame);
    }

    const forceKey = options.forceKey;
    const anchorKey = options.anchorKey;
    const dependencyChanged = previousDependencyKey.current !== dependencyKey;
    const forceChanged = previousForceKey.current !== forceKey;
    const anchorChanged = previousAnchorKey.current !== anchorKey;

    if (!dependencyChanged && !forceChanged && !anchorChanged) {
      return;
    }

    previousDependencyKey.current = dependencyKey;
    previousForceKey.current = forceKey;
    previousAnchorKey.current = anchorKey;
    if (anchorChanged && anchorKey) {
      anchorTurn(anchorKey);
      return;
    }
    if (forceChanged && forceKey) {
      anchorTurn(forceKey);
      return;
    }

    const state = stateRef.current;
    if (state.followMode === "away") {
      publishUnseen(state.unseen + 1);
      return;
    }
    if (state.interaction.kind !== "idle") {
      state.deferredUnseen += 1;
      return;
    }
    if (!reconcileFollowingLayout()) {
      publishUnseen(stateRef.current.unseen + 1);
    }
  }, [
    dependencyKey,
    anchorTurn,
    forceFollow,
    options.anchorKey,
    options.forceKey,
    publishUnseen,
    reconcileFollowingLayout,
    syncBottom,
  ]);

  useLayoutEffect(() => {
    const finishContinuousInteraction = () => handleScrollGestureEnd();
    const finishPointerInteraction = (event: PointerEvent) => {
      // Native touch panning cancels its PointerEvent stream while Touch Events
      // and scrolling continue under the still-held finger.
      if (event.type === "pointercancel" && event.pointerType === "touch") {
        return;
      }
      finishContinuousInteraction();
    };
    window.addEventListener("pointerup", finishPointerInteraction);
    window.addEventListener("pointercancel", finishPointerInteraction);
    window.addEventListener("touchend", finishContinuousInteraction);
    window.addEventListener("touchcancel", finishContinuousInteraction);
    window.addEventListener("blur", finishContinuousInteraction);

    return () => {
      window.removeEventListener("pointerup", finishPointerInteraction);
      window.removeEventListener("pointercancel", finishPointerInteraction);
      window.removeEventListener("touchend", finishContinuousInteraction);
      window.removeEventListener("touchcancel", finishContinuousInteraction);
      window.removeEventListener("blur", finishContinuousInteraction);
    };
  }, [handleScrollGestureEnd]);

  useLayoutEffect(
    () => () => {
      cancelReveal();
      clearInteractionTimeout();
      clearFocusReconcileFrame();
      retainedFocusRef.current = null;
    },
    [cancelReveal, clearFocusReconcileFrame, clearInteractionTimeout]
  );

  return {
    anchorTurn,
    handleContentResize,
    handleFocusChange,
    handleScroll,
    handleScrollMetrics,
    handleScrollGestureStart,
    handleScrollIntent,
    handleViewportResize,
    isFollowing,
    isRevealingMessage,
    revealElement,
    scrollRootRef: rootRef,
    scrollToBottom: pinToBottom,
    stopFollowing,
    unseenCount,
  };
}

/**
 * Where following lands when no turn is explicitly anchored — typing in the
 * composer drops the anchor, so this is the ordinary post-send state.
 *
 * Pinning the bottom and resting the newest turn's top on the reading inset
 * name the same scroll position while that turn fits the viewport, which is
 * what its reserved `viewport - inset` height guarantees. Past that they
 * diverge, and pinning the bottom wins by however much the turn overflows —
 * so unfolding anything inside it (an image group, a clamped message) yanks
 * its top, and the timestamp above it, off screen. Hold the top instead and
 * let the unfolded content grow downward.
 */
function newestTurnTopTarget(
  node: HTMLElement,
  newest: HTMLElement,
  maxScrollTop: number
) {
  const documentTop =
    node.scrollTop +
    newest.getBoundingClientRect().top -
    node.getBoundingClientRect().top;
  return Math.min(
    Math.max(0, documentTop - readTurnTopInset(newest, node)),
    maxScrollTop
  );
}

function findTurnAnchor(node: HTMLElement, turnKey: string) {
  return Array.from(
    node.querySelectorAll<HTMLElement>("[data-chat-turn-anchor][data-turn-key]")
  ).find((candidate) => candidate.dataset.turnKey === turnKey);
}

function readTurnTopInset(anchor: HTMLElement, viewport: HTMLElement) {
  const propertyOwner = anchor.closest<HTMLElement>(".comma-chat-thread") ?? viewport;
  const value = Number.parseFloat(
    getComputedStyle(propertyOwner).getPropertyValue(TURN_TOP_INSET_PROPERTY)
  );
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
