import { describe, expect, it, vi } from "vitest";
import { idleConversationChannelState } from "../../chat/model/conversationChannel";
import { appendRecommendationPrompt } from "../appendRecommendationPrompt";

describe("recommendation draft handoff", () => {
  it("preserves the exact draft and both consecutive source-specific prompts", () => {
    let draft = "  My unfinished note\n";
    const channel = {
      getSnapshot: () => ({ ...idleConversationChannelState, draft }),
      setDraft: vi.fn((next: string) => {
        draft = next;
      }),
      send: vi.fn(),
    };
    const first =
      "Review login fix\nhttps://github.com/team/a/pull/7\nCheck authentication.";
    const second =
      "Review login fix\nhttps://github.com/team/b/pull/7\nCheck session expiry.";
    appendRecommendationPrompt(channel, first);
    appendRecommendationPrompt(channel, second);
    expect(draft).toBe("  My unfinished note\n\n\n" + first + "\n\n" + second);
    expect(channel.send).not.toHaveBeenCalled();
  });

  it("fills an empty draft without changing the prompt or sending it", () => {
    const prompt = "Review\nhttps://example.com/" + "a".repeat(800);
    const channel = {
      getSnapshot: () => idleConversationChannelState,
      setDraft: vi.fn(),
      send: vi.fn(),
    };
    appendRecommendationPrompt(channel, prompt);
    expect(channel.setDraft).toHaveBeenCalledWith(prompt);
    expect(channel.send).not.toHaveBeenCalled();
  });
});
