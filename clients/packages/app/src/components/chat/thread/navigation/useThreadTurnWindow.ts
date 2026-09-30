import { useCallback, useLayoutEffect, useMemo, useRef } from "react";
import type { ChatAssistantDraft, ChatMessage } from "../../model/conversationChannel";
import {
  conversationWindowUnits,
  visibleConversationTurns,
  CONVERSATION_TURN_WINDOW,
} from "./conversationTurnWindow";
import { useConversationTurnWindow } from "./useConversationTurnWindow";
import type { useStickToBottom } from "../scroll/useStickToBottom";
import { conversationMessageTurnKey as messageTurnKey } from "../../model/visibleReplyPresentation";
import {
  appendAssistantDraft,
  type ConversationLayout,
} from "../layout/conversationLayout";
import type { OutgoingPresentations } from "../outgoing/useOutgoingPresentations";
import type { AnchoredTail } from "../turns/useAnchoredTails";

type Follow = ReturnType<typeof useStickToBottom>;

export type ThreadTurnWindow = ReturnType<typeof useThreadTurnWindow>;

export function useThreadTurnWindow({
  anchoredTails,
  assistantDraft,
  assistantResponseSlotId,
  canonicalLayout,
  follow: { isFollowing, isRevealingMessage, scrollRootRef },
  outgoing: { outgoingPresentations, outgoingTurnKeys },
  pendingUserMessage,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  canonicalLayout: ConversationLayout;
  follow: Pick<Follow, "isFollowing" | "isRevealingMessage" | "scrollRootRef">;
  outgoing: Pick<OutgoingPresentations, "outgoingPresentations" | "outgoingTurnKeys">;
  pendingUserMessage: ChatMessage | undefined;
}) {
  const hasAssistantDraft = Boolean(assistantDraft);
  const windowUnits = useMemo(
    () => conversationWindowUnits(canonicalLayout.turns),
    [canonicalLayout]
  );
  const windowKeyByMessage = useMemo(() => {
    const keys = new Map<string, string>();
    for (const unit of windowUnits) {
      for (const entry of canonicalLayout.turns[unit.turnIndex]!.entries.slice(
        unit.entryIndex,
        unit.entryIndex + CONVERSATION_TURN_WINDOW.maxEntriesPerUnit
      )) {
        if (entry.message) keys.set(entry.message.messageId, unit.key);
      }
    }
    return keys;
  }, [canonicalLayout, windowUnits]);
  const turnKeys = useMemo(() => {
    const keys = windowUnits.map((unit) => unit.key);
    return keys.length === 0 && hasAssistantDraft
      ? [`non-user:${assistantResponseSlotId}`]
      : keys;
  }, [assistantResponseSlotId, windowUnits, hasAssistantDraft]);
  const requiredTurnKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const key of outgoingTurnKeys) keys.add(key);
    if (pendingUserMessage) keys.add(messageTurnKey(pendingUserMessage));
    for (const tail of anchoredTails ?? []) {
      // A tail belongs after its message, not after an unbounded history prefix.
      const key = tail.messageId
        ? windowKeyByMessage.get(tail.messageId)
        : turnKeys.at(-1);
      if (key) keys.add(key);
    }
    return keys;
  }, [
    anchoredTails,
    windowKeyByMessage,
    turnKeys,
    outgoingTurnKeys,
    pendingUserMessage,
  ]);
  const getWindowViewport = useCallback(() => {
    const root = scrollRootRef.current;
    if (root?.getAttribute("data-slot") === "scroll-area-viewport") {
      return root;
    }
    return (
      root?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]') ?? null
    );
  }, [scrollRootRef]);
  const {
    hasOlder,
    hiddenOlderCount,
    reconcileViewport: reconcileWindowViewport,
    revealTurn: revealWindowTurn,
    visibleStart,
  } = useConversationTurnWindow({
    getViewport: getWindowViewport,
    requiredTurnKeys,
    turnKeys,
  });
  const reconcileViewport = useCallback(
    (metrics?: Parameters<typeof reconcileWindowViewport>[0], fillViewport = false) => {
      // A growing outgoing slot can move the scroll range past the history
      // threshold. That is not a request to load older turns: mounting a prefix
      // mid-flight changes the destination and adds a second settling motion.
      // Reader scroll intent releases following, so history remains available.
      if (
        !isRevealingMessage() &&
        !(outgoingPresentations.length > 0 && isFollowing())
      ) {
        // Initial layout can report scrollTop=0 before following reaches the
        // tail. Only reader navigation can request older content. Underfilled
        // viewports still expand inside the shared window owner.
        reconcileWindowViewport(metrics, { allowOlder: !isFollowing(), fillViewport });
      }
    },
    [
      isFollowing,
      isRevealingMessage,
      outgoingPresentations.length,
      reconcileWindowViewport,
    ]
  );
  const hasMeasuredContentRef = useRef(false);
  const wasPresentingOutgoingRef = useRef(false);
  useLayoutEffect(() => {
    const wasPresenting = wasPresentingOutgoingRef.current;
    const isPresenting = outgoingPresentations.length > 0;
    wasPresentingOutgoingRef.current = isPresenting;
    // A viewport resize during the flight deferred filling. Recheck once the
    // outgoing owner releases it, even if the content did not resize again.
    if (wasPresenting && !isPresenting)
      reconcileViewport(undefined, hasMeasuredContentRef.current);
  }, [outgoingPresentations.length, reconcileViewport]);
  const visibleCanonicalTurns = useMemo(
    () => visibleConversationTurns(canonicalLayout.turns, windowUnits, visibleStart),
    [canonicalLayout, windowUnits, visibleStart]
  );
  // Only the turn that owns the draft is rebuilt for a revision. Every other
  // visible turn keeps its identity, including a first turn the window cut.
  const visibleTurns = useMemo(() => {
    if (!assistantDraft) return visibleCanonicalTurns;
    const hiddenTurnCount = canonicalLayout.turns.length - visibleCanonicalTurns.length;
    const tailTurnIndex = canonicalLayout.tailTurnIndex - hiddenTurnCount;
    // The owning turn is above the mount window, so the draft is not mounted.
    if (canonicalLayout.tailTurnIndex >= 0 && tailTurnIndex < 0) {
      return visibleCanonicalTurns;
    }
    return appendAssistantDraft(
      { turns: visibleCanonicalTurns, tailTurnIndex },
      assistantDraft,
      assistantResponseSlotId
    ).turns;
  }, [assistantDraft, assistantResponseSlotId, canonicalLayout, visibleCanonicalTurns]);
  return {
    getWindowViewport,
    hasMeasuredContentRef,
    hasOlder,
    hiddenOlderCount,
    reconcileViewport,
    revealWindowTurn,
    visibleCanonicalTurns,
    visibleStart,
    visibleTurns,
    windowKeyByMessage,
    windowUnits,
  };
}
