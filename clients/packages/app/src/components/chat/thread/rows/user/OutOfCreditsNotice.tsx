import { useCommaMessages } from "@comma/i18n/react";
import { CreditNotice } from "../../../../billing/CreditNotice";

/**
 * A send the server refused because the workspace has no credits left. It
 * replaces the generic send-failure row for that one reason: the fix is
 * never "try again later" but "add credits", so the card says what ran out
 * and puts that action first.
 *
 * Same frame, placement and action order as the send-failure row — Add
 * credits and Discard both leave the send behind, Retry resumes it and sits
 * at the far end. The send stays pending on this device until one of them.
 */
export function OutOfCreditsNotice({
  onAddCredits,
  onDiscard,
  onRetry,
}: {
  onAddCredits: () => void;
  onDiscard: () => void;
  onRetry: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <CreditNotice
      title={messages.billing_out_of_credits_title()}
      detail={messages.billing_out_of_credits_detail()}
      testId="chat-out-of-credits"
      actions={
        <>
          <div className="comma-chat-notice-card-actions-group">
            <button
              className="comma-chat-notice-card-action"
              onClick={onAddCredits}
              type="button"
            >
              {messages.chat_add_credits()}
            </button>
            <button
              className="comma-chat-notice-card-action comma-chat-notice-card-action-quiet"
              onClick={onDiscard}
              type="button"
            >
              {messages.common_discard()}
            </button>
          </div>
          <button
            className="comma-chat-notice-card-action"
            onClick={onRetry}
            type="button"
          >
            {messages.common_retry()}
          </button>
        </>
      }
    />
  );
}
