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
import {
  RequestPeople,
  requestPersonKey,
  type RequestPersonTally,
} from "../../tasks/requestPeople";
import { recipientName, senderName, type InboxRequestEntry } from "../TaskRequestInbox";

/** The task lifecycles the rail filters on — the Tasks board's columns. */
export const INBOX_STATUS_BUCKETS: readonly TaskStatusBucket[] =
  TASK_STATUS_COLUMNS.map((column) => column.bucket);

export const INBOX_NO_PLATFORM = "unspecified";
export type InboxPlatformKey = TaskOriginKey | typeof INBOX_NO_PLATFORM;

/**
 * The Request filter's choices: each person who asked something of the person (their waiting requests and the Tasks
 * made of them), each person the person sent requests to (`requestPersonKey`), and every other notification.
 */
export const INBOX_NOT_REQUEST = "none";

/** The people of the loaded requests by way, and how many notifications came from no request. */
export interface InboxRequestCounts {
  from: readonly RequestPersonTally[];
  to: readonly RequestPersonTally[];
  none: number;
}

const itemRequestKey = (item: ProductInboxItem): string =>
  item.origin === "task_request"
    ? requestPersonKey("from", item.requestedBy ?? {})
    : INBOX_NOT_REQUEST;
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
  /** Undefined includes every notification, from a request or not (`InboxRequestCounts`). */
  requests?: ReadonlySet<string> | undefined;
  statuses: ReadonlySet<TaskStatusBucket>;
}

export const unfilteredInbox = (): InboxFilters => ({
  statuses: new Set(INBOX_STATUS_BUCKETS),
});

export const isInboxFiltered = (filters: InboxFilters) =>
  filters.platforms !== undefined ||
  filters.requests !== undefined ||
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
      (filters.requests === undefined || filters.requests.has(itemRequestKey(item))) &&
      (item.kind !== "agent_task" ||
        (filters.statuses.has(taskStatusBucket(item.status)) &&
          (filters.loopRule === undefined ||
            taskLoopRuleKey(item.loop) === filters.loopRule) &&
          (filters.schedules === undefined ||
            filters.schedules.has(inboxScheduleKey(item)))))
  );
}

/**
 * A request's row as the filters read it: one waiting for the person was received and needs them; one they sent is in
 * the status its Task last reported (waiting for its owner is under way, declined or expired ended).
 */
function requestRowFacts(row: InboxRequestEntry): {
  request: string;
  bucket: TaskStatusBucket;
} {
  if (row.kind === "task_request")
    return {
      request: requestPersonKey("from", {
        id: row.request.sender?.id,
        name: senderName(row.request),
      }),
      bucket: "needs_review",
    };
  const { sent } = row;
  return {
    request: requestPersonKey("to", {
      id: sent.workspace?.owner?.id,
      name: recipientName(sent),
    }),
    bucket:
      sent.status === "accepted" && sent.task_status
        ? taskStatusBucket(sent.task_status)
        : sent.status === "pending" || sent.status === "accepted"
          ? "in_progress"
          : "cancelled",
  };
}

/**
 * The request rows the filters keep: by the Request filter and their status. A request has no platform or Loop, so
 * either filter leaves it out.
 */
export function applyInboxRequestFilters<Row extends InboxRequestEntry>(
  rows: readonly Row[],
  filters: InboxFilters
): Row[] {
  return rows.filter((row) => {
    const { request, bucket } = requestRowFacts(row);
    return (
      (filters.requests === undefined || filters.requests.has(request)) &&
      filters.statuses.has(bucket) &&
      filters.platforms === undefined &&
      filters.schedules === undefined &&
      filters.loopRule === undefined
    );
  });
}

/**
 * The loaded notifications and request rows by the Request filter's choices: who sent each, with their avatar, who
 * each sent one went to, and the rest. `unnamed` names a person the server gave no name.
 */
export function countInboxRequests(
  items: readonly ProductInboxItem[],
  rows: readonly InboxRequestEntry[],
  unnamed: string,
  locale: string
): InboxRequestCounts {
  const from = new RequestPeople();
  const to = new RequestPeople();
  let none = 0;
  for (const item of items) {
    if (item.origin !== "task_request") {
      none += 1;
      continue;
    }
    const sender = item.requestedBy;
    from.add(itemRequestKey(item), {
      name: sender?.name || unnamed,
      ...(sender?.avatar
        ? { avatar: { source: "sender-avatar", ...sender.avatar } }
        : {}),
    });
  }
  for (const row of rows) {
    const key = requestRowFacts(row).request;
    if (row.kind === "task_request") {
      const { request, workspace } = row;
      const revision = request.sender?.avatar_id;
      from.add(key, {
        name: senderName(request) || unnamed,
        email: request.sender?.email,
        ...(revision && workspace
          ? {
              avatar: {
                source: "sender-avatar",
                workspace,
                request: request.id,
                revision,
              },
            }
          : {}),
      });
    } else {
      const { sent } = row;
      const owner = sent.workspace?.owner;
      to.add(key, {
        name: recipientName(sent) || unnamed,
        email: owner?.email,
        ...(owner?.avatar_id
          ? {
              avatar: {
                source: "recipient-avatar",
                request: sent.id,
                revision: owner.avatar_id,
              },
            }
          : {}),
      });
    }
  }
  return { from: from.list(locale), to: to.list(locale), none };
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
