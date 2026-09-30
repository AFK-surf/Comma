// Canonical bucket vocabulary lives in @comma/i18n; this module folds raw
// server statuses into it.
export { taskStatusBuckets, type TaskStatusBucket } from "@comma/i18n";
import type { TaskStatusBucket } from "@comma/i18n";

// Keep polling tied to authoritative Conversation statuses plus the aliases
// already accepted by the Inbox contract. Display-only legacy aliases below
// must not silently widen lifecycle behavior.
const POLLING_TERMINAL_STATUSES = new Set([
  "archived",
  "canceled",
  "cancelled",
  "completed",
  "done",
  "escalated",
  "failed",
  "ready_for_review",
  "succeeded",
]);

export function normalizeTaskStatus(status: string): string {
  return status.trim().toLowerCase();
}

export function isPollingTerminalTaskStatus(status: string): boolean {
  return POLLING_TERMINAL_STATUSES.has(normalizeTaskStatus(status));
}

export function taskStatusBucket(status: string): TaskStatusBucket {
  const normalized = normalizeTaskStatus(status);
  if (normalized === "archived") return "archived";
  if (["cancelled", "canceled", "failed", "error"].includes(normalized)) {
    return "cancelled";
  }
  if (
    ["closed", "completed", "done", "success", "succeeded", "terminal"].includes(
      normalized
    )
  ) {
    return "done";
  }
  if (
    [
      "escalated",
      "needs_review",
      "ready_for_review",
      "review",
      "waiting_for_review",
    ].includes(normalized)
  ) {
    return "needs_review";
  }
  if (["active", "in_progress", "running", "working"].includes(normalized)) {
    return "in_progress";
  }
  return "backlog";
}
