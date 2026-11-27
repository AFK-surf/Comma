import type { CommaLocale } from "@comma/i18n";
import type { useCommaMessages } from "@comma/i18n/react";
import type { TaskFeedMilestone } from "./types";

type Messages = ReturnType<typeof useCommaMessages>;

export function normalizeEpochMs(timestamp: number | undefined): number | undefined {
  if (timestamp === undefined || !Number.isFinite(timestamp) || timestamp <= 0)
    return undefined;
  return timestamp < 10_000_000_000 ? timestamp * 1_000 : timestamp;
}

/**
 * Orders milestones strictly from newest to oldest. Milestones carrying
 * timestamps sort descending by `at`; ties or untimestamped items preserve
 * reverse emission order so the latest step stays at the top.
 */
export function sortMilestonesNewestFirst(
  milestones: readonly TaskFeedMilestone[]
): TaskFeedMilestone[] {
  return milestones
    .map((milestone, index) => ({
      milestone,
      index,
      ms: normalizeEpochMs(milestone.at),
    }))
    .toSorted((a, b) => {
      if (a.ms !== undefined && b.ms !== undefined && a.ms !== b.ms) {
        return b.ms - a.ms;
      }
      if (a.ms !== undefined && b.ms === undefined) return -1;
      if (a.ms === undefined && b.ms !== undefined) return 1;
      return b.index - a.index;
    })
    .map((item) => item.milestone);
}

export function formatRelativeFeedTime(
  timestamp: number | undefined,
  nowMs: number,
  locale: CommaLocale,
  messages: Messages
): string {
  const ms = normalizeEpochMs(timestamp);
  if (ms === undefined) return "";
  const diffMs = Math.max(0, nowMs - ms);
  const minutes = Math.floor(diffMs / 60_000);
  if (minutes < 1) return messages.task_feed_just_now();
  if (minutes < 60) return messages.task_feed_minutes_ago({ count: String(minutes) });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return messages.task_feed_hours_ago({ count: String(hours) });
  const days = Math.floor(hours / 24);
  if (days < 7) return messages.task_feed_days_ago({ count: String(days) });
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
  }).format(new Date(ms));
}

export function formatFullFeedTime(
  timestamp: number | undefined,
  locale: CommaLocale
): string | undefined {
  const ms = normalizeEpochMs(timestamp);
  if (ms === undefined) return undefined;
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(ms));
}

export function feedDayKey(timestamp: number | undefined): string {
  const ms = normalizeEpochMs(timestamp);
  if (ms === undefined) return "";
  const d = new Date(ms);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

export function formatFeedDayHeading(
  timestamp: number | undefined,
  nowMs: number,
  locale: CommaLocale,
  messages: Messages
): string {
  const ms = normalizeEpochMs(timestamp);
  if (ms === undefined) return "";
  const target = new Date(ms);
  const today = new Date(nowMs);
  const startOfToday = new Date(
    today.getFullYear(),
    today.getMonth(),
    today.getDate()
  ).getTime();
  const startOfTarget = new Date(
    target.getFullYear(),
    target.getMonth(),
    target.getDate()
  ).getTime();
  const dayDiff = Math.round((startOfToday - startOfTarget) / 86_400_000);
  if (dayDiff === 0) return messages.task_feed_today();
  if (dayDiff === 1) return messages.task_feed_yesterday();
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
  }).format(target);
}
