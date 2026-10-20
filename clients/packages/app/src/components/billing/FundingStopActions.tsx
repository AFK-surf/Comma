import { useCommaLocale } from "@comma/i18n/react";
import type { ChatParticipantStatus } from "@comma/core/chat";
import { fundingStopActions, fundingStopKind } from "./fundingStops";

/**
 * The ways out of a funding stop, under the status line that names it. Side
 * Chat has no toast, so this is where its members find the fix; the main
 * window keeps it after its toast is dismissed.
 */
export function FundingStopActions({
  participantStatuses,
}: {
  participantStatuses: readonly ChatParticipantStatus[];
}) {
  const locale = useCommaLocale();
  const stop = participantStatuses.find(
    (status) => status.state === "error" && fundingStopKind(status.issue)
  );
  const kind = stop && fundingStopKind(stop.issue, stop.issueDetail);
  if (!stop || !kind) return null;
  return (
    <div className="comma-chat-funding-actions" data-testid="chat-funding-actions">
      {fundingStopActions(kind, stop.issueDetail, locale).map((action, index) => (
        <button
          className={`comma-chat-notice-card-action${
            index > 0 ? " comma-chat-notice-card-action-quiet" : ""
          }`}
          key={action.label}
          onClick={action.run}
          type="button"
        >
          {action.label}
        </button>
      ))}
    </div>
  );
}
