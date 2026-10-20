import { uiClock } from "@comma/ui/clock";
import { useMemo, useState } from "react";
import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";
import { conversationMessageTurnKey as messageTurnKey } from "@comma/core/chat";
import type { ChatOutgoingLaunch } from "../outgoing/outgoingPresentation";
import { useOutgoingPresentations } from "../outgoing/useOutgoingPresentations";
import { useAnchoredTails, type AnchoredTail } from "../turns/useAnchoredTails";
import {
  appendAssistantDraft,
  assistantDraftTurnIndex,
  buildConversationLayout,
  type EntryTimestamp,
} from "./conversationLayout";
import { agentMessageOpensTimestamp } from "./messageTimestamp";

export type TranscriptLayout = ReturnType<typeof useTranscriptLayout>;

export function useTranscriptLayout({
  anchoredTails,
  assistantDraft,
  assistantResponseSlotId,
  messages,
  outgoingLaunches,
  outgoingMatches,
}: {
  anchoredTails: readonly AnchoredTail[] | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  assistantResponseSlotId: string;
  messages: ChatMessage[];
  outgoingLaunches: readonly ChatOutgoingLaunch[];
  outgoingMatches: ReadonlyMap<number, string>;
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
  // A draft that opens a timestamp shows it from its first text, timed then,
  // so the row does not arrive above a reply the reader is already watching
  // when its message lands. The landed message is timed by its own createdAt.
  const [draftStamp, setDraftStamp] = useState<{
    draftId: string;
    timestamp: EntryTimestamp | undefined;
  }>();
  let currentDraftStamp = draftStamp;
  if (assistantDraft?.text.trim() && draftStamp?.draftId !== assistantDraft.draftId) {
    const shownAt = uiClock.now();
    const opens =
      assistantDraftTurnIndex(canonicalLayout, assistantDraft) ===
        canonicalLayout.tailTurnIndex &&
      agentMessageOpensTimestamp(shownAt, messages.at(-1));
    currentDraftStamp = {
      draftId: assistantDraft.draftId,
      timestamp: opens ? { createdAt: shownAt } : undefined,
    };
    setDraftStamp(currentDraftStamp);
  }
  const draftTimestamp =
    assistantDraft && currentDraftStamp?.draftId === assistantDraft.draftId
      ? currentDraftStamp.timestamp
      : undefined;
  const conversationLayout = useMemo(
    () =>
      assistantDraft
        ? appendAssistantDraft(
            canonicalLayout,
            assistantDraft,
            assistantResponseSlotId,
            assistantDraftTurnIndex(canonicalLayout, assistantDraft),
            draftTimestamp
          )
        : canonicalLayout,
    [assistantDraft, assistantResponseSlotId, canonicalLayout, draftTimestamp]
  );
  const conversationTurns = conversationLayout.turns;
  const outgoing = useOutgoingPresentations(
    outgoingLaunches,
    messages,
    outgoingMatches
  );
  const lastTurnKey = conversationTurns.at(-1)?.key;
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
    draftTimestamp,
    forceStickKey,
    lastTurnKey,
    messageKey,
    outgoing,
    pendingUserMessage,
  };
}
