import { useCommaMessages } from "@comma/i18n/react";
import type { ConversationErrorKind } from "@comma/core/chat";

/**
 * Why the conversation cannot be shown. With nothing of it held, the notice is the whole page; above messages already
 * shown (`inline`), it is one line and leaves the transcript its height.
 */
export function ChatBanner({
  errorKind,
  inline = false,
}: {
  errorKind?: ConversationErrorKind | undefined;
  inline?: boolean;
}) {
  const messages = useCommaMessages();
  const text =
    errorKind === "unauthorized"
      ? messages.chat_unauthorized()
      : errorKind === "not-found" || errorKind === "forbidden"
        ? messages.chat_cannot_open()
        : undefined;

  if (text === undefined) return null;
  if (inline)
    return <output className="block p-md text-sm text-secondary">{text}</output>;
  return <div className="comma-chat-terminal-state">{text}</div>;
}
