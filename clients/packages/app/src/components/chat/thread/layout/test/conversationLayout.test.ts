import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";
import { describe, expect, it } from "vitest";
import {
  buildConversationLayout,
  newestAgentTimestampId,
  type ConversationTurn,
} from "../conversationLayout";

const at = (minutes: number) => Date.UTC(2026, 9, 13, 9) + minutes * 60_000;

const message = (
  messageId: string,
  role: ChatMessage["role"],
  minutes: number,
  messageType?: string
): ChatMessage =>
  ({
    createdAt: at(minutes),
    messageId,
    role,
    ...(messageType ? { messageType } : {}),
  }) as ChatMessage;

const turnsOf = (messages: ChatMessage[], draft?: ChatAssistantDraft) =>
  buildConversationLayout(messages, draft, "conversation").turns;

const shape = (turns: readonly ConversationTurn[]) =>
  turns.map((turn) => [turn.key, turn.entries.map((entry) => entry.key)]);

const live = expect.stringMatching(/^assistant-live:/);

const news =
  (...ids: string[]) =>
  (id: string) =>
    ids.includes(id);

describe("buildConversationLayout", () => {
  it("streams a reply under its own request when a later request, a Quick Chat included, came after it", () => {
    const asked = message("m1", "user", 0);
    const spoken = message("m2", "user", 1, "quick_chat");
    const draft: ChatAssistantDraft = {
      conversationId: "home",
      draftId: "d1",
      responseKey: "r1",
      sourceMessageIds: ["m1"],
      status: "streaming",
      text: "On it",
    };

    expect(shape(turnsOf([asked, spoken], draft))).toEqual([
      ["m1", ["message:m1", live]],
      ["m2", ["message:m2"]],
    ]);
    expect(shape(turnsOf([asked, message("m3", "user", 1)], draft))).toEqual([
      ["m1", ["message:m1", live]],
      ["m3", ["message:m3"]],
    ]);
    // A reply with no request of its own in the transcript streams at the tail.
    expect(
      shape(turnsOf([asked, spoken], { ...draft, sourceMessageIds: ["gone"] }))
    ).toEqual([
      ["m1", ["message:m1"]],
      ["m2", ["message:m2", live]],
    ]);
  });
});

describe("newestAgentTimestampId", () => {
  it("retires the New mark at a Quick Chat, as at any request, and times its reply with it", () => {
    const reminder = message("a1", "assistant", 0);
    const spoken = message("q", "user", 10, "quick_chat");

    // The reply to the Quick Chat shares its timestamp, however long it took.
    const answered = turnsOf([reminder, spoken, message("a2", "assistant", 50)]);
    expect(answered.at(-1)!.entries.at(-1)!.timestamp).toBeUndefined();
    expect(newestAgentTimestampId(answered, undefined, news("a2"))).toBeUndefined();
    // News from before the Quick Chat is retired by it.
    expect(
      newestAgentTimestampId(turnsOf([reminder, spoken]), undefined, news("a1"))
    ).toBeUndefined();
  });
});
