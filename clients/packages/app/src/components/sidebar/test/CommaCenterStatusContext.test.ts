import { describe, expect, it } from "vitest";
import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";
import { replyState } from "@comma/core/chat";
import {
  advanceRouterReplyMark,
  deriveCommaCenterStatus,
} from "../CommaCenterStatusContext";

type StatusInput = Pick<
  ConversationChannelState,
  | "assistantDraft"
  | "awaitingReply"
  | "awaitingSince"
  | "awaitingTimedOut"
  | "messages"
  | "pending"
>;

/** What the status reads: the channel's facts, with the core's reading of the reply. */
const withReply = (input: StatusInput) => ({
  ...input,
  reply: replyState({ ...input, participantStatus: undefined }),
});

function assistantMessage(
  messageId: string,
  text: string,
  createdAt: number
): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    refs: [],
    role: "assistant",
    source: "server",
    status: "completed",
    text,
  };
}

function statusInput(overrides: Partial<StatusInput> = {}): StatusInput {
  return {
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    messages: [],
    pending: [],
    ...overrides,
  };
}

const oldReply = () => assistantMessage("assistant-old", "旧回复", 1_720_000_000);
const oldReplyComplete = {
  kind: "complete",
  messageId: "assistant-old",
  text: "旧回复",
  timestamp: 1_720_000_000,
};

describe("deriveCommaCenterStatus", () => {
  it.each([
    {
      name: "prioritizes the live typing state and keeps its conversation timestamp",
      input: () =>
        statusInput({
          awaitingReply: true,
          awaitingSince: 1_720_000_099_000,
          messages: [oldReply()],
        }),
      expected: { kind: "typing", timestamp: 1_720_000_099_000 },
    },
    {
      name: "shows the latest non-empty assistant output after typing completes",
      input: () =>
        statusInput({
          messages: [
            oldReply(),
            assistantMessage("assistant-empty", "   ", 1_720_000_001),
            assistantMessage("assistant-latest", "最新回复", 1_720_000_002),
          ],
        }),
      expected: {
        kind: "complete",
        messageId: "assistant-latest",
        text: "最新回复",
        timestamp: 1_720_000_002,
      },
    },
    {
      name: "stops typing after an awaiting reply times out",
      input: () =>
        statusInput({
          awaitingReply: true,
          awaitingSince: 1_720_000_099_000,
          awaitingTimedOut: true,
          messages: [oldReply()],
        }),
      expected: oldReplyComplete,
    },
    {
      name: "does not report a completed draft as live typing before canonical commit",
      input: () =>
        statusInput({
          assistantDraft: {
            conversationId: "conversation-a",
            draftId: "draft-completed",
            responseKey: "response-completed",
            sourceMessageIds: ["user-latest"],
            status: "completed",
            text: "等待 canonical commit",
          },
          awaitingReply: true,
          awaitingSince: 1_720_000_099_000,
          messages: [oldReply()],
        }),
      expected: oldReplyComplete,
    },
  ])("$name", ({ expected, input }) => {
    expect(deriveCommaCenterStatus(withReply(input()))).toEqual(expected);
  });
});

describe("advanceRouterReplyMark", () => {
  const user = (messageId: string): ChatMessage => ({
    ...assistantMessage(messageId, "question", 1),
    role: "user",
  });
  const reply = (messageId: string) => assistantMessage(messageId, "answer", 1);

  it("takes the first history as the baseline, including an empty one", () => {
    expect(advanceRouterReplyMark(undefined, [])).toEqual({
      published: null,
      seen: null,
    });
    expect(advanceRouterReplyMark(undefined, [user("u1"), reply("r1")])).toEqual({
      published: "r1",
      seen: "r1",
    });
  });

  it("publishes a reply committed after the last one seen", () => {
    const empty = advanceRouterReplyMark(undefined, []);
    const first = advanceRouterReplyMark(empty, [user("u1"), reply("r1")]);
    expect(first).toEqual({ published: "r1", seen: "r1" });
    expect(advanceRouterReplyMark(first, [user("u1"), reply("r1")])).toBe(first);
    expect(advanceRouterReplyMark(first, [user("u1"), reply("r1"), user("u2")])).toBe(
      first
    );
    expect(
      advanceRouterReplyMark(first, [user("u1"), reply("r1"), user("u2"), reply("r2")])
    ).toEqual({ published: "r2", seen: "r2" });
  });

  it("keeps the published reply when the latest one is deleted, then counts the next", () => {
    const mark = advanceRouterReplyMark(undefined, [reply("r1"), reply("r2")]);
    const deleted = advanceRouterReplyMark(mark, [reply("r1")]);
    expect(deleted).toEqual({ published: "r2", seen: "r1" });
    expect(advanceRouterReplyMark(deleted, [])).toEqual({
      published: "r2",
      seen: null,
    });
    expect(advanceRouterReplyMark(deleted, [reply("r1"), reply("r3")])).toEqual({
      published: "r3",
      seen: "r3",
    });
  });

  it("does not count a reply it cannot order after the last one seen", () => {
    const mark = advanceRouterReplyMark(undefined, [reply("r1")]);
    expect(advanceRouterReplyMark(mark, [reply("other")])).toEqual({
      published: "r1",
      seen: "other",
    });
  });
});
