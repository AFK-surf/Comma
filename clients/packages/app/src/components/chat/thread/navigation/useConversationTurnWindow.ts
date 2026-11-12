import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import {
  CONVERSATION_TURN_WINDOW,
  expandWindowStart,
  isPinnedToBottom,
  resolveWindowStart,
  restoredScrollTop,
  shouldFillTurnWindow,
  shouldLoadOlderTurns,
  shouldRearmOlderTurnLoad,
  startKeyAfterSlide,
  type ConversationTurnWindowMetrics,
} from "./conversationTurnWindow";
import { transcriptGlideOffset } from "../../motion/outgoingBubbleMotion";

type ScrollRestore = {
  anchor: HTMLElement | null;
  anchorOffset: number;
  previousHeight: number;
  previousTop: number;
};

type RevealRequest = {
  key: string;
  sequence: number;
};

/** Where `anchor` is laid out in `viewport`, without a send's glide offset. */
function anchorLayoutOffset(anchor: HTMLElement, viewport: HTMLElement) {
  return (
    anchor.getBoundingClientRect().top -
    transcriptGlideOffset(anchor) -
    viewport.getBoundingClientRect().top
  );
}

/** The conversation's messages before those the transcript holds, which the core reads (`chatView.older`). */
export type EarlierHistory = {
  available: boolean;
  /** The core is reading them; once it stops, the window looks again whether the reader is still at the top. */
  loading: boolean;
  load: (() => unknown) | undefined;
};

const noEarlierHistory: EarlierHistory = {
  available: false,
  loading: false,
  load: undefined,
};

export function useConversationTurnWindow({
  earlier = noEarlierHistory,
  getViewport,
  heldTurnKeys,
  requiredTurnKeys,
  turnKeys,
}: {
  earlier?: EarlierHistory | undefined;
  getViewport: () => HTMLElement | null;
  /**
   * Turns that hold a question for the reader. Each stays mounted like a
   * required turn; once released, the window keeps what it held.
   */
  heldTurnKeys?: ReadonlySet<string> | undefined;
  requiredTurnKeys?: ReadonlySet<string> | undefined;
  turnKeys: readonly string[];
}) {
  const [startKey, setStartKey] = useState<string | null>(null);
  const pinnedToBottomRef = useRef(true);
  const pendingRef = useRef(false);
  const loadArmedRef = useRef(true);
  const restoreRef = useRef<ScrollRestore | null>(null);
  const restoreFrameRef = useRef<CancelUiTimer | null>(null);
  const previousTailKeyRef = useRef<string | undefined>(undefined);
  const revealSequenceRef = useRef(0);
  const [revealRequest, setRevealRequest] = useState<RevealRequest | null>(null);

  useLayoutEffect(
    () => () => {
      if (restoreFrameRef.current !== null) restoreFrameRef.current();
    },
    []
  );

  const revealTurn = useCallback(
    (turnKey: string) => {
      if (!turnKeys.includes(turnKey)) return false;
      const viewport = getViewport();
      if (viewport) {
        const anchor = viewport.querySelector<HTMLElement>("article[data-message-id]");
        restoreRef.current = {
          anchor,
          anchorOffset: anchor ? anchorLayoutOffset(anchor, viewport) : 0,
          previousHeight: viewport.scrollHeight,
          previousTop: viewport.scrollTop,
        };
      }
      revealSequenceRef.current += 1;
      setRevealRequest({ key: turnKey, sequence: revealSequenceRef.current });
      return true;
    },
    [getViewport, turnKeys]
  );

  const effectiveRequiredTurnKeys = useMemo(() => {
    if (!revealRequest && !heldTurnKeys?.size) return requiredTurnKeys;
    const keys = new Set(requiredTurnKeys);
    for (const key of heldTurnKeys ?? []) keys.add(key);
    if (!revealRequest) return keys;
    keys.add(revealRequest.key);
    // Reuse one bounded history page above the target so it can land in the
    // reading area, including when it was just inside the mounted boundary.
    const precedingKey =
      turnKeys[
        Math.max(
          0,
          turnKeys.indexOf(revealRequest.key) - CONVERSATION_TURN_WINDOW.pageTurns
        )
      ];
    if (precedingKey) keys.add(precedingKey);
    return keys;
  }, [heldTurnKeys, requiredTurnKeys, revealRequest, turnKeys]);

  // A held turn released (the reader decided on its card) leaves what it
  // mounted in place: the reader may be on that turn. The start it held
  // becomes the window's own, as the reader's history load would, and a later
  // slide at the tail trims it.
  const [previousHeldTurnKeys, setPreviousHeldTurnKeys] = useState(heldTurnKeys);
  if (previousHeldTurnKeys !== heldTurnKeys) {
    setPreviousHeldTurnKeys(heldTurnKeys);
    const heldStart = resolveWindowStart({
      requiredTurnKeys: previousHeldTurnKeys,
      startKey,
      turnKeys,
    });
    const nextStart = resolveWindowStart({
      requiredTurnKeys: effectiveRequiredTurnKeys,
      startKey,
      turnKeys,
    });
    if (heldStart < nextStart) setStartKey(turnKeys[heldStart] ?? null);
  }

  // While the core reads earlier messages, the window keeps the turns it showed and leaves what comes in above them
  // unmounted until the reader goes on up. It holds them by their place before its last turn: earlier messages can
  // join its first turn (which then has another key) or come in as a new first turn under the same key.
  const [earlierHold, setEarlierHold] = useState<{
    lastKey: string;
    shown: number;
  } | null>(null);
  const [previousTurnKeys, setPreviousTurnKeys] = useState(turnKeys);
  if (previousTurnKeys !== turnKeys) {
    setPreviousTurnKeys(turnKeys);
    const last = earlierHold ? turnKeys.indexOf(earlierHold.lastKey) : -1;
    const heldKey =
      earlierHold && last >= 0
        ? (turnKeys[Math.max(0, last - earlierHold.shown + 1)] ?? null)
        : startKey;
    if (heldKey !== startKey) setStartKey(heldKey);
  }

  const visibleStart = useMemo(
    () =>
      resolveWindowStart({
        requiredTurnKeys: effectiveRequiredTurnKeys,
        startKey,
        turnKeys,
      }),
    [effectiveRequiredTurnKeys, startKey, turnKeys]
  );
  const hasOlder = visibleStart > 0;
  const hiddenOlderCount = visibleStart;

  const readMetrics = useCallback((): ConversationTurnWindowMetrics | null => {
    const viewport = getViewport();
    if (!viewport) return null;
    return {
      clientHeight: viewport.clientHeight,
      scrollHeight: viewport.scrollHeight,
      scrollTop: viewport.scrollTop,
    };
  }, [getViewport]);

  const commitStart = useCallback(
    (nextStart: number, restoreScroll: boolean) => {
      const nextKey = turnKeys[nextStart] ?? null;
      if (nextKey === startKey) return false;
      const viewport = getViewport();
      if (restoreScroll && viewport) {
        const anchor = viewport.querySelector<HTMLElement>("article[data-message-id]");
        restoreRef.current = {
          anchor,
          anchorOffset: anchor ? anchorLayoutOffset(anchor, viewport) : 0,
          previousHeight: viewport.scrollHeight,
          previousTop: viewport.scrollTop,
        };
      }
      pendingRef.current = true;
      setEarlierHold(null);
      setStartKey(nextKey);
      return true;
    },
    [getViewport, startKey, turnKeys]
  );

  const expandOlder = useCallback(
    (restoreScroll: boolean) => {
      if (pendingRef.current) return false;
      const currentStart = resolveWindowStart({
        requiredTurnKeys: effectiveRequiredTurnKeys,
        startKey,
        turnKeys,
      });
      const { expanded, start } = expandWindowStart(currentStart);
      if (expanded === 0) return false;
      return commitStart(start, restoreScroll);
    },
    [commitStart, effectiveRequiredTurnKeys, startKey, turnKeys]
  );

  const earlierRef = useRef(earlier);
  earlierRef.current = earlier;
  /**
   * Asks the core for the messages before those held, once the window shows every turn it has. The window holds its
   * start, so what comes in stays above it until the reader goes on up.
   */
  const loadEarlier = useCallback(() => {
    const { available, loading, load } = earlierRef.current;
    const lastKey = turnKeys.at(-1);
    if (visibleStart > 0 || !available || loading || !load || lastKey === undefined)
      return false;
    setEarlierHold({ lastKey, shown: turnKeys.length - visibleStart });
    void Promise.resolve()
      .then(load)
      .catch(() => undefined);
    return true;
  }, [turnKeys, visibleStart]);

  const reconcileViewport = useCallback(
    (
      providedMetrics?: ConversationTurnWindowMetrics,
      {
        allowOlder = true,
        fillViewport = false,
      }: { allowOlder?: boolean; fillViewport?: boolean } = {}
    ) => {
      const metrics = providedMetrics ?? readMetrics();
      if (!metrics) return;

      if (shouldRearmOlderTurnLoad(metrics)) {
        loadArmedRef.current = true;
      }

      const pinned = isPinnedToBottom(metrics);
      pinnedToBottomRef.current = pinned || !allowOlder;

      if (
        loadArmedRef.current &&
        allowOlder &&
        shouldLoadOlderTurns({
          hasOlder: hasOlder || earlierRef.current.available,
          metrics,
          pending: pendingRef.current,
          pinnedToBottom: pinned,
        })
      ) {
        if (expandOlder(true) || loadEarlier()) {
          loadArmedRef.current = false;
        }
        return;
      }

      if (
        fillViewport &&
        shouldFillTurnWindow({
          hasOlder,
          metrics,
          pending: pendingRef.current,
        })
      ) {
        expandOlder(false);
      }
    },
    [expandOlder, hasOlder, loadEarlier, readMetrics]
  );

  useLayoutEffect(() => {
    const tailKey = turnKeys.at(-1);
    const previousTailKey = previousTailKeyRef.current;
    previousTailKeyRef.current = tailKey;

    if (revealRequest) {
      if (turnKeys.includes(revealRequest.key)) {
        // The temporary requirement mounted the target for this commit. Hand
        // ownership to startKey before releasing it so the following render
        // keeps the same suffix without retaining an append-only reveal set.
        // Preserve an already-expanded prefix. Trimming it at the requested
        // turn would shift an on-screen target during the following commit.
        setStartKey(turnKeys[visibleStart] ?? null);
      }
      // A conversation switch can retire the requested key between the click
      // and commit. Drop that stale request too rather than retaining inert
      // reveal state for the lifetime of the next conversation.
      setRevealRequest((current) =>
        current?.sequence === revealRequest.sequence ? null : current
      );
    } else if (
      pinnedToBottomRef.current &&
      tailKey !== undefined &&
      previousTailKey !== undefined &&
      tailKey !== previousTailKey
    ) {
      const currentStart = resolveWindowStart({
        requiredTurnKeys: effectiveRequiredTurnKeys,
        startKey,
        turnKeys,
      });
      const nextKey = startKeyAfterSlide(turnKeys, currentStart);
      if (nextKey !== startKey) {
        restoreRef.current = null;
        setEarlierHold(null);
        setStartKey(nextKey);
      }
    }

    const restore = restoreRef.current;
    const viewport = getViewport();
    if (restore && viewport) {
      restoreRef.current = null;
      viewport.scrollTop = restore.anchor?.isConnected
        ? viewport.scrollTop +
          anchorLayoutOffset(restore.anchor, viewport) -
          restore.anchorOffset
        : restoredScrollTop(
            restore.previousTop,
            restore.previousHeight,
            viewport.scrollHeight
          );
      const restoredTop = viewport.scrollTop;
      if (restoreFrameRef.current !== null) restoreFrameRef.current();
      // Markdown children can finish their initial layout after this parent
      // effect. Reconcile once before paint, preserving any reader movement.
      // Explicit reply navigation owns its own target reconciliation.
      if (!revealRequest)
        restoreFrameRef.current = uiClock.frame(() => {
          restoreFrameRef.current = null;
          if (restore.anchor?.isConnected) {
            const readerMovement = viewport.scrollTop - restoredTop;
            viewport.scrollTop +=
              anchorLayoutOffset(restore.anchor, viewport) -
              restore.anchorOffset +
              readerMovement;
          }
        });
    }
    pendingRef.current = false;
  }, [
    effectiveRequiredTurnKeys,
    getViewport,
    revealRequest,
    startKey,
    turnKeys,
    visibleStart,
  ]);

  // After the window's own restore above, so a step up it takes from here restores the reader's place itself.
  // A read of earlier messages ended: a reader still at the top goes on up into what it brought, or asks for more
  // when it brought nothing the transcript shows.
  const wasLoadingEarlierRef = useRef(earlier.loading);
  useLayoutEffect(() => {
    const wasLoading = wasLoadingEarlierRef.current;
    wasLoadingEarlierRef.current = earlier.loading;
    if (!wasLoading || earlier.loading) return;
    setEarlierHold(null);
    loadArmedRef.current = true;
    reconcileViewport();
  }, [earlier.loading, reconcileViewport]);

  return {
    hasOlder,
    /** Messages lie above the window: unmounted turns, or earlier ones the core can read. */
    olderAbove: hasOlder || earlier.available,
    hiddenOlderCount,
    initialTurns: CONVERSATION_TURN_WINDOW.initialTurns,
    reconcileViewport,
    revealTurn,
    visibleStart,
  };
}
