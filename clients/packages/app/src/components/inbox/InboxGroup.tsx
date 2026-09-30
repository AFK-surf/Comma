import { memo, useRef } from "react";
import { Link } from "@tanstack/react-router";
import {
  contentFreshnessLabel,
  formatDate,
  formatNumber,
  messages as catalog,
  type CommaLocale,
} from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import type { ProductInboxItem } from "@comma/native-bridge";
import {
  TaskListItem,
  getMenuPointerOffsets,
  taskStatusBucket,
  taskStatusIcon,
} from "@comma/ui";
import { InboxItemMenuPopover, useInboxItemMenu } from "./InboxItemMenu";

export type InboxGroupModel = {
  items: ProductInboxItem[];
  key: string;
  label: string;
};

export const InboxRow = memo(function InboxRow({
  conversationId,
  groupId,
  workspaceId,
  title,
  status,
  freshness,
  updatedAt,
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
  freshness: ProductInboxItem["freshness"];
  selected: boolean;
  unread: boolean;
  minute: number;
  onDelete: () => void;
  onMarkRead: () => void;
  onMarkUnread: () => void;
  onOpen: () => void;
}) {
  const locale = useCommaLocale();
  const rowRef = useRef<HTMLAnchorElement | null>(null);
  const menu = useInboxItemMenu();
  // Every Inbox row is a Task, so it draws the same status glyph as Properties.
  const statusBucket = taskStatusBucket(status);
  const freshnessLabel = contentFreshnessLabel(freshness, locale);
  const relativeTime = formatCompactRelative(updatedAt, locale);

  return (
    <>
      <Link
        aria-current={selected ? "page" : undefined}
        aria-haspopup="menu"
        aria-label={`${title}${freshnessLabel ? `, ${freshnessLabel}` : ""}`}
        className="block rounded-xl no-underline outline-none focus-visible:shadow-focus-gray"
        data-freshness={freshness}
        data-task-status={status}
        data-testid="inbox-item"
        onClick={onOpen}
        onContextMenu={(event) => {
          if (!rowRef.current) return;
          event.preventDefault();
          menu.open(
            getMenuPointerOffsets(rowRef.current, event.clientX, event.clientY)
          );
        }}
        onKeyDown={(event) => {
          if (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10")) {
            return;
          }
          event.preventDefault();
          menu.open(null);
        }}
        params={{
          conversationId,
          groupId,
          workspaceId,
        }}
        ref={rowRef}
        to="/inbox/$workspaceId/$groupId/$conversationId"
      >
        <TaskListItem
          dot={unread}
          icon={taskStatusIcon(statusBucket)}
          iconKey={statusBucket}
          layout="sidebar"
          selected={selected || menu.isOpen}
          tail={
            <span className="flex items-center gap-xs">
              {freshnessLabel ? (
                <span
                  className={
                    freshness === "stale"
                      ? "text-fg-warning-secondary"
                      : "text-tertiary"
                  }
                >
                  {freshnessLabel}
                </span>
              ) : null}
              <span>{relativeTime}</span>
            </span>
          }
          title={title}
        />
      </Link>
      <InboxItemMenuPopover
        isOpen={menu.isOpen}
        onAction={(action) => {
          if (action === "delete") onDelete();
          else if (action === "mark-unread") onMarkUnread();
          else if (action === "mark-read") onMarkRead();
        }}
        onOpenChange={menu.onOpenChange}
        pointerOffsets={menu.pointerOffsets}
        triggerRef={rowRef}
        unread={unread}
      />
    </>
  );
});

export function groupInboxItems(
  items: ProductInboxItem[],
  locale: CommaLocale,
  now = Date.now()
) {
  const today = startOfDay(now);
  const yesterday = startOfPreviousDay(now);
  const groups = new Map<string, InboxGroupModel>();

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
  now = Date.now()
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

function normalizeTimestamp(timestamp: number) {
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
