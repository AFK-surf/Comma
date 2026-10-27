import { useTopic } from "@comma/core-client";
import type { ChatSuggestion } from "@comma/core/contract";
import { useCallback, useState } from "react";
import type { ConversationViewState } from "../composer/conversationDraft";

const noSuggestions: readonly ChatSuggestion[] = [];

export type ChatSuggestionsState = {
  clear: () => void;
  items: readonly ChatSuggestion[];
};

/**
 * The core's follow-ups for the settled turn (`chatSuggestions`), asked once per turn and locale. A round in flight
 * hides them; one chosen or accepted (`clear`) hides that turn's until the next turn settles.
 */
export function useChatSuggestions({
  conversationId,
  enabled,
  groupId,
  locale,
  state,
}: {
  conversationId: string | undefined;
  enabled: boolean;
  groupId: string | undefined;
  locale: string;
  state: ConversationViewState;
}): ChatSuggestionsState {
  // A round in flight, in any of the forms the channel reports it. Suggestions
  // describe a finished turn, so any of these hides the ones on screen.
  const busy =
    state.assistantDraft !== undefined ||
    state.awaitingReply ||
    state.activity !== undefined ||
    state.pending.length > 0 ||
    state.participantStatus?.state === "active";

  const settledMessageId = busy
    ? undefined
    : state.messages.findLast((message) => message.role === "assistant")?.messageId;

  const asked = enabled && groupId && conversationId && settledMessageId;
  const key = asked ? `${conversationId} ${settledMessageId} ${locale}` : undefined;
  const [dismissed, setDismissed] = useState<string>();
  const { value } = useTopic(
    asked
      ? {
          topic: "chatSuggestions",
          group: groupId,
          conversation: conversationId,
          message: settledMessageId,
          locale,
        }
      : null
  );

  const clear = useCallback(() => setDismissed(key), [key]);

  return {
    clear,
    items: key && key !== dismissed && value ? value : noSuggestions,
  };
}
