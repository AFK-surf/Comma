import { useCommaMessages } from "@comma/i18n/react";
import { ExclamationTriangleIcon } from "@comma/ui/components/icons";
import { openUsageBillingSettings } from "../../../../billing/outOfCredits";
import type { ChatMessage } from "@comma/core/chat";

export function FailedDeliveryNotice({
  message,
  onDiscard,
  onRetry,
}: {
  message: ChatMessage;
  onDiscard: (clientRequestId: string) => void;
  onRetry: (clientRequestId: string) => void;
}) {
  const messagesApi = useCommaMessages();
  // A send refused for Comma credits says how to add them, in both windows.
  const outOfCredits =
    message.failureAction === "billing" ||
    message.error === messagesApi.chat_insufficient_credits();
  return (
    <div
      className="comma-chat-notice-card comma-chat-failed-row"
      data-testid="chat-failed-row"
      role="alert"
    >
      <ExclamationTriangleIcon aria-hidden className="comma-chat-notice-card-icon" />
      <div className="comma-chat-notice-card-content">
        <span className="comma-chat-notice-card-copy">
          {message.error
            ? messagesApi.chat_send_failed_detail({ detail: message.error })
            : messagesApi.chat_failed()}
        </span>
        <div className="comma-chat-notice-card-actions">
          {/* Discard leaves the send behind; Retry is the one that
              resumes it, so it sits at the far end. */}
          <div className="comma-chat-notice-card-actions-group">
            {outOfCredits ? (
              <button
                className="comma-chat-notice-card-action"
                onClick={openUsageBillingSettings}
                type="button"
              >
                {messagesApi.chat_add_credits()}
              </button>
            ) : null}
            <button
              className="comma-chat-notice-card-action comma-chat-notice-card-action-quiet"
              onClick={() => onDiscard(message.clientRequestId!)}
              type="button"
            >
              {messagesApi.common_discard()}
            </button>
          </div>
          <button
            className="comma-chat-notice-card-action"
            onClick={() => onRetry(message.clientRequestId!)}
            type="button"
          >
            {messagesApi.common_retry()}
          </button>
        </div>
      </div>
    </div>
  );
}
