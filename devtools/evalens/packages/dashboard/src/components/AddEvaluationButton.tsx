import { GitCompareArrows, X } from "lucide-react";
import { useEffect, useId, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { EvalCatalogEntry, RunSummary } from "../data/types";
import {
  useCompareSelection,
  type CandidateCompatibility,
} from "../selection/CompareSelection";
import { useMessages } from "../i18n/locale";

export function AddEvaluationButton({
  entry,
  compact = false,
}: {
  entry: EvalCatalogEntry;
  compact?: boolean;
}) {
  const m = useMessages();
  return (
    <EvaluationToggleButton
      addLabel={m.add_label({ id: entry.id })}
      compact={compact}
      entry={entry}
    />
  );
}

export function AddLatestRunEvaluationButton({ run }: { run: RunSummary }) {
  const m = useMessages();
  if (!run.latestFinishedEvaluation) {
    return (
      <CompareAction
        ariaLabel={m.add_latest_label({ id: run.id })}
        disabled
        reason={run.evalCount === 0 ? m.add_run_empty() : m.add_latest_empty()}
      >
        <GitCompareArrows size={14} />
      </CompareAction>
    );
  }
  return (
    <EvaluationToggleButton
      addLabel={m.add_latest_label({ id: run.id })}
      compact
      entry={run.latestFinishedEvaluation}
    />
  );
}

function EvaluationToggleButton({
  entry,
  compact,
  addLabel,
}: {
  entry: EvalCatalogEntry;
  compact: boolean;
  addLabel: string;
}) {
  const m = useMessages();
  const { add, checkCompatibility, remove, selected } = useCompareSelection();
  const isSelected = selected.some(({ id }) => id === entry.id);
  const [compatibility, setCompatibility] = useState<
    CandidateCompatibility | { compatible: undefined }
  >({ compatible: undefined });

  useEffect(() => {
    if (isSelected) {
      setCompatibility({ compatible: true });
      return;
    }
    let cancelled = false;
    setCompatibility({ compatible: undefined });
    void checkCompatibility(entry).then((result) => {
      if (!cancelled) setCompatibility(result);
    });
    return () => {
      cancelled = true;
    };
  }, [checkCompatibility, entry, isSelected]);

  const disabled = !isSelected && compatibility.compatible !== true;
  const reason =
    compatibility.compatible === false
      ? compatibility.reason
      : compatibility.compatible === undefined
        ? m.common_loading()
        : "";
  return (
    <CompareAction
      ariaLabel={isSelected ? m.tray_remove({ id: entry.id }) : addLabel}
      className={compact ? "icon-button" : "secondary-button"}
      disabled={disabled}
      onClick={() => {
        if (isSelected) {
          remove(entry.id);
          return;
        }
        void add(entry).then((result) => {
          if (!result.ok) {
            setCompatibility({ compatible: false, reason: result.message });
          }
        });
      }}
      reason={disabled ? reason : undefined}
      title={isSelected ? m.common_remove() : m.add_action()}
    >
      {isSelected ? <X size={14} /> : <GitCompareArrows size={14} />}
      {!compact && (isSelected ? m.common_remove() : m.add_button())}
    </CompareAction>
  );
}

function CompareAction({
  ariaLabel,
  children,
  className = "icon-button",
  disabled = false,
  onClick,
  reason,
  title,
}: {
  ariaLabel: string;
  children: ReactNode;
  className?: string;
  disabled?: boolean;
  onClick?: () => void;
  reason?: string;
  title?: string;
}) {
  const tooltipId = useId();
  const [tooltipPosition, setTooltipPosition] = useState<{
    left: number;
    top: number;
  }>();
  const showTooltip = (target: HTMLElement) => {
    if (!reason) return;
    const bounds = target.getBoundingClientRect();
    setTooltipPosition({
      left: Math.max(8, Math.min(bounds.left, globalThis.innerWidth - 288)),
      top: bounds.bottom + 6,
    });
  };
  return (
    <span
      aria-describedby={reason ? tooltipId : undefined}
      className="compare-action"
      onBlur={() => setTooltipPosition(undefined)}
      onFocus={(event) => showTooltip(event.currentTarget)}
      onMouseEnter={(event) => showTooltip(event.currentTarget)}
      onMouseLeave={() => setTooltipPosition(undefined)}
      tabIndex={reason ? 0 : undefined}
    >
      <button
        aria-label={ariaLabel}
        className={className}
        disabled={disabled}
        onClick={onClick}
        title={reason ? undefined : title}
        type="button"
      >
        {children}
      </button>
      {reason &&
        tooltipPosition &&
        createPortal(
          <span
            className="compare-action-tooltip"
            id={tooltipId}
            role="tooltip"
            style={tooltipPosition}
          >
            {reason}
          </span>,
          document.body
        )}
    </span>
  );
}
