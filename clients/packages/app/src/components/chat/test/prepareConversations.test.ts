import { describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaConversation } from "../../../api";
import type { ChatRegistry } from "../ChatProvider";
import { ConversationPreparation } from "../prepareConversations";

function fixture() {
  const pending: { resolve(value: CommaConversation): void; signal: AbortSignal }[] =
    [];
  const getConversation = vi.fn(
    (_group, _id, options) =>
      new Promise<CommaConversation>((resolve) => {
        pending.push({ resolve, signal: options.signal });
      })
  );
  const remember = vi.fn();
  const registry = {
    getRetainedSnapshot: vi.fn(),
    rememberConversationSnapshot: remember,
    beginAttempt: () => ({
      run: (work: (api: CommaApiClient, signal: AbortSignal) => unknown) =>
        Promise.resolve(
          work(
            { getConversation } as unknown as CommaApiClient,
            new AbortController().signal
          )
        ),
      isCurrent: () => true,
      release: vi.fn(),
    }),
  } as unknown as ChatRegistry;
  return {
    pending,
    getConversation,
    remember,
    registry,
    owner: new ConversationPreparation(registry),
  };
}
const tasks = Array.from({ length: 100 }, (_, i) => ({
  groupId: "g",
  conversationId: `c${i}`,
  updatedAt: 1,
}));
const conversation = {
  id: "c0",
  group_id: "g",
  kind: "agent_task",
  status: "active",
  title: "Task",
  updated_at: 1,
  messages: [],
} satisfies CommaConversation;
const settle = async () => {
  for (let i = 0; i < 6; i++) await Promise.resolve();
};

describe("conversation preparation", () => {
  it("bounds visible-page reads and shares completed reads across repeated visibility reports", async () => {
    const f = fixture();
    f.owner.update(tasks);
    expect(f.getConversation).toHaveBeenCalledTimes(2);
    expect(f.getConversation).toHaveBeenCalledWith(
      "g",
      "c0",
      expect.objectContaining({ messageLimit: 24 })
    );
    for (let i = 0; i < 6; i++) {
      f.pending[i]!.resolve({ ...conversation, id: `c${i}` });
      await settle();
      expect(f.getConversation.mock.calls.length - i - 1).toBeLessThanOrEqual(2);
    }
    f.owner.update(tasks);
    expect(f.getConversation).toHaveBeenCalledTimes(6);
    expect(f.remember).toHaveBeenCalledTimes(6);
  });

  it("replaces queued offscreen work and rejects late results after leaving the list", async () => {
    const f = fixture();
    f.owner.update(tasks);
    f.owner.update(tasks.slice(90));
    f.pending[0]!.resolve(conversation);
    await settle();
    expect(f.getConversation.mock.calls[2]?.[1]).toBe("c90");
    f.owner.dispose();
    expect(f.pending[1]!.signal.aborted).toBe(true);
    f.pending[1]!.resolve({ ...conversation, id: "c1" });
    await settle();
    expect(f.remember).toHaveBeenCalledTimes(1);
    expect(f.getConversation).toHaveBeenCalledTimes(3);
  });
});
