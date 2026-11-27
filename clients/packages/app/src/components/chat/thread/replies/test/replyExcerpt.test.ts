import type { ChatMessage } from "@comma/core/chat";
import { describe, expect, it } from "vitest";
import { replyExcerpt } from "../replyExcerpt";

const messagesApi = {
  chat_ref_task: () => "Task",
  chat_ref_task_unavailable: () => "Task unavailable",
  chat_reply_attachment: () => "Attachment",
} as never;

describe("replyExcerpt", () => {
  it("strips Markdown formatting while preserving identifiers and math", () => {
    const text =
      "## 2. **Open station settings**\n\n- Click `· Settings` for `foo_bar_baz` and check [docs](https://example.com) with 2 * 3 = 6\n> Quoted _note_ and ~~old~~";
    const target = {
      text,
      parts: [{ kind: "markdown", text }],
      attachments: [],
    } as unknown as ChatMessage;

    expect(replyExcerpt(target, messagesApi)).toBe(
      "2. Open station settings Click · Settings for foo_bar_baz and check docs with 2 * 3 = 6 Quoted note and old"
    );
  });

  it("separates body text from a question prompt without dumping choice labels", () => {
    const target = {
      text: "Review the options",
      parts: [
        { kind: "markdown", text: "Review **the** options" },
        {
          kind: "question",
          messageId: "m1",
          prompt: "Choose the interaction mode",
          multiSelect: false,
          allowOther: true,
          skipBehavior: "dismiss",
          choices: [
            { id: "a", label: "In-place repair" },
            { id: "b", label: "Open settings" },
          ],
          state: { status: "open" },
        },
      ],
      attachments: [],
    } as unknown as ChatMessage;

    expect(replyExcerpt(target, messagesApi)).toBe(
      "Review the options Choose the interaction mode"
    );
  });
});
