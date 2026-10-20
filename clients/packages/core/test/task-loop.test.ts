import { describe, expect, it } from "vitest";
import { taskLoop } from "../src/comma/task-loop.ts";

const STARTED = 1_760_000_000_000;
/** A Loop the Router just asked for: no Background Loop yet, no run. */
const pending = { state: "pending", started_at: STARTED, wake_count: 0 };
const cron = (expression: string) =>
  taskLoop({ ...pending, cadence: { cron: expression, timezone: "UTC" } })?.cadence
    ?.pattern;

describe("a Loop Task's Loop", () => {
  it("reads an active cron Loop with its cadence, runs, next run and end", () => {
    expect(
      taskLoop({
        state: "active",
        cadence: { cron: "0 9 * * *", timezone: "Asia/Shanghai" },
        max_runs: 10,
        ends_at: 1_760_500_000_000,
        until: "PR #12 is merged",
        started_at: STARTED,
        wake_count: 3,
        last_wake_at: 1_760_200_000_000,
        next_run_at: 1_760_250_000_000,
      })
    ).toEqual({
      state: "active",
      cadence: {
        pattern: { kind: "daily", hour: 9, minute: 0 },
        cron: "0 9 * * *",
        timezone: "Asia/Shanghai",
      },
      maxRuns: 10,
      endsAt: 1_760_500_000_000,
      until: "PR #12 is merged",
      startedAt: STARTED,
      wakeCount: 3,
      lastWakeAt: 1_760_200_000_000,
      nextRunAt: 1_760_250_000_000,
    });
  });

  it("reads an interval and an events cadence, and a Loop not yet created", () => {
    expect(taskLoop({ ...pending, cadence: { every_minutes: 60 } })).toEqual({
      state: "pending",
      cadence: { pattern: { kind: "interval", minutes: 60 }, everyMinutes: 60 },
      startedAt: STARTED,
      wakeCount: 0,
    });
    expect(
      taskLoop({
        ...pending,
        state: "active",
        cadence: { events: "new comments on PR #12" },
      })
    ).toEqual({
      state: "active",
      cadence: { events: "new comments on PR #12" },
      startedAt: STARTED,
      wakeCount: 0,
    });
  });

  it("reads why a Loop paused or ended, each reason with its own state", () => {
    for (const reason of [
      "waiting",
      "budget",
      "exited",
      "failed",
      "quota",
      "undeliverable",
    ])
      expect(taskLoop({ ...pending, state: "paused", reason }), reason).toMatchObject({
        state: "paused",
        reason,
      });
    for (const reason of ["completed", "cancelled", "failed", "max_runs", "ends_at"])
      expect(
        taskLoop({ ...pending, state: "ended", reason, ended_at: STARTED + 1 }),
        reason
      ).toMatchObject({ state: "ended", reason, endedAt: STARTED + 1 });
    // A reason of the other state, or of none, is no reason.
    expect(
      taskLoop({ ...pending, state: "paused", reason: "max_runs" })
    ).not.toHaveProperty("reason");
    expect(
      taskLoop({ ...pending, state: "ended", reason: "waiting" })
    ).not.toHaveProperty("reason");
    expect(
      taskLoop({ ...pending, state: "active", reason: "failed" })
    ).not.toHaveProperty("reason");
  });

  it("keeps a Loop whose cadence or reason this client does not know, without them", () => {
    expect(
      taskLoop({
        ...pending,
        state: "ended",
        cadence: { at: STARTED },
        reason: "superseded",
        wake_count: 1,
      })
    ).toEqual({ state: "ended", startedAt: STARTED, wakeCount: 1 });
    // A cron is on the wall clock of its zone: without one it is no cadence.
    expect(taskLoop({ ...pending, cadence: { cron: "0 9 * * *" } })).not.toHaveProperty(
      "cadence"
    );
  });

  it("is no Loop's for an older server's schedule, a one-off Task, or a shape it cannot read", () => {
    for (const wire of [
      undefined,
      null,
      "every day",
      {},
      { command: "Create the weekday workspace summary" },
      { schedule_id: "sch1", command: "Create the weekday workspace summary" },
      {
        state: "active",
        recurrence: { cron: "0 9 * * *", timezone: "Asia/Shanghai" },
        run_count: 3,
        next_run_at: 1_760_250_000_000,
      },
      { ...pending, state: "running" },
      { ...pending, wake_count: -1 },
      { ...pending, started_at: undefined },
      { ...pending, next_run_at: "tomorrow" },
    ])
      expect(taskLoop(wire), JSON.stringify(wire)).toBeUndefined();
  });
});

describe("how a timed Loop repeats", () => {
  it("folds a cron into the plain pattern it is", () => {
    expect(cron("0 9 * * *")).toEqual({ kind: "daily", hour: 9, minute: 0 });
    expect(cron("15 * * * *")).toEqual({ kind: "hourly", minute: 15 });
    expect(cron("0 9 * * 1-5")).toEqual({ kind: "weekdays", hour: 9, minute: 0 });
    expect(cron("0 9 * * MON-FRI")).toEqual({ kind: "weekdays", hour: 9, minute: 0 });
    expect(cron("30 18 * * 3,1")).toEqual({
      kind: "weekly",
      days: [1, 3],
      hour: 18,
      minute: 30,
    });
    expect(cron("0 8 1 * *")).toEqual({ kind: "monthly", day: 1, hour: 8, minute: 0 });
    expect(cron("@weekly")).toEqual({ kind: "weekly", days: [0], hour: 0, minute: 0 });
  });

  it("takes 0 and 7 both for Sunday, in lists and ranges, each day once", () => {
    expect(cron("0 10 * * 0,6")).toEqual({
      kind: "weekly",
      days: [0, 6],
      hour: 10,
      minute: 0,
    });
    expect(cron("0 10 * * 6,7,0")).toMatchObject({ kind: "weekly", days: [0, 6] });
    expect(cron("0 10 * * 5-7")).toMatchObject({ kind: "weekly", days: [0, 5, 6] });
    expect(cron("0 10 * * 0-6")).toEqual({ kind: "daily", hour: 10, minute: 0 });
    expect(cron("0 10 * * 1-5,1")).toEqual({ kind: "weekdays", hour: 10, minute: 0 });
  });

  it("is an interval for steps that divide the hour or the day", () => {
    expect(cron("*/30 * * * *")).toEqual({ kind: "interval", minutes: 30 });
    expect(cron("0 */6 * * *")).toEqual({ kind: "interval", minutes: 360 });
    expect(cron("0 */1 * * *")).toEqual({ kind: "hourly", minute: 0 });
  });

  it("is custom for anything else", () => {
    for (const expression of [
      "*/7 * * * *",
      "0 */5 * * *",
      "*/30 9-17 * * 1-5",
      "0 9-17 * * *",
      "0,30 9 * * *",
      "0 9 1 * 1",
      "0 9 * 1 *",
      "0 9 1,15 * *",
      "0 9 * * */2",
      "0 9 * * 5-1",
      "60 9 * * *",
      "0 24 * * *",
      "0 9 32 * *",
      "0 9 * * 8",
      "0 9 * *",
      "0 9 * * * 2026",
      "@yearly",
    ])
      expect(cron(expression), expression).toEqual({ kind: "custom" });
  });
});
