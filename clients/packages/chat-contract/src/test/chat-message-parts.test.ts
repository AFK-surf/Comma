import { describe, expect, it } from "vitest";
import {
  chatMessagePartSchema,
  chatMessageSchema,
  chatPendingSendSchema,
} from "../index";

const task = {
  conversationId: "cnv_task_public",
  title: "Deploy report",
  unavailable: false,
};

describe("chat message parts", () => {
  it("preserves the canonical Task actor role", () => {
    const message = {
      actorId: "actor_worker_1",
      actorRole: "worker",
      attachments: [],
      delivery: "sent",
      messageId: "msg_worker",
      refs: [],
      role: "assistant",
      source: "server",
      text: "Worker result",
    };

    expect(chatMessageSchema.parse(message)).toMatchObject({
      actorId: "actor_worker_1",
      actorRole: "worker",
    });
    expect(
      chatMessageSchema.safeParse({ ...message, actorRole: "assistant" }).success
    ).toBe(false);
  });

  it("preserves the billing recovery action across shared chat projections", () => {
    const action = { failureAction: "billing" } as const;
    const message = {
      ...action,
      attachments: [],
      delivery: "failed",
      error: "Not enough credits",
      messageId: "msg_billing_failure",
      refs: [],
      role: "user",
      source: "pending",
      text: "Continue",
    };
    const pending = {
      ...action,
      clientRequestId: "request_billing_failure",
      createdAt: 1,
      error: "Not enough credits",
      status: "failed",
      text: "Continue",
    };

    expect(chatMessageSchema.parse(message).failureAction).toBe("billing");
    expect(chatPendingSendSchema.parse(pending).failureAction).toBe("billing");
  });

  it("accepts only the payload owned by each ordered part variant", () => {
    expect(chatMessagePartSchema.parse({ kind: "markdown", text: "Before " })).toEqual({
      kind: "markdown",
      text: "Before ",
    });
    expect(chatMessagePartSchema.parse({ kind: "inline-task", task })).toEqual({
      kind: "inline-task",
      task,
    });

    for (const malformed of [
      { kind: "markdown" },
      { kind: "markdown", task, text: "Forged" },
      { kind: "inline-task" },
      { kind: "inline-task", task, text: "Forged" },
    ]) {
      expect(
        chatMessagePartSchema.safeParse(malformed).success,
        JSON.stringify(malformed)
      ).toBe(false);
    }
  });

  it("rejects a malformed part when it is nested in the native chat message", () => {
    const message = {
      attachments: [],
      delivery: "sent",
      messageId: "msg_1",
      parts: [{ kind: "inline-task", text: "No structured Task" }],
      refs: [],
      role: "assistant",
      source: "server",
      text: "No structured Task",
    };

    expect(chatMessageSchema.safeParse(message).success).toBe(false);
  });
});
