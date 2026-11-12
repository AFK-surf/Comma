import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { useGradientShimmer } from "@comma/ui/components/ai-activity";
import { memo, useMemo, useRef } from "react";
import { useStartOfToday } from "../layout/calendarDay";
import { formatConversationTimestamp } from "../layout/messageTimestamp";
import type { ReplyLinePlace } from "../replies/messageRelationships";

// Memoized (all props are primitives): formatting constructs Intl formatters,
// which must not re-run for every timestamped turn on each thread render.
export const ConversationTimestamp = memo(function ConversationTimestamp({
  animate,
  createdAt,
  isNew = false,
  locale,
  messageId,
  replyLine,
}: {
  animate: boolean;
  createdAt: number;
  /**
   * Reads "New" in place of the time: the newest messages the agent sent on
   * its own. The time shows again once they are no longer news.
   */
  isNew?: boolean;
  locale: CommaLocale;
  messageId: string;
  /** Where a reply line runs down through this row, so New's rule starts past it. */
  replyLine?: ReplyLinePlace | undefined;
}) {
  const messagesApi = useCommaMessages();
  // Read here so a timestamp says "Today" only while it is: the transcript
  // stays open across midnight.
  const today = useStartOfToday();
  const timestamp = useMemo(
    () => formatConversationTimestamp(createdAt, locale, today),
    [createdAt, locale, today]
  );
  if (!timestamp) {
    return null;
  }

  return (
    <time
      className="comma-chat-conversation-timestamp"
      data-new={isNew ? "true" : undefined}
      data-outgoing-entry={animate ? "true" : undefined}
      data-reply-line={replyLine}
      data-testid={`chat-conversation-time-${messageId}`}
      dateTime={timestamp.iso}
    >
      {isNew ? (
        <NewLabel label={messagesApi.chat_timestamp_new()} />
      ) : timestamp.isToday ? (
        `${messagesApi.inbox_today()} ${timestamp.label}`
      ) : (
        timestamp.label
      )}
    </time>
  );
});

/**
 * "New" crosses once with the thinking shimmer when the reader comes to it:
 * on mount, or when it first scrolls into view.
 */
function NewLabel({ label }: { label: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  useGradientShimmer(ref, { active: true, contentIdentity: label, repeat: false });
  return (
    <span
      className="comma-chat-conversation-timestamp-new comma-gradient-shimmer"
      ref={ref}
    >
      {label}
    </span>
  );
}
