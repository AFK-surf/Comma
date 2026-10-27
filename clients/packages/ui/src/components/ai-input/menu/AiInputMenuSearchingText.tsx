import { aiInputMenuStateRow } from "../styles";

/**
 * "Searching..." with the Home briefing's "Generating..." sweep: the shared
 * loading shine (`.comma-shiny-text`, styles.css).
 */
export const AiInputMenuSearchingText = ({ label }: { label: string }) => (
  <span className="comma-ai-input-menu-searching-text comma-shiny-text min-w-0 truncate">
    {label}
  </span>
);

/** The menu's trailing searching row, keeping the item grid so states never reflow. */
export const AiInputMenuSearchingRow = ({ label }: { label: string }) => (
  <div className={aiInputMenuStateRow} data-testid="ai-input-menu-searching">
    <AiInputMenuSearchingText label={label} />
  </div>
);
