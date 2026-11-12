import { uiClock } from "@comma/ui/clock";
import { memo, useRef } from "react";
import { Link } from "@tanstack/react-router";
import {
  formatDate,
  formatNumber,
  messages as catalog,
  type CommaLocale,
} from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { ProductInboxItem } from "@comma/core-client";
import { TaskListItem } from "@comma/ui/components/TaskListItem";
import { taskStatusBucket, taskStatusIcon } from "@comma/ui/components/task-workspace";
import { taskLoopFilterKey, taskLoopLabel } from "../tasks/taskLoopLabels";
import { requestPersonKey } from "../tasks/requestPeople";
import {
  TaskRequestChip,
  TaskScheduleChip,
  useOpenTasksFilter,
} from "../tasks/taskChips";
import {
  inboxItemMenuTrigger,
  InboxItemMenuPopover,
  useInboxItemMenu,
} from "./InboxItemMenu";

export type InboxGroupModel<T extends { updatedAt: number } = ProductInboxItem> = {
  items: T[];
  key: string;
  label: string;
};

export const InboxRow = memo(function InboxRow({
  conversationId,
  groupId,
  workspaceId,
  title,
  status,
  updatedAt,
  loop,
  origin,
  requestedBy,
  selected,
  unread,
  onDelete,
  onMarkRead,
  onMarkUnread,
  onOpen,
}: Pick<
  ProductInboxItem,
  "conversationId" | "groupId" | "workspaceId" | "title" | "status" | "updatedAt"
> & {
  /** The row names the Loop's trigger type. */
  loop: ProductInboxItem["loop"];
  origin?: string | undefined;
  /** A Task from a request names who sent it. */
  requestedBy?: ProductInboxItem["requestedBy"];
  selected: boolean;
  unread: boolean;
  minute: number;
  onDelete: () => void;
  onMarkRead: () => void;
  onMarkUnread: () => void;
  onOpen: () => void;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const rowRef = useRef<HTMLAnchorElement | null>(null);
  const menu = useInboxItemMenu();
  const openTasksFilter = useOpenTasksFilter();
  // Every Inbox row is a Task, so it draws the same status glyph as Properties.
  const statusBucket = taskStatusBucket(status);
  const relativeTime = formatCompactRelative(updatedAt, locale);

  return (
    <>
      <Link
        aria-current={selected ? "page" : undefined}
        aria-label={[title, loop ? taskLoopLabel(loop, messages) : undefined]
          .filter(Boolean)
          .join(", ")}
        className="block rounded-xl no-underline outline-none focus-visible:shadow-focus-gray"
        data-task-status={status}
        data-testid="inbox-item"
        onClick={onOpen}
        {...inboxItemMenuTrigger(menu, rowRef)}
        params={{
          conversationId,
          groupId,
          workspaceId,
        }}
        ref={rowRef}
        to="/inbox/$workspaceId/$groupId/$conversationId"
      >
        <TaskListItem
          badges={
            loop || (origin === "task_request" && requestedBy) ? (
              <>
                {loop ? (
                  <TaskScheduleChip
                    loop={loop}
                    iconOnly
                    nested
                    onOpen={() =>
                      openTasksFilter({ schedule: taskLoopFilterKey(loop) })
                    }
                    testId="inbox-item-schedule"
                  />
                ) : null}
                {origin === "task_request" && requestedBy ? (
                  <TaskRequestChip
                    avatar={
                      requestedBy.avatar
                        ? { source: "sender-avatar", ...requestedBy.avatar }
                        : undefined
                    }
                    direction="from"
                    iconOnly
                    name={requestedBy.name}
                    nested
                    onOpen={() =>
                      openTasksFilter({
                        request: requestPersonKey("from", requestedBy),
                      })
                    }
                    testId="inbox-item-request"
                  />
                ) : null}
              </>
            ) : undefined
          }
          dot={unread}
          icon={taskStatusIcon(statusBucket)}
          iconKey={statusBucket}
          layout="sidebar"
          selected={selected || menu.isOpen}
          tail={<span>{relativeTime}</span>}
          title={title}
          titleIdentity={conversationId}
        />
      </Link>
      <InboxItemMenuPopover
        actions={[unread ? "mark-read" : "mark-unread", "delete"]}
        isOpen={menu.isOpen}
        onAction={(action) => {
          if (action === "delete") onDelete();
          else if (action === "mark-unread") onMarkUnread();
          else if (action === "mark-read") onMarkRead();
        }}
        onOpenChange={menu.onOpenChange}
        pointerOffsets={menu.pointerOffsets}
        triggerRef={rowRef}
      />
    </>
  );
});

export function groupInboxItems<T extends { updatedAt: number }>(
  items: T[],
  locale: CommaLocale,
  now = uiClock.now()
) {
  const today = startOfDay(now);
  const yesterday = startOfPreviousDay(now);
  const groups = new Map<string, InboxGroupModel<T>>();

  for (const item of items) {
    const timestamp = normalizeTimestamp(item.updatedAt);
    const key =
      timestamp >= today
        ? "today"
        : timestamp >= yesterday
          ? "yesterday"
          : new Date(timestamp).toISOString().slice(0, 10);
    const current = groups.get(key);
    if (current) {
      current.items.push(item);
    } else {
      const label =
        key === "today"
          ? catalog.inbox_today(undefined, { locale })
          : key === "yesterday"
            ? catalog.inbox_yesterday(undefined, { locale })
            : formatDate(timestamp, locale, { day: "numeric", month: "short" });
      groups.set(key, { key, label, items: [item] });
    }
  }

  return [...groups.values()];
}

export function formatCompactRelative(
  timestamp: number,
  locale: CommaLocale,
  now = uiClock.now()
): string {
  const seconds = Math.max(0, Math.round((now - normalizeTimestamp(timestamp)) / 1000));
  if (seconds < 60) return catalog.inbox_time_now(undefined, { locale });
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return catalog.inbox_time_minutes(
      { formattedCount: formatNumber(minutes, locale) },
      { locale }
    );
  }
  const hours = Math.round(minutes / 60);
  if (hours < 24) {
    return catalog.inbox_time_hours(
      { formattedCount: formatNumber(hours, locale) },
      { locale }
    );
  }
  return catalog.inbox_time_days(
    { formattedCount: formatNumber(Math.round(hours / 24), locale) },
    { locale }
  );
}

export function normalizeTimestamp(timestamp: number) {
  return timestamp > 0 && timestamp < 10_000_000_000 ? timestamp * 1000 : timestamp;
}

function startOfDay(timestamp: number) {
  const date = new Date(timestamp);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

function startOfPreviousDay(timestamp: number) {
  const date = new Date(timestamp);
  date.setDate(date.getDate() - 1);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}
