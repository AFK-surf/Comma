import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";
import {
  asksRouter,
  conversationMessageTurnKey as messageTurnKey,
  visibleReplyIdentityKey,
} from "@comma/core/chat";
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

/** The time a timestamp row above an entry shows; seconds or milliseconds. */
export type EntryTimestamp = { createdAt: number };

export type ConversationEntry =
  | {
      key: string;
      kind: "message";
      message: ChatMessage;
      timestamp?: EntryTimestamp | undefined;
    }
  | {
      draft?: ChatAssistantDraft | undefined;
      key: string;
      kind: "assistant-response";
      message?: ChatMessage | undefined;
      timestamp?: EntryTimestamp | undefined;
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
    last.message?.platformSource === first.message?.platformSource &&
    conversationEntryRole(last) === conversationEntryRole(first)
  );
}

/**
 * The newest timestamp, when it heads messages the agent sent on its own, the
 * user has asked nothing since, and `isNews` holds for one of the messages
 * under it: its message's id, or the draft's id while a draft that opens a
 * timestamp streams. Anything the user asks the Router, a Quick Chat
 * included, retires it.
 */
export function newestAgentTimestampId(
  turns: readonly ConversationTurn[],
  draft: { id: string; timestamped: boolean } | undefined,
  isNews: (id: string) => boolean
) {
  let news = draft ? isNews(draft.id) : false;
  if (draft?.timestamped) return news ? draft.id : undefined;
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const entries = turns[turnIndex]!.entries;
    for (let entryIndex = entries.length - 1; entryIndex >= 0; entryIndex -= 1) {
      const entry = entries[entryIndex]!;
      if (entry.message && asksRouter(entry.message)) return undefined;
      const id = entry.message?.messageId;
      if (id !== undefined && isNews(id)) news = true;
      if (entry.timestamp) return news ? id : undefined;
    }
  }
  return undefined;
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
    const timestamp =
      timestampMessageIds.has(message.messageId) &&
      normalizeMessageTimestamp(message.createdAt) !== undefined
        ? { createdAt: message.createdAt! }
        : undefined;
    if (message.role === "user") {
      const turnKey = messageTurnKey(message);
      const entry = { ...messageEntry(message), timestamp };
      let turn = turnsByKey.get(turnKey);
      if (turn) {
        turn.entries.unshift(entry);
      } else {
        turn = { entries: [entry], key: turnKey };
        turns.push(turn);
        turnsByKey.set(turnKey, turn);
      }
      if (timestamp) {
        turn.timestamp = { ...timestamp, messageId: message.messageId };
      }
      currentSequentialTurn = turn;
      continue;
    }

    const entry = canonicalResponseEntry(message) ?? messageEntry(message);
    appendSourceLessNonUser(timestamp ? { ...entry, timestamp } : entry);
  }

  const tailTurn = currentSequentialTurn ?? leadingNonUserTurn;
  const layout = {
    turns,
    tailTurnIndex: tailTurn ? turns.indexOf(tailTurn) : -1,
    userTurnIndexes: new Map(
      turns.flatMap((turn, turnIndex) =>
        turn.entries.flatMap((entry) =>
          entry.message?.role === "user"
            ? [[entry.message.messageId, turnIndex] as const]
            : []
        )
      )
    ),
  };
  return assistantDraft
    ? {
        ...layout,
        ...appendAssistantDraft(
          layout,
          assistantDraft,
          responseSlotId,
          assistantDraftTurnIndex(layout, assistantDraft)
        ),
      }
    : layout;
}

/** The turn a draft streams in: its source's, else the tail. */
export function assistantDraftTurnIndex(
  layout: {
    tailTurnIndex: number;
    userTurnIndexes: ReadonlyMap<string, number>;
  },
  draft: ChatAssistantDraft
) {
  for (let index = draft.sourceMessageIds.length - 1; index >= 0; index -= 1) {
    const owner = layout.userTurnIndexes.get(draft.sourceMessageIds[index]!);
    if (owner !== undefined) return owner;
  }
  return layout.tailTurnIndex;
}

export function appendAssistantDraft(
  layout: { turns: ConversationTurn[]; tailTurnIndex: number },
  draft: ChatAssistantDraft,
  responseSlotId: string,
  ownerTurnIndex = layout.tailTurnIndex,
  timestamp?: EntryTimestamp | undefined
) {
  const entry: ConversationEntry = {
    draft,
    key: `assistant-live:${responseSlotId}:${visibleReplyIdentityKey(
      draft.responseKey,
      draft.sourceMessageIds
    )}`,
    kind: "assistant-response",
    timestamp,
  };
  const turns = [...layout.turns];
  const owner = turns[ownerTurnIndex];
  if (owner) {
    turns[ownerTurnIndex] = { ...owner, entries: [...owner.entries, entry] };
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
