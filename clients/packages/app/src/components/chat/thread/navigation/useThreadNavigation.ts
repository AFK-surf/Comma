import type { RefObject } from "react";
import type { ChatAssistantDraft } from "@comma/core/chat";
import { useStickToBottom } from "../scroll/useStickToBottom";
import type { TranscriptLayout } from "../layout/useTranscriptLayout";
import type { PendingHistoryReveal } from "../replies/useReplyHistory";
import type { AnchoredTail } from "../turns/useAnchoredTails";
import { useThreadTurnWindow } from "./useThreadTurnWindow";
import { useTurnReveal, type RevealTurnHandle } from "./useTurnReveal";

/** Following the tail, mounting the window of turns around it, and revealing one. */
export function useThreadNavigation({
  anchoredTails,
  assistantDraft,
  assistantResponseSlotId,
  historyReveal,
  historyScope,
  layout: {
    canonicalLayout,
    conversationTurns,
    draftTimestamp,
    forceStickKey,
    lastTurnKey,
    messageKey,
    outgoing,
    pendingUserMessage,
  },
  resolveNewestTurn,
  revealTurnHandle,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  historyReveal: RefObject<PendingHistoryReveal | null>;
  historyScope: string;
  layout: TranscriptLayout;
  resolveNewestTurn: () => HTMLElement | null;
  revealTurnHandle: RevealTurnHandle | undefined;
}) {
  const follow = useStickToBottom(messageKey, {
    anchorKey: lastTurnKey,
    forceKey: forceStickKey,
    // Agent-only histories have no user turn to anchor. Open at their latest
    // message, using the same rule for Task and Home transcripts.
    followTarget:
      conversationTurns.at(-1)?.entries[0]?.message?.role !== "user"
        ? "bottom"
        : "newest-turn",
    resolveNewestTurn,
  });
  const turnWindow = useThreadTurnWindow({
    anchoredTails,
    assistantDraft,
    assistantResponseSlotId,
    canonicalLayout,
    draftTimestamp,
    follow,
    outgoing,
    pendingUserMessage,
  });
  const revealTurn = useTurnReveal({
    canonicalLayout,
    follow,
    historyReveal,
    historyScope,
    revealTurnHandle,
    turnWindow,
  });
  return { follow, revealTurn, turnWindow };
}
