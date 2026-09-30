import type { CompatibilityReason } from "../lib/comparison";
import { m } from "../paraglide/messages.js";
import type { SelectionInvalidReason } from "../selection/CompareSelection";

export function formatCompatibilityReason(reason: CompatibilityReason): string {
  switch (reason.code) {
    case "no-selection":
      return m.compat_no_selection();
    case "dataset-identity":
      return m.compat_dataset();
    case "aggregator-version":
      return m.compat_aggregator();
    case "aggregate-score-key":
      return m.compat_aggregate_score();
    case "item-identity":
      return m.compat_items();
    case "evaluator-score-identity":
      return m.compat_evaluator_score();
  }
}

export function formatCompatibilityReasons(reasons: CompatibilityReason[]): string {
  return reasons.map(formatCompatibilityReason).join("; ");
}

export function formatSelectionInvalidReason(reason: SelectionInvalidReason): string {
  if (reason.code === "missing") return m.selection_missing();
  if (reason.code === "error") return reason.message;
  const status =
    reason.status === "finished"
      ? m.status_finished()
      : reason.status === "running"
        ? m.status_running()
        : m.status_error();
  return m.selection_status_changed({ status });
}
