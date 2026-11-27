import { act, render } from "@comma/test-utils/render";
import { useLayoutEffect } from "react";
import { describe, expect, it, vi } from "vitest";
import {
  idleConversationChannelState,
  type ConversationChannelState,
} from "@comma/core/chat";
import {
  useComposerDraft,
  type ComposerDraftSource,
} from "../../composer/conversationDraft";
import { useConversation } from "../useConversation";

const { context, MockStaleChatSessionError } = vi.hoisted(() => ({
  context: { registry: {} as Record<string, unknown> },
  MockStaleChatSessionError: class extends Error {
    constructor() {
      super("The chat session is no longer active.");
      this.name = "StaleChatSessionError";
    }
  },
}));
vi.mock("../../ChatProvider", () => ({
  useChatRegistry: () => context.registry,
  isStaleChatSessionError: (error: unknown) =>
    error instanceof MockStaleChatSessionError,
}));

const readyState = (id: string) => ({
  ...idleConversationChannelState,
  status: "ready" as const,
  conversation: {
    id,
    group_id: "group",
    kind: "agent_task" as const,
    title: id,
    status: "ready_for_review",
  },
});

for (const cached of [false, true]) {
  describe(cached ? "retained conversation" : "new conversation", () => {
    it("never commits the previous conversation while switching targets", () => {
      const first = readyState("first");
      const second = cached
        ? readyState("second")
        : { ...idleConversationChannelState, status: "loading" as const };
      const release = vi.fn();
      context.registry = {
        retain: (_workspace: string, _group: string, id: string) => ({
          channel: {
            subscribe: () => () => {},
            getSnapshot: () => (id === "first" ? first : second),
          },
          release,
        }),
        getRetainedSnapshot: (_group: string, id: string) =>
          cached && id === "second" ? second : undefined,
      };
      const commits: {
        requested: string;
        shown: string | undefined;
        status: string;
      }[] = [];
      function Probe({ id }: { id: string }) {
        const { state } = useConversation("workspace", "group", id);
        useLayoutEffect(() => {
          commits.push({
            requested: id,
            shown: state.conversation?.id,
            status: state.status,
          });
        });
        return null;
      }
      const view = render(<Probe id="first" />);
      commits.length = 0;
      view.rerender(<Probe id="second" />);
      expect(commits.length).toBeGreaterThan(0);
      for (const commit of commits) {
        expect(commit).toEqual({
          requested: "second",
          shown: cached ? "second" : undefined,
          status: cached ? "ready" : "loading",
        });
      }
      expect(release).toHaveBeenCalledTimes(1);
    });
  });
}

it("re-renders the draft reader, not the conversation host, for a keystroke", () => {
  let snapshot: ConversationChannelState = readyState("keystroke");
  const listeners = new Set<() => void>();
  context.registry = {
    retain: () => ({
      channel: {
        subscribe: (listener: () => void) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
        getSnapshot: () => snapshot,
      },
      release: vi.fn(),
    }),
    getRetainedSnapshot: () => undefined,
  };
  const emit = (next: ConversationChannelState) => {
    snapshot = next;
    act(() => listeners.forEach((listener) => listener()));
  };
  let hostRenders = 0;
  const drafts: string[] = [];
  function DraftReader({ source }: { source: ComposerDraftSource }) {
    drafts.push(useComposerDraft(source));
    return null;
  }
  function Host() {
    const conversation = useConversation("workspace", "group", "keystroke");
    hostRenders += 1;
    return <DraftReader source={conversation.draftSource} />;
  }
  render(<Host />);
  const settled = hostRenders;

  // The channel's draft fast path changes only the draft.
  emit({ ...snapshot, draft: "h" });
  emit({ ...snapshot, draft: "hi" });
  expect(hostRenders).toBe(settled);
  expect(drafts.at(-1)).toBe("hi");

  // Conversation content still reaches the host.
  emit({ ...snapshot, status: "loading" });
  expect(hostRenders).toBe(settled + 1);
});

it("drops stale-session upkeep but keeps the error for actions the person waits on", () => {
  const throwStale = () => {
    throw new MockStaleChatSessionError();
  };
  let stale = true;
  const snapshot = readyState("guarded");
  const unexpected = new Error("unexpected failure");
  const guardedChannel = {
    subscribe: () => () => {},
    getSnapshot: () => snapshot,
    refresh: () => {
      if (stale) throwStale();
      throw unexpected;
    },
    older: throwStale,
    readTaskActivity: throwStale,
    clearPresentation: throwStale,
    setDraft: throwStale,
    send: throwStale,
    retry: throwStale,
    discard: throwStale,
    setTaskRun: throwStale,
    answerQuestion: throwStale,
  };
  context.registry = {
    retain: () => ({
      channel: guardedChannel,
      release: vi.fn(),
    }),
    getRetainedSnapshot: () => undefined,
  };

  let captured: ReturnType<typeof useConversation> | undefined;
  function Probe() {
    captured = useConversation("workspace", "group", "guarded");
    return null;
  }

  render(<Probe />);
  expect(captured).toBeDefined();
  const actions = captured!;

  expect(actions.refresh()).toBeUndefined();
  expect(actions.older()).toBeUndefined();
  expect(actions.readTaskActivity()).toBeUndefined();
  expect(actions.clearPresentation()).toBeUndefined();
  expect(actions.setDraft("draft")).toBeUndefined();

  // The composer undoes its send launch only when send throws.
  expect(() => actions.send("hello")).toThrow(MockStaleChatSessionError);
  expect(() => actions.retry("req_1")).toThrow(MockStaleChatSessionError);
  expect(() => actions.discard("req_1")).toThrow(MockStaleChatSessionError);
  expect(() => actions.setTaskRun({ mode: "auto" } as never)).toThrow(
    MockStaleChatSessionError
  );
  expect(() => actions.answerQuestion({} as never)).toThrow(MockStaleChatSessionError);

  stale = false;
  expect(() => actions.refresh()).toThrow(unexpected);
});
