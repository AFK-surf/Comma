import { useCommaMessages } from "@comma/i18n/react";
import type { ConversationErrorKind } from "../model/conversationChannel";

export function ChatBanner({
  errorKind,
}: {
  errorKind?: ConversationErrorKind | undefined;
}) {
  const messages = useCommaMessages();

  if (errorKind === "unauthorized") {
    return (
      <div className="comma-chat-terminal-state">{messages.chat_unauthorized()}</div>
    );
  }

  if (errorKind === "not-found" || errorKind === "forbidden") {
    return (
      <div className="comma-chat-terminal-state">{messages.chat_cannot_open()}</div>
    );
  }

  return null;
}
