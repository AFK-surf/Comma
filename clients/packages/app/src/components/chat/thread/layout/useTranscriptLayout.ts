import { useMemo } from "react";
import type { ChatAssistantDraft, ChatMessage } from "../../model/conversationChannel";
import { conversationMessageTurnKey as messageTurnKey } from "../../model/visibleReplyPresentation";
import type { ChatOutgoingLaunch } from "../outgoing/outgoingPresentation";
import { useOutgoingPresentations } from "../outgoing/useOutgoingPresentations";
import { useAnchoredTails, type AnchoredTail } from "../turns/useAnchoredTails";
import {
  appendAssistantDraft,
  assistantDraftTurnIndex,
  buildConversationLayout,
} from "./conversationLayout";

export type TranscriptLayout = ReturnType<typeof useTranscriptLayout>;

export function useTranscriptLayout({
  anchoredTails,
  assistantDraft,
  assistantResponseSlotId,
  messages,
  outgoingLaunches,
  outgoingMatches,
  variant,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  messages: ChatMessage[];
  outgoingLaunches: readonly ChatOutgoingLaunch[];
  outgoingMatches: ReadonlyMap<number, string>;
  variant: "default" | "side-chat";
}) {
  // The turn layout and outgoing-presentation resolution are O(messages) with
  // per-turn allocations. The thread re-renders on every channel emit (each
  // keystroke and stream chunk), so this derived work must only re-run when
  // its actual inputs change.
  const messageKey = useMemo(
    () =>
      `${messages.map((message) => message.messageId).join("|")}:${assistantDraft?.draftId ?? ""}`,
    [assistantDraft?.draftId, messages]
  );
  const canonicalLayout = useMemo(
    () => buildConversationLayout(messages, undefined, assistantResponseSlotId),
    [assistantResponseSlotId, messages]
  );
  const conversationLayout = useMemo(
    () =>
      assistantDraft
        ? appendAssistantDraft(
            canonicalLayout,
            assistantDraft,
            assistantResponseSlotId,
            assistantDraftTurnIndex(canonicalLayout, assistantDraft)
          )
        : canonicalLayout,
    [assistantDraft, assistantResponseSlotId, canonicalLayout]
  );
  const conversationTurns = conversationLayout.turns;
  const outgoing = useOutgoingPresentations(
    outgoingLaunches,
    messages,
    outgoingMatches
  );
  const lastTurnKey = conversationTurns.at(-1)?.key;
  const latestTurnKey = variant === "default" ? lastTurnKey : undefined;
  const firstOutgoingTurnKey = outgoing.outgoingPresentations[0]?.turnKey;
  const pendingUserMessage = messages.findLast(
    (message) =>
      message.role === "user" &&
      message.source === "pending" &&
      message.delivery === "sending"
  );
  const forceStickKey =
    firstOutgoingTurnKey ??
    (pendingUserMessage ? messageTurnKey(pendingUserMessage) : undefined);
  const anchoredTailsFor = useAnchoredTails(
    anchoredTails,
    conversationTurns,
    lastTurnKey
  );
  return {
    anchoredTailsFor,
    canonicalLayout,
    conversationTurns,
    forceStickKey,
    lastTurnKey,
    latestTurnKey,
    messageKey,
    outgoing,
    pendingUserMessage,
  };
}
