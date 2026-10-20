import { describe, expect, it, vi } from "vitest";
import { prefillDeviceDraft } from "../routerDeviceDraft";

// How the core waits for the chat and keeps the draft is tested in
// packages/core/test/chat/chat.test.ts.

describe("device Router draft", () => {
  it("asks the core to add the prompt to the draft, and stops waiting on an abort", async () => {
    const prefillDraft = vi.fn(() => Promise.resolve({}));
    await prefillDeviceDraft(
      { prefillDraft },
      "Connect another device",
      new AbortController().signal
    );
    expect(prefillDraft).toHaveBeenCalledWith("Connect another device");

    const controller = new AbortController();
    const pending = prefillDeviceDraft(
      { prefillDraft: () => new Promise(() => {}) },
      "Connect another device",
      controller.signal
    );
    controller.abort();
    await expect(pending).rejects.toThrow("Chat request canceled.");
  });
});
