import { useLayoutEffect, useRef } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import type { CommaApiClient } from "../../api";
import { CreditNotice } from "./CreditNotice";
import { openUsageBillingSettings } from "./outOfCredits";
import { useCreditWarning } from "./useCreditWarning";

export function CreditWarningNotice({
  api,
  workspaceId,
  active,
  onHeightChange,
}: {
  api: CommaApiClient | undefined;
  workspaceId: string | undefined;
  active: boolean;
  onHeightChange?: ((height: number) => void) | undefined;
}) {
  const messages = useCommaMessages();
  const { warning, dismiss } = useCreditWarning(api, workspaceId, active);
  const frame = useRef<HTMLDivElement>(null);
  const visible = Boolean(warning);
  useLayoutEffect(() => {
    if (!onHeightChange) return;
    const element = frame.current;
    if (!element) {
      onHeightChange(0);
      return;
    }
    const report = () => onHeightChange(element.getBoundingClientRect().height);
    report();
    const observer = new ResizeObserver(report);
    observer.observe(element);
    return () => observer.disconnect();
  }, [onHeightChange, visible]);
  if (!warning) return null;
  return (
    <div ref={frame} className="comma-chat-credit-warning-frame">
      <CreditNotice
        tone={
          warning.threshold === 0
            ? "error"
            : warning.threshold === 50
              ? "info"
              : "warning"
        }
        testId="chat-credit-warning"
        title={
          warning.threshold === 0
            ? messages.billing_out_of_credits_title()
            : messages.billing_low_credits_title({ percent: warning.percent })
        }
        detail={
          warning.threshold === 0
            ? messages.billing_out_of_credits_detail()
            : warning.threshold === 50
              ? messages.billing_credits_reminder_detail()
              : messages.billing_low_credits_detail()
        }
        actions={
          <>
            <button
              className="comma-chat-notice-card-action"
              onClick={openUsageBillingSettings}
              type="button"
            >
              {warning.threshold === 50
                ? messages.settings_usage_billing()
                : messages.chat_add_credits()}
            </button>
            <button
              className="comma-chat-notice-card-action comma-chat-notice-card-action-quiet"
              onClick={dismiss}
              type="button"
            >
              {messages.common_close()}
            </button>
          </>
        }
      />
    </div>
  );
}
