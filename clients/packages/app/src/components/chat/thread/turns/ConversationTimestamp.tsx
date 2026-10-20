import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { useGradientShimmer } from "@comma/ui/components/ai-activity";
import { memo, useMemo, useRef } from "react";
import { formatConversationTimestamp } from "../layout/messageTimestamp";

// Memoized (all props are primitives): formatting constructs Intl formatters,
// which must not re-run for every timestamped turn on each thread render.
export const ConversationTimestamp = memo(function ConversationTimestamp({
  animate,
  createdAt,
  isNew = false,
  locale,
  messageId,
}: {
  animate: boolean;
  createdAt: number;
  /** Leads with "New": the newest messages the agent sent on its own. */
  isNew?: boolean;
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
      {isNew ? (
        <>
          <NewLabel label={messagesApi.chat_timestamp_new()} />{" "}
        </>
      ) : null}
      {timestamp.isToday
        ? `${messagesApi.inbox_today()} ${timestamp.label}`
        : timestamp.label}
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
