import { renderHook, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { expect, it } from "vitest";
import { useAgentRequests } from "../useAgentRequests";

it("lets go of a conversation's request stream as soon as the view no longer shows it", async () => {
  const subscribed: Record<string, unknown>[] = [];
  const unsubscribed: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "agentRequests"
        ? { requests: [], loading: false, error: false }
        : undefined,
    onSubscribe: (topic) => subscribed.push(topic),
    onUnsubscribe: (topic) => unsubscribed.push(topic),
  });
  const { rerender } = renderHook(
    ({ conversationId, live }: { conversationId: string; live: boolean }) =>
      useAgentRequests({ live, groupId: "grp-a", conversationId, messages: [] }),
    {
      initialProps: { conversationId: "cnv-a", live: true },
      wrapper: ({ children }) => core.wrap(children),
    }
  );
  await waitFor(() =>
    expect(subscribed).toContainEqual(
      expect.objectContaining({ topic: "agentRequests", conversation: "cnv-a" })
    )
  );

  // Another conversation (another account's, after a sign-in): the last one's stream ends at once, not after the
  // renderer's linger, so the core never follows it for the account there is now.
  rerender({ conversationId: "cnv-b", live: true });
  await waitFor(() =>
    expect(unsubscribed).toContainEqual(
      expect.objectContaining({ topic: "agentRequests", conversation: "cnv-a" })
    )
  );

  // A view that no longer shows live data (a retained surface out of sight) follows none.
  rerender({ conversationId: "cnv-b", live: false });
  await waitFor(() =>
    expect(unsubscribed).toContainEqual(
      expect.objectContaining({ topic: "agentRequests", conversation: "cnv-b" })
    )
  );
});
