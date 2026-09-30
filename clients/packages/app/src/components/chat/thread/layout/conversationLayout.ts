import type { ChatAssistantDraft, ChatMessage } from "../../model/conversationChannel";
import {
  conversationMessageTurnKey as messageTurnKey,
  visibleReplyIdentityKey,
} from "../../model/visibleReplyPresentation";
import {
  conversationTimestampMessageIds,
  normalizeMessageTimestamp,
} from "./messageTimestamp";

/** The pseudo-turn an empty transcript renders; it hosts tail nodes too. */
export const emptyThreadTurnKey = "empty";

export type ConversationTurn = {
  entries: ConversationEntry[];
  key: string;
  timestamp?:
    | {
        createdAt: number;
        messageId: string;
      }
    | undefined;
};

export type ConversationEntry =
  | {
      key: string;
      kind: "message";
      message: ChatMessage;
    }
  | {
      draft?: ChatAssistantDraft | undefined;
      key: string;
      kind: "assistant-response";
      message?: ChatMessage | undefined;
    };

export type ConversationLayout = ReturnType<typeof buildConversationLayout>;

export function continuesTurnRole(
  previous: ConversationTurn | undefined,
  next: ConversationTurn
) {
  const last = previous?.entries.at(-1);
  const first = next.entries[0];
  return Boolean(
    last &&
    first &&
    !next.timestamp &&
    conversationEntryRole(last) === conversationEntryRole(first)
  );
}

function conversationEntryRole(entry: ConversationEntry) {
  return entry.kind === "assistant-response" ? "assistant" : entry.message.role;
}

export function partitionConversationTurns(
  messages: ChatMessage[],
  assistantDraft?: ChatAssistantDraft | undefined
) {
  return buildConversationLayout(messages, assistantDraft, "conversation").turns;
}

export function buildConversationLayout(
  messages: ChatMessage[],
  assistantDraft: ChatAssistantDraft | undefined,
  responseSlotId: string
) {
  const turns: ConversationTurn[] = [];
  const turnsByKey = new Map<string, ConversationTurn>();
  const timestampMessageIds = conversationTimestampMessageIds(messages);
  let currentSequentialTurn: ConversationTurn | undefined;
  let leadingNonUserTurn: ConversationTurn | undefined;

  const appendSourceLessNonUser = (entry: ConversationEntry) => {
    // Messages and transient Participant state are presented in transcript
    // order. A user row starts a turn; every following non-user row belongs to
    // that turn until the next user row. Agent-only task transcripts share one
    // leading turn.
    let owner = currentSequentialTurn ?? leadingNonUserTurn;
    if (!owner) {
      owner = { entries: [], key: `non-user:${responseSlotId}` };
      leadingNonUserTurn = owner;
      turns.push(owner);
      turnsByKey.set(owner.key, owner);
    }
    owner.entries.push(entry);
  };

  for (const message of messages) {
    if (message.role === "user") {
      const turnKey = messageTurnKey(message);
      let turn = turnsByKey.get(turnKey);
      if (turn) {
        turn.entries.unshift(messageEntry(message));
      } else {
        turn = { entries: [messageEntry(message)], key: turnKey };
        turns.push(turn);
        turnsByKey.set(turnKey, turn);
      }
      if (
        timestampMessageIds.has(message.messageId) &&
        normalizeMessageTimestamp(message.createdAt) !== undefined
      ) {
        turn.timestamp = {
          createdAt: message.createdAt!,
          messageId: message.messageId,
        };
      }
      currentSequentialTurn = turn;
      continue;
    }

    const responseEntry = canonicalResponseEntry(message);
    appendSourceLessNonUser(responseEntry ?? messageEntry(message));
  }

  const tailTurn = currentSequentialTurn ?? leadingNonUserTurn;
  const layout = {
    turns,
    tailTurnIndex: tailTurn ? turns.indexOf(tailTurn) : -1,
  };
  return assistantDraft
    ? appendAssistantDraft(layout, assistantDraft, responseSlotId)
    : layout;
}

export function appendAssistantDraft(
  layout: { turns: ConversationTurn[]; tailTurnIndex: number },
  draft: ChatAssistantDraft,
  responseSlotId: string
) {
  const entry: ConversationEntry = {
    draft,
    key: `assistant-live:${responseSlotId}:${visibleReplyIdentityKey(
      draft.responseKey,
      draft.sourceMessageIds
    )}`,
    kind: "assistant-response",
  };
  const turns = [...layout.turns];
  const owner = turns[layout.tailTurnIndex];
  if (owner) {
    turns[layout.tailTurnIndex] = { ...owner, entries: [...owner.entries, entry] };
  } else {
    turns.push({ entries: [entry], key: `non-user:${responseSlotId}` });
  }
  return { turns, tailTurnIndex: owner ? layout.tailTurnIndex : turns.length - 1 };
}

function canonicalResponseEntry(
  message: ChatMessage,
  key?: string | undefined
): Extract<ConversationEntry, { kind: "assistant-response" }> | undefined {
  if (message.role !== "assistant") {
    return undefined;
  }

  return {
    key: key ?? `message:${message.messageId}`,
    kind: "assistant-response",
    message,
  };
}

function messageEntry(
  message: ChatMessage
): Extract<ConversationEntry, { kind: "message" }> {
  return {
    key: `message:${
      message.role === "user" ? messageTurnKey(message) : message.messageId
    }`,
    kind: "message",
    message,
  };
}
