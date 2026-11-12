import { useCallback, useLayoutEffect, useMemo, useRef } from "react";
import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";
import {
  conversationWindowUnits,
  visibleConversationTurns,
  CONVERSATION_TURN_WINDOW,
} from "./conversationTurnWindow";
import {
  useConversationTurnWindow,
  type EarlierHistory,
} from "./useConversationTurnWindow";
import type { useStickToBottom } from "../scroll/useStickToBottom";
import { conversationMessageTurnKey as messageTurnKey } from "@comma/core/chat";
import {
  appendAssistantDraft,
  assistantDraftTurnIndex,
  type ConversationLayout,
  type EntryTimestamp,
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
  draftTimestamp,
  earlier,
  follow: { isFollowing, isRevealingMessage, scrollRootRef },
  outgoing: { outgoingPresentations, outgoingTurnKeys },
  pendingUserMessage,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  canonicalLayout: ConversationLayout;
  draftTimestamp: EntryTimestamp | undefined;
  earlier: EarlierHistory;
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
    return keys;
  }, [outgoingTurnKeys, pendingUserMessage]);
  // Only a question holds its reply's turn mounted. A settled node shows when
  // the reader reaches that turn, like the rest of the history, and a node
  // with no reply is on the newest turn, which the window always holds.
  const heldTurnKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const tail of anchoredTails ?? []) {
      if (!tail.awaitsDecision || tail.messageId === undefined) continue;
      const key = windowKeyByMessage.get(tail.messageId);
      if (key) keys.add(key);
    }
    return keys;
  }, [anchoredTails, windowKeyByMessage]);
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
    olderAbove,
    reconcileViewport: reconcileWindowViewport,
    revealTurn: revealWindowTurn,
    visibleStart,
  } = useConversationTurnWindow({
    earlier,
    getViewport: getWindowViewport,
    heldTurnKeys,
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
    const ownerTurnIndex = assistantDraftTurnIndex(canonicalLayout, assistantDraft);
    const visibleOwnerTurnIndex = ownerTurnIndex - hiddenTurnCount;
    // The owning turn is above the mount window, so the draft is not mounted.
    if (ownerTurnIndex >= 0 && visibleOwnerTurnIndex < 0) {
      return visibleCanonicalTurns;
    }
    return appendAssistantDraft(
      {
        turns: visibleCanonicalTurns,
        tailTurnIndex: canonicalLayout.tailTurnIndex - hiddenTurnCount,
      },
      assistantDraft,
      assistantResponseSlotId,
      visibleOwnerTurnIndex,
      draftTimestamp
    ).turns;
  }, [
    assistantDraft,
    assistantResponseSlotId,
    canonicalLayout,
    draftTimestamp,
    visibleCanonicalTurns,
  ]);
  return {
    getWindowViewport,
    hasMeasuredContentRef,
    hasOlder,
    hiddenOlderCount,
    olderAbove,
    reconcileViewport,
    revealWindowTurn,
    visibleCanonicalTurns,
    visibleStart,
    visibleTurns,
    windowKeyByMessage,
    windowUnits,
  };
}
