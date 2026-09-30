import { describe, expect, it } from "vitest";
import type {
  ChatMessage,
  ConversationChannelState,
} from "../../chat/model/conversationChannel";
import { deriveCommaCenterStatus } from "../CommaCenterStatusContext";

type StatusInput = Pick<
  ConversationChannelState,
  | "assistantDraft"
  | "awaitingReply"
  | "awaitingSince"
  | "awaitingTimedOut"
  | "messages"
  | "pending"
>;

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

describe("deriveCommaCenterStatus", () => {
  it("prioritizes the live typing state and keeps its conversation timestamp", () => {
    expect(
      deriveCommaCenterStatus(
        statusInput({
          awaitingReply: true,
          awaitingSince: 1_720_000_099_000,
          messages: [assistantMessage("assistant-old", "旧回复", 1_720_000_000)],
        })
      )
    ).toEqual({ kind: "typing", timestamp: 1_720_000_099_000 });
  });

  it("shows the latest non-empty assistant output after typing completes", () => {
    expect(
      deriveCommaCenterStatus(
        statusInput({
          messages: [
            assistantMessage("assistant-old", "旧回复", 1_720_000_000),
            assistantMessage("assistant-empty", "   ", 1_720_000_001),
            assistantMessage("assistant-latest", "最新回复", 1_720_000_002),
          ],
        })
      )
    ).toEqual({
      kind: "complete",
      messageId: "assistant-latest",
      text: "最新回复",
      timestamp: 1_720_000_002,
    });
  });

  it("stops typing after an awaiting reply times out", () => {
    expect(
      deriveCommaCenterStatus(
        statusInput({
          awaitingReply: true,
          awaitingSince: 1_720_000_099_000,
          awaitingTimedOut: true,
          messages: [assistantMessage("assistant-old", "旧回复", 1_720_000_000)],
        })
      )
    ).toEqual({
      kind: "complete",
      messageId: "assistant-old",
      text: "旧回复",
      timestamp: 1_720_000_000,
    });
  });

  it("does not report a completed draft as live typing before canonical commit", () => {
    expect(
      deriveCommaCenterStatus(
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
          messages: [assistantMessage("assistant-old", "旧回复", 1_720_000_000)],
        })
      )
    ).toEqual({
      kind: "complete",
      messageId: "assistant-old",
      text: "旧回复",
      timestamp: 1_720_000_000,
    });
  });
});
