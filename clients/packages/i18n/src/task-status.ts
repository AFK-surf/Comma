import type { CommaLocale } from "./locale";
import * as messages from "./paraglide/messages.js";

/**
 * Canonical task-status vocabulary. Three layers hang off this one order:
 * raw server statuses fold into these buckets (taskStatusBucket in @comma/ui),
 * the status-indicator element's segment ids map 1:1 from them
 * (statusMapping in @comma/ui), and the display labels below are the single
 * localized name for each bucket.
 */
export const visibleTaskStatusBuckets = [
  "backlog",
  "in_progress",
  "needs_review",
  "done",
  "cancelled",
] as const;

export const taskStatusBuckets = [...visibleTaskStatusBuckets, "archived"] as const;
export type VisibleTaskStatusBucket = (typeof visibleTaskStatusBuckets)[number];

export type TaskStatusBucket = (typeof taskStatusBuckets)[number];

export function taskStatusBucketLabel(
  bucket: TaskStatusBucket,
  locale: CommaLocale
): string {
  switch (bucket) {
    case "archived":
      return messages.tasks_archived(undefined, { locale });
    case "backlog":
      return messages.tasks_backlog(undefined, { locale });
    case "in_progress":
      return messages.tasks_in_progress(undefined, { locale });
    case "needs_review":
      return messages.tasks_needs_review(undefined, { locale });
    case "done":
      return messages.tasks_done(undefined, { locale });
    case "cancelled":
      return messages.tasks_cancelled(undefined, { locale });
  }
}

export function taskActivityLabel(
  status: string | undefined,
  locale: CommaLocale
): string | undefined {
  const normalized = status?.trim().toLowerCase().replaceAll("-", "_");

  switch (normalized) {
    case "meeting_awaiting_recording":
      return messages.meeting_task_awaiting_recording(undefined, { locale });
    case "meeting_recording":
      return messages.meeting_task_recording(undefined, { locale });
    case "meeting_paused":
      return messages.tasks_activity_paused(undefined, { locale });
    case "meeting_saving":
      return messages.meeting_task_saving(undefined, { locale });
    case "meeting_processing":
      return messages.meeting_task_processing(undefined, { locale });
    case undefined:
    case "":
    case "idle":
      return undefined;
    case "starting":
      return messages.tasks_activity_starting(undefined, { locale });
    case "thinking":
      return messages.chat_activity_thinking(undefined, { locale });
    case "execution":
    case "executing":
      return messages.chat_activity_executing(undefined, { locale });
    case "messaging":
      return messages.tasks_activity_messaging(undefined, { locale });
    case "waiting":
      return messages.tasks_activity_waiting(undefined, { locale });
    case "paused":
      return messages.tasks_activity_paused(undefined, { locale });
    case "running_tests":
      return messages.tasks_activity_running_tests(undefined, { locale });
    case "running":
    case "active":
    case "in_progress":
      return messages.tasks_in_progress(undefined, { locale });
    case "working":
      return messages.tasks_activity_working(undefined, { locale });
    case "needs_review":
    case "ready_for_review":
    case "review":
    case "waiting_for_review":
      return messages.tasks_needs_review(undefined, { locale });
    case "completed":
    case "done":
    case "success":
    case "succeeded":
    case "closed":
    case "terminal":
      return messages.tasks_activity_completed(undefined, { locale });
    case "archived":
      return messages.tasks_archived(undefined, { locale });
    case "escalated":
      return messages.tasks_activity_escalated(undefined, { locale });
    case "cancelled":
    case "canceled":
      return messages.tasks_cancelled(undefined, { locale });
    case "failed":
    case "error":
      return messages.tasks_activity_failed(undefined, { locale });
    case "open":
    case "pending":
    case "queued":
    case "backlog":
      return messages.tasks_backlog(undefined, { locale });
    default:
      return messages.tasks_activity_unknown(undefined, { locale });
  }
}
