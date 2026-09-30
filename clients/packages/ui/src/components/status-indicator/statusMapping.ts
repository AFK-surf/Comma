import {
  visibleTaskStatusBuckets as taskStatusBuckets,
  type TaskStatusBucket,
  type VisibleTaskStatusBucket,
} from "@comma/i18n";
import type { StatusId } from "./StatusIndicator";

/**
 * The single bridge between the canonical task-status buckets (@comma/i18n)
 * and the status-indicator element's hyphenated segment ids.
 */
export const BUCKET_TO_STATUS_ID: Record<VisibleTaskStatusBucket, StatusId> = {
  backlog: "backlog",
  cancelled: "cancel",
  done: "done",
  in_progress: "in-progress",
  needs_review: "needs-review",
};

const STATUS_ID_TO_BUCKET = Object.fromEntries(
  taskStatusBuckets.map((bucket) => [BUCKET_TO_STATUS_ID[bucket], bucket])
) as Record<StatusId, TaskStatusBucket>;

export function taskStatusToIndicatorId(bucket: TaskStatusBucket): StatusId {
  return bucket === "archived" ? "backlog" : BUCKET_TO_STATUS_ID[bucket];
}

export function indicatorIdToTaskStatus(id: StatusId): TaskStatusBucket {
  return STATUS_ID_TO_BUCKET[id];
}
