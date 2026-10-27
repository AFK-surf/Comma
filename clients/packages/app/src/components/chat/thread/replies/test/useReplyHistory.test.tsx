import { act, renderHook } from "@comma/test-utils/render";
import { expect, it, vi } from "vitest";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { useStickToBottom } from "../../scroll/useStickToBottom";
import { useReplyHistory } from "../useReplyHistory";

it.each(["navigation", "focus"])(
  "discards a late history response after %s cancels its reveal",
  async (entry) => {
    let resolve!: (value: never[]) => void;
    const core = createScriptedCore({
      calls: (name) =>
        name === "chat.messageContext"
          ? new Promise<never[]>((done) => {
              resolve = done;
            })
          : null,
    });
    const { result } = renderHook(
      () => {
        const history = useReplyHistory({
          live: true,
          conversationId: "conversation",
          conversationKind: "user_chat",
          currentMessages: [],
          groupId: "group",
          historyScope: "scope",
        });
        const follow = useStickToBottom("one", {
          resolveNewestTurn: () => null,
          onCancelNavigation: history.cancelHistoryRequest,
        });
        return { ...history, follow };
      },
      { wrapper: ({ children }) => core.wrap(children) }
    );
    const lifecycle = { arrived: vi.fn(), cancel: vi.fn() };
    let pending!: Promise<void>;
    act(() => {
      pending = result.current.loadReplyTarget("old-message", lifecycle);
    });
    // Let the request reach the core before it is let go.
    await act(async () => {});
    expect(core.sentTo("chat.messageContext")).toHaveLength(1);
    act(() => {
      if (entry === "focus")
        result.current.follow.handleFocusChange(document.createElement("button"));
      else result.current.cancelHistoryRequest();
    });
    await act(async () => {
      resolve([]);
      await pending;
    });
    expect(core.cancelledTo("chat.messageContext")).toHaveLength(1);
    expect(lifecycle.cancel).toHaveBeenCalledOnce();
    expect(lifecycle.arrived).not.toHaveBeenCalled();
    expect(result.current.historyReveal.current).toBeNull();
    expect(result.current.messages).toEqual([]);
  }
);
