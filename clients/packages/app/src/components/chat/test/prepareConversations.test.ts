import { describe, expect, it, vi } from "vitest";
import type { CallFn } from "@comma/core-client";
import type { CommaConversation } from "@comma/core/api-schemas";
import type { ChatContextValue } from "../ChatProvider";
import { ConversationPreparation } from "../prepareConversations";

type Prepared = { conversation: CommaConversation; messages: [] } | null;
const session = { audience: "https://api.test", sessionId: "session-1" };

function fixture() {
  const pending: {
    params: { groupId: string; conversationId: string };
    resolve(value: Prepared): void;
    signal: AbortSignal;
  }[] = [];
  // The core reads each conversation ahead (chat.prepare); here each read waits for the test.
  const call = vi.fn(
    (_name: string, params: unknown, signal?: AbortSignal) =>
      new Promise<Prepared>((resolve) => {
        pending.push({
          params: params as { groupId: string; conversationId: string },
          resolve,
          signal: signal!,
        });
      })
  );
  const remember = vi.fn();
  const registry = {
    getRetainedSnapshot: vi.fn(),
    productLease: session,
    rememberConversationSnapshot: remember,
    beginAttempt: () => ({
      run: (work: (signal: AbortSignal) => unknown) =>
        Promise.resolve(work(new AbortController().signal)),
      isCurrent: () => true,
      release: vi.fn(),
    }),
  } as unknown as ChatContextValue;
  return {
    pending,
    call,
    remember,
    registry,
    owner: new ConversationPreparation(registry, call as unknown as CallFn),
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
const prepared = (read: CommaConversation): Prepared => ({
  conversation: read,
  messages: [],
});
const settle = async () => {
  for (let i = 0; i < 6; i++) await Promise.resolve();
};

describe("conversation preparation", () => {
  it("bounds visible-page reads and shares completed reads across repeated visibility reports", async () => {
    const f = fixture();
    f.owner.update(tasks);
    expect(f.call).toHaveBeenCalledTimes(2);
    expect(f.call).toHaveBeenCalledWith(
      "chat.prepare",
      { session, groupId: "g", conversationId: "c0" },
      expect.any(AbortSignal)
    );
    for (let i = 0; i < 6; i++) {
      f.pending[i]!.resolve(prepared({ ...conversation, id: `c${i}` }));
      await settle();
      expect(f.call.mock.calls.length - i - 1).toBeLessThanOrEqual(2);
    }
    f.owner.update(tasks);
    expect(f.call).toHaveBeenCalledTimes(6);
    expect(f.remember).toHaveBeenCalledTimes(6);
  });

  it("replaces queued offscreen work and rejects late results after leaving the list", async () => {
    const f = fixture();
    f.owner.update(tasks);
    f.owner.update(tasks.slice(90));
    f.pending[0]!.resolve(prepared(conversation));
    await settle();
    expect(f.pending[2]?.params.conversationId).toBe("c90");
    f.owner.dispose();
    expect(f.pending[1]!.signal.aborted).toBe(true);
    f.pending[1]!.resolve(prepared({ ...conversation, id: "c1" }));
    await settle();
    expect(f.remember).toHaveBeenCalledTimes(1);
    expect(f.call).toHaveBeenCalledTimes(3);
  });
});
