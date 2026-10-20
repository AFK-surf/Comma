import { taskLoopRuleKey } from "@comma/core/task-loop-filter";
import { taskStatusBuckets, type TaskStatusBucket } from "@comma/i18n";
import type { ProductInboxItem } from "@comma/core-client";
import {
  TASK_STATUS_COLUMNS,
  taskStatusBucket,
  type TaskStatusCounts,
} from "@comma/ui/components/task-workspace";

import {
  taskLoopFilterKey,
  type TaskLoopFilterKey,
  type TaskLoopFilterCounts,
} from "../../tasks/taskLoopLabels";
import { taskOriginKey, type TaskOriginKey } from "../../tasks/taskOrigin";

/** The task lifecycles the rail filters on — the Tasks board's columns. */
export const INBOX_STATUS_BUCKETS: readonly TaskStatusBucket[] =
  TASK_STATUS_COLUMNS.map((column) => column.bucket);

export const INBOX_NO_PLATFORM = "unspecified";
export type InboxPlatformKey = TaskOriginKey | typeof INBOX_NO_PLATFORM;
export type InboxPlatformCounts = ReadonlyMap<InboxPlatformKey, number>;

/** Do not infer a provider for notifications whose origin is not recognized. */
export const inboxPlatformKey = (item: ProductInboxItem): InboxPlatformKey =>
  taskOriginKey(item.origin) ?? INBOX_NO_PLATFORM;

/** Loop types and one-off Tasks use the same choices as the Tasks page. */
export type InboxScheduleKey = TaskLoopFilterKey;
export type InboxScheduleCounts = TaskLoopFilterCounts;

export const inboxScheduleKey = (item: ProductInboxItem): InboxScheduleKey =>
  taskLoopFilterKey(item.loop);

export interface InboxFilters {
  /** Undefined includes every platform, including unknown or absent origins. */
  platforms?: ReadonlySet<string> | undefined;
  /** Undefined includes every Task, Loop or not. */
  schedules?: ReadonlySet<string> | undefined;
  loopRule?: string | undefined;
  statuses: ReadonlySet<TaskStatusBucket>;
}

export const unfilteredInbox = (): InboxFilters => ({
  statuses: new Set(INBOX_STATUS_BUCKETS),
});

export const isInboxFiltered = (filters: InboxFilters) =>
  filters.platforms !== undefined ||
  filters.schedules !== undefined ||
  filters.loopRule !== undefined ||
  filters.statuses.size < INBOX_STATUS_BUCKETS.length;

/**
 * Status and Loops only narrow tasks. Platform narrows all notifications
 * by their declared origin; missing or unrecognized origins share an
 * Unspecified option.
 */
export function applyInboxFilters(
  items: readonly ProductInboxItem[],
  filters: InboxFilters
): ProductInboxItem[] {
  return items.filter(
    (item) =>
      (filters.platforms === undefined ||
        filters.platforms.has(inboxPlatformKey(item))) &&
      (item.kind !== "agent_task" ||
        (filters.statuses.has(taskStatusBucket(item.status)) &&
          (filters.loopRule === undefined ||
            taskLoopRuleKey(item.loop) === filters.loopRule) &&
          (filters.schedules === undefined ||
            filters.schedules.has(inboxScheduleKey(item)))))
  );
}

export function countInboxTasksByStatus(
  items: readonly ProductInboxItem[]
): TaskStatusCounts {
  const counts = Object.fromEntries(
    taskStatusBuckets.map((bucket) => [bucket, 0])
  ) as TaskStatusCounts;
  for (const item of items) {
    if (item.kind === "agent_task") counts[taskStatusBucket(item.status)] += 1;
  }
  return counts;
}

export function countInboxTasksBySchedule(
  items: readonly ProductInboxItem[]
): InboxScheduleCounts {
  const counts = { scheduled: 0, event_triggered: 0, unknown: 0, not_scheduled: 0 };
  for (const item of items) {
    if (item.kind === "agent_task") counts[inboxScheduleKey(item)] += 1;
  }
  return counts;
}

/** Count the loaded, undeleted notifications before applying either filter. */
export function countInboxItemsByPlatform(
  items: readonly ProductInboxItem[]
): InboxPlatformCounts {
  const counts = new Map<InboxPlatformKey, number>();
  for (const item of items) {
    const origin = inboxPlatformKey(item);
    counts.set(origin, (counts.get(origin) ?? 0) + 1);
  }
  return counts;
}
