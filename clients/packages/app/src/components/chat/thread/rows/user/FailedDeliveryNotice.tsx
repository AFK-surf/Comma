import { useCommaMessages } from "@comma/i18n/react";
import { ExclamationTriangleIcon } from "@comma/ui";
import { openUsageBillingSettings } from "../../../../billing/outOfCredits";
import type { ChatMessage } from "../../../model/conversationChannel";
import { OutOfCreditsNotice } from "./OutOfCreditsNotice";

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
  if (
    message.failureAction === "billing" ||
    message.error === messagesApi.chat_insufficient_credits()
  ) {
    return (
      <OutOfCreditsNotice
        onAddCredits={openUsageBillingSettings}
        onDiscard={() => onDiscard(message.clientRequestId!)}
        onRetry={() => onRetry(message.clientRequestId!)}
      />
    );
  }
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
