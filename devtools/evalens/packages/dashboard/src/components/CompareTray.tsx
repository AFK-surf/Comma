import { Link, useLocation, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, GitCompareArrows, Trash2, X } from "lucide-react";
import { compactId } from "../lib/format";
import { useCompareSelection } from "../selection/CompareSelection";
import { useMessages } from "../i18n/locale";
import { formatSelectionInvalidReason } from "../i18n/compatibility";

export function CompareTray() {
  const m = useMessages();
  const { selected, remove, clear, move } = useCompareSelection();
  const location = useLocation();
  const navigate = useNavigate({ from: "/compare" });
  if (selected.length === 0) return null;
  const valid = selected.filter(({ state }) => state === "valid");
  const invalid = selected.filter(({ state }) => state === "invalid");
  const missing = Math.max(0, 2 - valid.length);
  const disabled = missing > 0 || invalid.length > 0;
  const reason =
    invalid.length > 0
      ? m.tray_invalid({ count: invalid.length })
      : missing > 0
        ? m.tray_missing({ count: missing })
        : m.tray_ready();
  const updateCompareUrl = (evalIds: string[]) => {
    if (location.pathname !== "/compare") return;
    void navigate({
      search: (current) => ({
        ...current,
        eval: evalIds,
        itemPage: 1,
        reference:
          current.reference && evalIds.includes(current.reference)
            ? current.reference
            : undefined,
      }),
    });
  };
  return (
    <aside aria-label={m.tray_label()} className="compare-tray">
      <div className="tray-summary">
        <GitCompareArrows size={16} />
        <b>{m.tray_selected({ count: selected.length })}</b>
        <span>{reason}</span>
      </div>
      <div className="tray-items">
        {selected.map((item, index) => (
          <div className={`tray-item tray-${item.state}`} key={item.id}>
            <span>
              <b>{item.entry?.run.experimentName ?? m.tray_unknown()}</b>
              <small>{compactId(item.id)}</small>
              {item.reason && (
                <small className="error-copy">
                  {formatSelectionInvalidReason(item.reason)}
                </small>
              )}
            </span>
            <button
              aria-label={m.tray_move_earlier({ id: item.id })}
              className="tray-icon"
              disabled={index === 0}
              onClick={() => {
                move(item.id, -1);
                const reordered = selected.map(({ id }) => id);
                const [moved] = reordered.splice(index, 1);
                if (moved) reordered.splice(index - 1, 0, moved);
                updateCompareUrl(reordered);
              }}
              title={m.compare_move_left()}
            >
              <ArrowLeft size={13} />
            </button>
            <button
              aria-label={m.tray_move_later({ id: item.id })}
              className="tray-icon"
              disabled={index === selected.length - 1}
              onClick={() => {
                move(item.id, 1);
                const reordered = selected.map(({ id }) => id);
                const [moved] = reordered.splice(index, 1);
                if (moved) reordered.splice(index + 1, 0, moved);
                updateCompareUrl(reordered);
              }}
              title={m.compare_move_right()}
            >
              <ArrowRight size={13} />
            </button>
            <button
              aria-label={m.tray_remove({ id: item.id })}
              className="tray-icon"
              onClick={() => {
                remove(item.id);
                updateCompareUrl(
                  selected.filter(({ id }) => id !== item.id).map(({ id }) => id)
                );
              }}
              title={m.common_remove()}
            >
              <X size={13} />
            </button>
          </div>
        ))}
      </div>
      <button
        aria-label={m.tray_clear()}
        className="secondary-button"
        onClick={() => {
          clear();
          updateCompareUrl([]);
        }}
        title={m.common_clear_all()}
      >
        <Trash2 size={14} /> {m.common_clear()}
      </button>
      {disabled ? (
        <button className="primary-button" disabled title={reason}>
          <GitCompareArrows size={14} /> {m.common_compare()}
        </button>
      ) : (
        <Link
          className="primary-button"
          search={{
            eval: valid.map(({ id }) => id),
            itemPage: 1,
            catalogPage: 1,
            reference: undefined,
          }}
          to="/compare"
        >
          <GitCompareArrows size={14} /> {m.common_compare()}
        </Link>
      )}
    </aside>
  );
}
