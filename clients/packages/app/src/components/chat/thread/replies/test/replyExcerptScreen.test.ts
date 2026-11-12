import type { ChatMessage } from "@comma/core/chat";
import { describe, expect, it } from "vitest";
import { replyExcerpt } from "../replyExcerpt";

const messagesApi = {
  chat_ref_task: () => "Task",
  chat_ref_task_unavailable: () => "Task unavailable",
  chat_reply_attachment: () => "Attachment",
} as never;

describe("a reply's excerpt of a message with a screen link", () => {
  it("says the link's words, not its markdown", () => {
    const text =
      "The app is on the emulator. Have a look:\n\n[comma-findn6-fold](comma:screen/dev/android%3Aemulator-5554)\n\nAnd your computer's own screen:\n\ncomma:screen/dev/display";
    const target = {
      text,
      parts: [{ kind: "markdown", text }],
      attachments: [],
    } as unknown as ChatMessage;
    expect(replyExcerpt(target, messagesApi)).toBe(
      "The app is on the emulator. Have a look: comma-findn6-fold And your computer's own screen:"
    );
  });
});
