// A Loop Task's Loop as the Comma API says it (`loop`, sent only for a Task the person asked to repeat or keep
// watching), read once for every client: the `tasks`, `taskSummaries` and `archivedTasks` topics carry what it reads.
// A Task without `loop` is no Loop Task.
import { z } from "zod";
import type {
  TaskLoop,
  TaskLoopCadence,
  TaskLoopReason,
  TaskLoopState,
  TaskRecurrencePattern,
} from "../contract.ts";

const instant = z.number().int().nonnegative();

const cadenceSchema = z.union([
  z.object({ every_minutes: z.number().int().positive() }),
  z.object({
    cron: z.string().min(1).max(256),
    timezone: z.string().min(1).max(256),
  }),
  z.object({ events: z.string().min(1).max(2_048) }),
]);

const pauseReasonSchema = z.enum([
  "waiting",
  "budget",
  "exited",
  "failed",
  "quota",
  "undeliverable",
]);
const endReasonSchema = z.enum([
  "completed",
  "cancelled",
  "failed",
  "max_runs",
  "ends_at",
]);

const loopSchema = z.object({
  state: z.enum(["pending", "active", "paused", "ended"]),
  // A cadence or a reason this client does not know yet leaves only itself unsaid.
  reason: z.unknown().optional(),
  cadence: cadenceSchema.optional().catch(undefined),
  max_runs: z.number().int().positive().optional(),
  ends_at: instant.optional(),
  until: z.string().min(1).max(2_048).optional(),
  started_at: instant,
  wake_count: z.number().int().nonnegative(),
  last_wake_at: instant.optional(),
  next_run_at: instant.optional(),
  ended_at: instant.optional(),
});

/** A Task's `loop` as the Comma API sends it; undefined when it is no Loop's. */
export function taskLoop(wire: unknown): TaskLoop | undefined {
  const parsed = loopSchema.safeParse(wire);
  if (!parsed.success) return undefined;
  const loop = parsed.data;
  const reason = loopReason(loop.state, loop.reason);
  return {
    state: loop.state,
    ...(reason === undefined ? {} : { reason }),
    ...(loop.cadence ? { cadence: readCadence(loop.cadence) } : {}),
    ...(loop.max_runs === undefined ? {} : { maxRuns: loop.max_runs }),
    ...(loop.ends_at === undefined ? {} : { endsAt: loop.ends_at }),
    ...(loop.until === undefined ? {} : { until: loop.until }),
    startedAt: loop.started_at,
    wakeCount: loop.wake_count,
    ...(loop.last_wake_at === undefined ? {} : { lastWakeAt: loop.last_wake_at }),
    ...(loop.next_run_at === undefined ? {} : { nextRunAt: loop.next_run_at }),
    ...(loop.ended_at === undefined ? {} : { endedAt: loop.ended_at }),
  };
}

/** A paused Loop's reason or an ended one's, when it is one this client knows. */
function loopReason(state: TaskLoopState, wire: unknown): TaskLoopReason | undefined {
  const reasons =
    state === "paused"
      ? pauseReasonSchema
      : state === "ended"
        ? endReasonSchema
        : undefined;
  const parsed = reasons?.safeParse(wire);
  return parsed?.success ? parsed.data : undefined;
}

export function readCadence(wire: z.output<typeof cadenceSchema>): TaskLoopCadence {
  if ("every_minutes" in wire)
    return {
      pattern: { kind: "interval", minutes: wire.every_minutes },
      everyMinutes: wire.every_minutes,
    };
  if ("cron" in wire)
    return {
      pattern: cronPattern(wire.cron),
      cron: wire.cron,
      timezone: wire.timezone,
    };
  return { events: wire.events };
}

const CUSTOM: TaskRecurrencePattern = { kind: "custom" };

const MACROS: Record<string, string> = {
  "@hourly": "0 * * * *",
  "@daily": "0 0 * * *",
  "@midnight": "0 0 * * *",
  "@weekly": "0 0 * * 0",
  "@monthly": "0 0 1 * *",
};
const DAY_NAMES = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/** How a cron (5 fields, as the server's Schedules take it) repeats, folded into the plain pattern it is. */
function cronPattern(cron: string): TaskRecurrencePattern {
  const fields = (MACROS[cron.trim().toLowerCase()] ?? cron).trim().split(/\s+/);
  if (fields.length !== 5) return CUSTOM;
  const [minuteField, hourField, dayField, monthField, weekdayField] = fields as [
    string,
    string,
    string,
    string,
    string,
  ];
  if (monthField !== "*") return CUSTOM;
  const everyDay = dayField === "*" && weekdayField === "*";
  const minuteStep = step(minuteField, 60);
  if (minuteStep !== undefined)
    return everyDay && hourField === "*"
      ? { kind: "interval", minutes: minuteStep }
      : CUSTOM;
  const minute = number(minuteField, 0, 59);
  if (minute === undefined) return CUSTOM;
  const hourStep = hourField === "*" ? 1 : step(hourField, 24);
  if (hourStep !== undefined) {
    if (!everyDay) return CUSTOM;
    return hourStep === 1
      ? { kind: "hourly", minute }
      : { kind: "interval", minutes: hourStep * 60 };
  }
  const hour = number(hourField, 0, 23);
  if (hour === undefined) return CUSTOM;
  if (dayField !== "*") {
    // A day of the month and days of the week both named: either fires (cron's rule), no plain pattern.
    const day = weekdayField === "*" ? number(dayField, 1, 31) : undefined;
    return day === undefined ? CUSTOM : { kind: "monthly", day, hour, minute };
  }
  const days = weekdayField === "*" ? [0, 1, 2, 3, 4, 5, 6] : weekdays(weekdayField);
  if (!days) return CUSTOM;
  if (days.length === 7) return { kind: "daily", hour, minute };
  if (days.join() === "1,2,3,4,5") return { kind: "weekdays", hour, minute };
  return { kind: "weekly", days, hour, minute };
}

/** A whole number of the field in `min`…`max`. */
function number(field: string, min: number, max: number): number | undefined {
  if (!/^\d{1,2}$/.test(field)) return undefined;
  const value = Number(field);
  return value >= min && value <= max ? value : undefined;
}

/** `*` stepped by N where N divides `period` evenly (so the runs are evenly spaced): N. */
function step(field: string, period: number): number | undefined {
  const match = /^\*\/(\d{1,2})$/.exec(field);
  if (!match) return undefined;
  const value = Number(match[1]);
  return value >= 1 && value < period && period % value === 0 ? value : undefined;
}

/** Days of the week as a list of days and ranges (0 or 7 Sunday, or names), sorted and each once. */
function weekdays(field: string): number[] | undefined {
  const days = new Set<number>();
  for (const part of field.split(",")) {
    const bounds = part.split("-");
    if (bounds.length > 2) return undefined;
    const from = weekday(bounds[0]!);
    const to = weekday(bounds[1] ?? bounds[0]!);
    if (from === undefined || to === undefined || from > to) return undefined;
    for (let day = from; day <= to; day++) days.add(day % 7);
  }
  return [...days].toSorted((a, b) => a - b);
}

function weekday(token: string): number | undefined {
  const named = DAY_NAMES.indexOf(token.toLowerCase());
  return named === -1 ? number(token, 0, 7) : named;
}
