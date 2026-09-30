/**
 * Reserves the image group's footprint before its previews exist. It mirrors
 * the deck's own geometry — a collapsed stack paints one card, an expanded or
 * non-stackable group paints every card — so the swap to the real group moves
 * nothing.
 */
export function ChatImageGroupPlaceholder({
  count,
  expanded,
}: {
  count: number;
  expanded: boolean;
}) {
  const stackable = count > 3;
  const isExpanded = stackable ? expanded : true;
  const painted = isExpanded ? count : 1;
  return (
    <div
      aria-hidden
      className="chat-panel-image-group"
      data-comma-image-group-placeholder=""
    >
      {stackable ? (
        <span className="chat-panel-image-group-toggle">
          <span className="chat-panel-image-group-toggle-label">
            <span className="chat-panel-image-group-toggle-text">{count}</span>
          </span>
        </span>
      ) : null}
      <div
        className="chat-panel-image-group-cards"
        data-expanded={isExpanded ? "true" : "false"}
      >
        {Array.from({ length: painted }, (_, index) => (
          <div className="chat-panel-image-group-card" key={index} />
        ))}
      </div>
    </div>
  );
}
