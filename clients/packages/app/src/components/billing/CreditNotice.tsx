import { GaugeIcon } from "@comma/ui";
import type { ReactNode } from "react";

export function CreditNotice({
  title,
  detail,
  actions,
  testId,
  tone = "error",
}: {
  title: string;
  detail: string;
  actions: ReactNode;
  testId: string;
  tone?: "info" | "warning" | "error";
}) {
  return (
    <div
      className={`comma-chat-notice-card comma-chat-failed-row comma-chat-out-of-credits${tone !== "error" ? " comma-chat-credit-warning" : ""}`}
      data-testid={testId}
      data-tone={tone}
      role={tone === "error" ? "alert" : "status"}
    >
      <GaugeIcon aria-hidden className="comma-chat-notice-card-icon" />
      <div className="comma-chat-notice-card-content">
        <span className="comma-chat-notice-card-copy">{title}</span>
        <span className="comma-chat-out-of-credits-detail">{detail}</span>
        <div className="comma-chat-notice-card-actions">{actions}</div>
      </div>
    </div>
  );
}
