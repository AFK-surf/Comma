import type { ConversationProjection } from "@comma/chat-contract";
import { describe, expect, it } from "vitest";
import { projectionToChannelState } from "../../src/chat/view-state.ts";

const message = (
  messageId: string,
  text: string,
  extra: Record<string, unknown> = {}
) => ({
  attachments: [],
  delivery: "sent" as const,
  messageId,
  parts: [{ kind: "markdown" as const, text }],
  refs: [],
  role: "assistant" as const,
  source: "server" as const,
  text,
  ...extra,
});

function projection(extra: Partial<ConversationProjection>): ConversationProjection {
  return {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    connection: "live",
    conversation: undefined,
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: [],
    pending: [],
    serverMessages: [],
    status: "ready",
    syncWarning: undefined,
    ...extra,
  } as ConversationProjection;
}

describe("a conversation's projection as a window shows it", () => {
  it("keeps who wrote each message, where it came from and what it answers", () => {
    const incoming = message("m-in", "Hello from WeChat", {
      platformSource: "wechat",
      role: "user",
    });
    const router = message("m-router", "Router reply", {
      actorId: "actor-router",
      actorRole: "router",
      platformSource: "telegram",
      replyToMessageId: "m-in",
      threadRootMessageId: "m-in",
    });
    const worker = message("m-worker", "Worker reply", {
      actorId: "actor-worker",
      actorRole: "worker",
    });
    const shown = projectionToChannelState(
      projection({
        messages: [incoming, router, worker] as ConversationProjection["messages"],
        serverMessages: [
          incoming,
          router,
          worker,
        ] as ConversationProjection["messages"],
      })
    );

    expect(shown.serverMessages).toMatchObject([
      { platformSource: "wechat", role: "user" },
      {
        actorId: "actor-router",
        actorRole: "router",
        platformSource: "telegram",
        replyToMessageId: "m-in",
        threadRootMessageId: "m-in",
      },
      { actorId: "actor-worker", actorRole: "worker" },
    ]);
    expect(shown.messages.map((m) => m.messageId)).toEqual([
      "m-in",
      "m-router",
      "m-worker",
    ]);
  });

  it("keeps the reply awaited on this device and a Task's review version", () => {
    const shown = projectionToChannelState(
      projection({
        awaitingReply: true,
        awaitingTurnKey: "request-current",
        locallyAwaitingReply: true,
        conversation: {
          groupId: "grp_test",
          id: "cnv_1",
          kind: "agent_task",
          reviewVersion: 2,
          status: "ready_for_review",
          title: "Review Task",
          workspaceId: "wsp_1",
        } as ConversationProjection["conversation"],
      })
    );

    expect(shown).toMatchObject({
      awaitingReply: true,
      awaitingTurnKey: "request-current",
      locallyAwaitingReply: true,
      conversation: { id: "cnv_1", review_version: 2, status: "ready_for_review" },
    });
  });
});
