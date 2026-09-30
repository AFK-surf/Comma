import type { RefObject } from "react";
import type { CommaApiClient } from "../../../../api";
import type { ChatAssistantDraft } from "../../model/conversationChannel";
import { useStickToBottom } from "../scroll/useStickToBottom";
import type { TranscriptLayout } from "../layout/useTranscriptLayout";
import type { PendingHistoryReveal } from "../replies/useReplyHistory";
import type { AnchoredTail } from "../turns/useAnchoredTails";
import { useThreadTurnWindow } from "./useThreadTurnWindow";
import { useTurnReveal, type RevealTurnHandle } from "./useTurnReveal";

/** Following the tail, mounting the window of turns around it, and revealing one. */
export function useThreadNavigation({
  anchoredTails,
  api,
  assistantDraft,
  assistantResponseSlotId,
  historyReveal,
  historyScope,
  layout: {
    canonicalLayout,
    conversationTurns,
    forceStickKey,
    latestTurnKey,
    messageKey,
    outgoing,
    pendingUserMessage,
  },
  resolveNewestTurn,
  revealTurnHandle,
  variant,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  api: CommaApiClient | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  historyReveal: RefObject<PendingHistoryReveal | null>;
  historyScope: string;
  layout: TranscriptLayout;
  resolveNewestTurn: () => HTMLElement | null;
  revealTurnHandle: RevealTurnHandle | undefined;
  variant: "default" | "side-chat";
}) {
  const follow = useStickToBottom(messageKey, {
    anchorKey: latestTurnKey,
    forceKey: forceStickKey,
    // Agent-only histories have no user turn to anchor. Open at their latest
    // message, using the same rule for Task and Home transcripts.
    followTarget:
      variant === "side-chat" ||
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
    follow,
    outgoing,
    pendingUserMessage,
  });
  const revealTurn = useTurnReveal({
    api,
    canonicalLayout,
    follow,
    historyReveal,
    historyScope,
    revealTurnHandle,
    turnWindow,
  });
  return { follow, revealTurn, turnWindow };
}
