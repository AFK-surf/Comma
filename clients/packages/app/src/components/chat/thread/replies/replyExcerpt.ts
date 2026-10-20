import type { useCommaMessages } from "@comma/i18n/react";
import type { ChatMessage } from "@comma/core/chat";
import { messagePartsPlainText } from "../inline/MessageInlineElements";

/** One line that stands for a message wherever a reply points at it. */
export function replyExcerpt(
  target: ChatMessage,
  messagesApi: ReturnType<typeof useCommaMessages>
) {
  let text = messagePartsPlainText(
    target.parts ?? [{ kind: "markdown", text: target.text }],
    {
      task: messagesApi.chat_ref_task(),
      unavailableTask: messagesApi.chat_ref_task_unavailable(),
    }
  );
  // A person's message that only quotes or attaches text stands for that text.
  if (target.display && !text.trim()) {
    text = [
      ...target.display.quotes,
      ...(target.display.texts ?? []).map((attached) => attached.text),
    ].join(" ");
  }
  return (
    text.replace(/\s+/g, " ").trim().slice(0, 180) ||
    target.attachments[0]?.fileName ||
    target.attachments[0]?.title ||
    messagesApi.chat_reply_attachment()
  );
}
