import type { StopNotice } from "./fundingStops";

/**
 * A stop's further words and the ways out of it, inside the status line's
 * notice card, so every chat surface (Side Chat has no toast) shows the fix
 * where it names the stop.
 */
export function StopNoticeContent({ notice }: { notice: StopNotice }) {
  return (
    <>
      <span className="comma-chat-notice-card-detail">{notice.detail}</span>
      <div className="comma-chat-funding-actions" data-testid="chat-funding-actions">
        {notice.actions.map((action, index) => (
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
    </>
  );
}
