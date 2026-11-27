import { useTopic } from "@comma/core-client";
import type { ChatMessage } from "@comma/core/chat";
import type { ChatSuggestion } from "@comma/core/contract";
import { useCallback, useState } from "react";
import type { ConversationViewState } from "../composer/conversationDraft";
import { TASK_RUN_BLOCKED } from "../tasks/taskRunSwitch";

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
  workerStarting = false,
}: {
  conversationId: string | undefined;
  enabled: boolean;
  groupId: string | undefined;
  locale: string;
  state: ConversationViewState;
  /** A started Task whose Worker has not reported yet (`workerStarting`). */
  workerStarting?: boolean | undefined;
}): ChatSuggestionsState {
  // A round in flight, in any of the forms the channel reports it. Suggestions
  // describe a finished turn, so any of these hides the ones on screen.
  const busy =
    workerStarting ||
    state.assistantDraft !== undefined ||
    state.awaitingReply ||
    state.activity !== undefined ||
    state.pending.length > 0 ||
    state.participantStatus?.state === "active" ||
    // In a Task: its Router or its Worker at work.
    state.participantStatuses?.some((participant) => participant.state === "active") ===
      true;

  const settledMessageId = busy ? undefined : settledReplyId(state.messages);

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

/**
 * The reply that ended the newest turn, when the newest message is one. A
 * person's message after it opens a turn that has not ended yet. A Task's
 * brief and a request the Router brought into it are instructions its Worker
 * starts from, and a system notice or a blocked run is no reply: follow-ups
 * under any of these read as steps the reader must take.
 */
function settledReplyId(messages: readonly ChatMessage[]): string | undefined {
  const newest = messages.at(-1);
  if (
    !newest ||
    newest.role !== "assistant" ||
    newest.actorType === "system" ||
    newest.brief ||
    newest.routerRequest ||
    newest.messageType === TASK_RUN_BLOCKED ||
    newest.parts?.some(
      (part) =>
        part.kind === "question" &&
        (part.state.status === "open" ||
          part.state.status === "sending" ||
          part.state.status === "failed")
    )
  ) {
    return undefined;
  }
  return newest.messageId;
}
