import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
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

export function useConversationTurnWindow({
  getViewport,
  requiredTurnKeys,
  turnKeys,
}: {
  getViewport: () => HTMLElement | null;
  requiredTurnKeys?: ReadonlySet<string> | undefined;
  turnKeys: readonly string[];
}) {
  const [startKey, setStartKey] = useState<string | null>(null);
  const pinnedToBottomRef = useRef(true);
  const pendingRef = useRef(false);
  const loadArmedRef = useRef(true);
  const restoreRef = useRef<ScrollRestore | null>(null);
  const restoreFrameRef = useRef<number | null>(null);
  const previousTailKeyRef = useRef<string | undefined>(undefined);
  const revealSequenceRef = useRef(0);
  const [revealRequest, setRevealRequest] = useState<RevealRequest | null>(null);

  useLayoutEffect(
    () => () => {
      if (restoreFrameRef.current !== null)
        cancelAnimationFrame(restoreFrameRef.current);
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
          anchorOffset: anchor
            ? anchor.getBoundingClientRect().top - viewport.getBoundingClientRect().top
            : 0,
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
    if (!revealRequest) return requiredTurnKeys;
    const keys = new Set(requiredTurnKeys);
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
  }, [requiredTurnKeys, revealRequest, turnKeys]);

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
          anchorOffset: anchor
            ? anchor.getBoundingClientRect().top - viewport.getBoundingClientRect().top
            : 0,
          previousHeight: viewport.scrollHeight,
          previousTop: viewport.scrollTop,
        };
      }
      pendingRef.current = true;
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
          hasOlder,
          metrics,
          pending: pendingRef.current,
          pinnedToBottom: pinned,
        })
      ) {
        if (expandOlder(true)) {
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
    [expandOlder, hasOlder, readMetrics]
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
        setStartKey(nextKey);
      }
    }

    const restore = restoreRef.current;
    const viewport = getViewport();
    if (restore && viewport) {
      restoreRef.current = null;
      viewport.scrollTop = restore.anchor?.isConnected
        ? viewport.scrollTop +
          restore.anchor.getBoundingClientRect().top -
          viewport.getBoundingClientRect().top -
          restore.anchorOffset
        : restoredScrollTop(
            restore.previousTop,
            restore.previousHeight,
            viewport.scrollHeight
          );
      const restoredTop = viewport.scrollTop;
      if (restoreFrameRef.current !== null)
        cancelAnimationFrame(restoreFrameRef.current);
      // Markdown children can finish their initial layout after this parent
      // effect. Reconcile once before paint, preserving any reader movement.
      // Explicit reply navigation owns its own target reconciliation.
      if (!revealRequest)
        restoreFrameRef.current = requestAnimationFrame(() => {
          restoreFrameRef.current = null;
          if (restore.anchor?.isConnected) {
            const readerMovement = viewport.scrollTop - restoredTop;
            viewport.scrollTop +=
              restore.anchor.getBoundingClientRect().top -
              viewport.getBoundingClientRect().top -
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

  return {
    hasOlder,
    hiddenOlderCount,
    initialTurns: CONVERSATION_TURN_WINDOW.initialTurns,
    reconcileViewport,
    revealTurn,
    visibleStart,
  };
}
