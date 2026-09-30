import { describe, expect, it, vi } from "vitest";
import type { ChatChannel } from "../../../runtime-chat/channel/ChatChannel";
import { idleConversationChannelState } from "../../chat/model/conversationChannel";
import { prefillDeviceDraft } from "../routerDeviceDraft";

describe("device Router draft", () => {
  it("waits for existing content, preserves it, and never sends", async () => {
    let state = {
      ...idleConversationChannelState,
      status: "loading" as "loading" | "ready",
      draft: "",
    };
    let changed: () => void = vi.fn();
    const release = vi.fn();
    const setDraft = vi.fn((draft: string) => {
      state = { ...state, draft };
    });
    const send = vi.fn();
    const channel = {
      getSnapshot: () => state,
      subscribe: (cb: () => void) => {
        changed = cb;
        return release;
      },
      setDraft,
      send,
    } as unknown as ChatChannel;
    const signal = new AbortController().signal;
    const pending = prefillDeviceDraft(channel, "Connect another device", signal);
    expect(setDraft).not.toHaveBeenCalled();
    state = { ...state, status: "ready", draft: "My existing draft" };
    changed();
    await pending;
    expect(setDraft).toHaveBeenCalledWith(
      "My existing draft\n\nConnect another device"
    );
    await prefillDeviceDraft(channel, "Connect another device", signal);
    expect(setDraft).toHaveBeenCalledOnce();
    expect(send).not.toHaveBeenCalled();
    expect(release).toHaveBeenCalledTimes(2);
  });
});
