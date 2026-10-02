// The canonical bucket vocabulary, and the fold of raw server statuses into it,
// live in @comma/i18n, where Electron Main reads them too.
export {
  normalizeTaskStatus,
  taskStatusBucket,
  taskStatusBuckets,
  type TaskStatusBucket,
} from "@comma/i18n";
import { normalizeTaskStatus } from "@comma/i18n";

// Keep polling tied to authoritative Conversation statuses plus the aliases
// already accepted by the Inbox contract. Display-only legacy aliases in
// taskStatusBucket must not silently widen lifecycle behavior.
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

export function isPollingTerminalTaskStatus(status: string): boolean {
  return POLLING_TERMINAL_STATUSES.has(normalizeTaskStatus(status));
}
