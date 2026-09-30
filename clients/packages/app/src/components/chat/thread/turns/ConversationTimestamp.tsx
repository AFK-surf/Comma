import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { memo, useMemo } from "react";
import { formatConversationTimestamp } from "../layout/messageTimestamp";

// Memoized (all props are primitives): formatting constructs Intl formatters,
// which must not re-run for every timestamped turn on each thread render.
export const ConversationTimestamp = memo(function ConversationTimestamp({
  animate,
  createdAt,
  locale,
  messageId,
}: {
  animate: boolean;
  createdAt: number;
  locale: CommaLocale;
  messageId: string;
}) {
  const messagesApi = useCommaMessages();
  const timestamp = useMemo(
    () => formatConversationTimestamp(createdAt, locale),
    [createdAt, locale]
  );
  if (!timestamp) {
    return null;
  }

  return (
    <time
      className="comma-chat-conversation-timestamp"
      data-outgoing-entry={animate ? "true" : undefined}
      data-testid={`chat-conversation-time-${messageId}`}
      dateTime={timestamp.iso}
    >
      {timestamp.isToday
        ? `${messagesApi.inbox_today()} ${timestamp.label}`
        : timestamp.label}
    </time>
  );
});
