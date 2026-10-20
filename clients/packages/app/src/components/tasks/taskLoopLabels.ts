import type { TaskLoop, TaskLoopCadence } from "@comma/core-client";
import {
  formatDate,
  formatList,
  formatNumber,
  formatTimeZoneName,
  type CommaLocale,
} from "@comma/i18n";
import type { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";

type CommaMessages = ReturnType<typeof useCommaMessages>;

export const TASK_LOOP_FILTER_KEYS = [
  "scheduled",
  "event_triggered",
  "unknown",
  "not_scheduled",
] as const;
export type TaskLoopFilterKey = (typeof TASK_LOOP_FILTER_KEYS)[number];
export type TaskLoopFilterCounts = Readonly<Record<TaskLoopFilterKey, number>>;

export function isTaskLoopFilterKey(value: unknown): value is TaskLoopFilterKey {
  return TASK_LOOP_FILTER_KEYS.some((key) => key === value);
}

/**
 * The trigger type of the stored cadence. An ended Loop keeps its type. A
 * cadence this client cannot read is "unknown".
 */
export function taskLoopFilterKey(loop: TaskLoop | undefined): TaskLoopFilterKey {
  return loop ? taskLoopTriggerType(loop.cadence) : "not_scheduled";
}

/** The trigger type of a cadence. One this client cannot read is "unknown". */
export function taskLoopTriggerType(
  cadence: TaskLoopCadence | undefined
): Exclude<TaskLoopFilterKey, "not_scheduled"> {
  if (cadence?.events !== undefined) return "event_triggered";
  if (cadence?.cron !== undefined || cadence?.everyMinutes !== undefined)
    return "scheduled";
  return "unknown";
}

/** One name for each trigger type: on the chip, the filter option and the Properties heading. */
export function taskLoopFilterLabel(
  key: TaskLoopFilterKey,
  messages: CommaMessages
): string {
  switch (key) {
    case "scheduled":
      return messages.task_loop_scheduled();
    case "event_triggered":
      return messages.task_loop_event_triggered();
    case "unknown":
      return messages.task_loop_other();
    case "not_scheduled":
      return messages.tasks_filter_no_loop();
  }
}

export function taskLoopLabel(loop: TaskLoop, messages: CommaMessages): string {
  return taskLoopFilterLabel(taskLoopFilterKey(loop), messages);
}

const counted = (count: number, locale: CommaLocale) => ({
  count,
  formattedCount: formatNumber(count, locale),
});

/** Why a Loop is paused, as one short sentence; undefined for a reason this client does not know. */
export function taskLoopPausedLabel(
  { reason }: Pick<TaskLoop, "reason">,
  messages: CommaMessages
): string | undefined {
  switch (reason) {
    case "waiting":
      return messages.task_loop_paused_waiting();
    case "budget":
      return messages.task_loop_paused_budget();
    case "exited":
      return messages.task_loop_paused_exited();
    case "failed":
      return messages.task_loop_paused_failed();
    case "quota":
      return messages.task_loop_paused_quota();
    case "undeliverable":
      return messages.task_loop_paused_undeliverable();
    default:
      return undefined;
  }
}

/**
 * What wakes a Loop, in words: how it repeats, or the events it waits for. A
 * time of day is the cron's wall clock (its `timezone`), so it is written as
 * is, never converted to the viewer's. A cron no pattern names is shown as
 * written.
 */
export function taskLoopCadenceLabel(
  cadence: TaskLoopCadence,
  messages: CommaMessages,
  locale: CommaLocale
): string {
  if (cadence.events !== undefined) return cadence.events;
  const { pattern } = cadence;
  switch (pattern?.kind) {
    case "interval": {
      if (pattern.minutes % (24 * 60) === 0)
        return messages.task_loop_every_days(
          counted(pattern.minutes / (24 * 60), locale)
        );
      if (pattern.minutes % 60 !== 0)
        return messages.task_loop_every_minutes(counted(pattern.minutes, locale));
      const hours = counted(pattern.minutes / 60, locale);
      const minute = cadence.cron === undefined ? 0 : steppedHourMinute(cadence.cron);
      return minute === 0
        ? messages.task_loop_every_hours(hours)
        : messages.task_loop_every_hours_at({
            ...hours,
            minute: clockMinute(minute, locale),
          });
    }
    case "hourly":
      return messages.task_loop_hourly({ minute: clockMinute(pattern.minute, locale) });
    case "daily":
      return messages.task_loop_daily({ time: wallTime(pattern, locale) });
    case "weekdays":
      return messages.task_loop_weekdays({ time: wallTime(pattern, locale) });
    case "weekly":
      return messages.task_loop_weekly({
        days: formatList(
          pattern.days.map((day) => weekdayName(day, locale)),
          locale,
          { style: "narrow", type: "conjunction" }
        ),
        time: wallTime(pattern, locale),
      });
    case "monthly":
      return messages.task_loop_monthly({
        day: formatNumber(pattern.day, locale),
        time: wallTime(pattern, locale),
      });
    default:
      return cadence.cron ?? "";
  }
}

/**
 * The instant that zone suffixes compare at, and the reader's UTC offset
 * then. A list makes one for all of its rules.
 */
export interface TaskLoopZoneClock {
  now: number;
  readerOffset: string;
}

export function taskLoopZoneClock(now: number = uiClock.now()): TaskLoopZoneClock {
  return { now, readerOffset: utcOffset(now) };
}

/**
 * A trigger rule as a Loop's details show it: the cadence, then the cron's
 * zone as a short offset when that zone is not the reader's. `title` is the
 * hover text and names that zone in full. It is undefined when no zone shows.
 */
export function taskLoopTriggerText(
  cadence: TaskLoopCadence,
  messages: CommaMessages,
  locale: CommaLocale,
  clock: TaskLoopZoneClock = taskLoopZoneClock()
): { text: string; title: string | undefined } {
  const rule = taskLoopCadenceLabel(cadence, messages, locale);
  const zone = taskLoopForeignZone(cadence.timezone, locale, clock);
  return zone
    ? { text: `${rule} · ${zone.offset}`, title: `${rule} · ${zone.name}` }
    : { text: rule, title: undefined };
}

/**
 * A cron's time zone, only when its UTC offset at `clock.now` is not the
 * reader's. Then its wall-clock times are not the reader's. A zone at the
 * reader's offset (an alias such as Asia/Calcutta for Asia/Kolkata, or Hong
 * Kong for Shanghai) gives the reader no information. `offset` reads "GMT+8"
 * and `name` reads "China Standard Time", in the reader's language. The
 * result is undefined for a zone that this runtime's ICU does not know.
 */
function taskLoopForeignZone(
  timezone: string | undefined,
  locale: CommaLocale,
  { now, readerOffset }: TaskLoopZoneClock
): { offset: string; name: string } | undefined {
  if (timezone === undefined) return undefined;
  try {
    if (utcOffset(now, timezone) === readerOffset) return undefined;
    return {
      offset: formatTimeZoneName(now, locale, "shortOffset", timezone),
      name: formatTimeZoneName(now, locale, "longGeneric", timezone),
    };
  } catch (error) {
    // The server accepts any tzdata name. This runtime's ICU may not know it.
    if (error instanceof RangeError) return undefined;
    throw error;
  }
}

/**
 * A zone's UTC offset at `now` ("GMT+08:00"), the runtime's zone when
 * `timeZone` is undefined. It is written in one fixed locale, so offsets
 * compare the same in every language.
 */
function utcOffset(now: number, timeZone?: string): string {
  return formatTimeZoneName(now, "en", "longOffset", timeZone);
}

/**
 * The minute past the hour of a stepped-hour cron ("15 *\/2 * * *"). Its
 * interval pattern keeps only the period. The core folds a cron into an
 * interval of whole hours only when its first field is that minute.
 */
function steppedHourMinute(cron: string): number {
  return Number(cron.trim().split(/\s+/, 1)[0]);
}

/** English writes a clock's minute (":05"). Chinese counts it ("第 5 分"). */
function clockMinute(minute: number, locale: CommaLocale): string {
  return String(minute).padStart(locale === "zh-CN" ? 1 : 2, "0");
}

function wallTime(
  { hour, minute }: { hour: number; minute: number },
  locale: CommaLocale
): string {
  return formatDate(Date.UTC(2000, 0, 1, hour, minute), locale, {
    hour: "numeric",
    minute: "2-digit",
    timeZone: "UTC",
  });
}

/** 0 = Sunday … 6 = Saturday; 1 January 2023 was a Sunday. */
function weekdayName(day: number, locale: CommaLocale): string {
  return formatDate(Date.UTC(2023, 0, 1 + day), locale, {
    timeZone: "UTC",
    weekday: "short",
  });
}
