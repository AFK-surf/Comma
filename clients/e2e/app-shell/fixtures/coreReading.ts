// What the client core sends with a conversation a fixture builds by hand: its reading of each message (a person's
// words, an agent's parsed Markdown), of the reply streaming in, and of where the next reply stands. A fixture page
// shows the UI what the core would.
import {
  decodeUserMessage,
  messageReading,
  replyState,
  type ChatAssistantDraft,
  type ChatMessage,
  type ConversationChannelState,
} from "@comma/core/chat";
import { draftMarkdown } from "@comma/core/markdown";

const readMessages = new WeakMap<ChatMessage, ChatMessage>();

export function readMessage(message: ChatMessage): ChatMessage {
  const kept = readMessages.get(message);
  if (kept) return kept;
  const read =
    message.role === "user"
      ? message.platformSource || message.display
        ? message
        : { ...message, display: decodeUserMessage(message.text) }
      : {
          ...message,
          ...messageReading({
            ...message,
            parts: message.parts ?? [{ kind: "markdown", text: message.text }],
          }),
          // A fixture's own parse stands.
          ...(message.markdown ? { markdown: message.markdown } : {}),
        };
  readMessages.set(message, read);
  return read;
}

export function readDraft(draft: ChatAssistantDraft): ChatAssistantDraft {
  return {
    ...draft,
    markdown: draftMarkdown(
      draft.draftId,
      draft.text,
      draft.status === "completed"
    ) as ChatAssistantDraft["markdown"],
  };
}

// A list the core read before is the same list, as the core keeps it while only a draft streams.
const readLists = new WeakMap<readonly ChatMessage[], ChatMessage[]>();

function readMessageList(messages: readonly ChatMessage[]): ChatMessage[] {
  const kept = readLists.get(messages);
  if (kept) return kept;
  const read = messages.map(readMessage);
  readLists.set(messages, read);
  return read;
}

export function readState(state: ConversationChannelState): ConversationChannelState {
  return {
    ...state,
    assistantDraft: state.assistantDraft && readDraft(state.assistantDraft),
    messages: readMessageList(state.messages),
    reply: replyState(state),
    serverMessages: readMessageList(state.serverMessages),
  };
}
