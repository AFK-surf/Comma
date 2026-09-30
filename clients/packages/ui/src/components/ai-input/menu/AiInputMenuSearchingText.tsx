import { aiInputMenuStateRow } from "../styles";

/**
 * "Searching..." with the Home briefing's "Generating..." sweep: a quaternary
 * body with a primary shine gliding through on the shared loading-shine
 * cadence (`.comma-ai-input-menu-searching-text`, ai-input-menu.css).
 */
export const AiInputMenuSearchingText = ({ label }: { label: string }) => (
  <span
    className="comma-ai-input-menu-searching-text min-w-0 truncate"
    data-shimmer="true"
  >
    {label}
  </span>
);

/** The menu's trailing searching row, keeping the item grid so states never reflow. */
export const AiInputMenuSearchingRow = ({ label }: { label: string }) => (
  <div className={aiInputMenuStateRow} data-testid="ai-input-menu-searching">
    <AiInputMenuSearchingText label={label} />
  </div>
);
