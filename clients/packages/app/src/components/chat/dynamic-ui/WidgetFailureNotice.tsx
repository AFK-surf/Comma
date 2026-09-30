import { useCommaMessages } from "@comma/i18n/react";
import { ExclamationTriangleIcon } from "@comma/ui";

/**
 * Why a widget is not showing. `load` means its content never arrived, so
 * the network is the likely cause. `display` means the content arrived but
 * the runtime could not show it, so the text answer above is the fallback.
 */
export type WidgetFailure = { kind: "load" | "display"; reason: string };

/**
 * A widget that failed wears the same chat notice card as a failed send:
 * one readable sentence, what to do next, and Retry. The internal reason
 * stays out of the copy and is kept on `data-reason` for diagnosis.
 */
export function WidgetFailureNotice({
  failure,
  onRetry,
}: {
  failure: WidgetFailure;
  onRetry: () => void;
}) {
  const messages = useCommaMessages();
  const load = failure.kind === "load";
  return (
    <div
      className="comma-chat-notice-card comma-chat-widget-failure"
      data-reason={failure.reason}
      data-testid="dynamic-ui-failure"
      role="alert"
    >
      <ExclamationTriangleIcon aria-hidden className="comma-chat-notice-card-icon" />
      <div className="comma-chat-notice-card-content">
        <span className="comma-chat-notice-card-copy">
          {load ? messages.chat_ui_load_failed() : messages.chat_ui_display_failed()}
        </span>
        <span className="comma-chat-notice-card-detail">
          {load
            ? messages.chat_ui_load_failed_detail()
            : messages.chat_ui_display_failed_detail()}
        </span>
      </div>
      <button className="comma-chat-notice-card-action" onClick={onRetry} type="button">
        {messages.common_retry()}
      </button>
    </div>
  );
}
