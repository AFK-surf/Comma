import { describe, expect, it } from "vitest";
import type { TaskLoop } from "../src/contract.ts";
import { taskLoop } from "../src/comma/task-loop.ts";
import {
  countTaskLoopRules,
  readTaskLoopRule,
  readTaskLoopRuleKey,
  taskLoopRuleKey,
} from "../src/task-loop-filter.ts";

const at = (minute: number, timezone = "Asia/Singapore"): TaskLoop =>
  taskLoop({
    state: "active",
    started_at: 1,
    wake_count: 0,
    cadence: { cron: `${minute} 9 * * *`, timezone },
  })!;

const offsetCron = (minute: number) =>
  taskLoop({
    state: "active",
    started_at: 1,
    wake_count: 0,
    cadence: { cron: `${minute} */2 * * *`, timezone: "UTC" },
  })!;

const shanghai = (cron: string) =>
  taskLoop({
    state: "active",
    started_at: 1,
    wake_count: 0,
    cadence: { cron, timezone: "Asia/Shanghai" },
  })!;

describe("Loop trigger rule filters", () => {
  it("groups the same saved trigger regardless of progress, limits or pause, leaves out ended Loops, and separates minutes and timezones", () => {
    const morning = at(0);
    const tasks = [
      morning,
      {
        ...morning,
        state: "paused" as const,
        wakeCount: 4,
        maxRuns: 10,
        nextRunAt: 123,
      },
      at(1),
      at(2),
      at(0, "Europe/London"),
      { ...morning, state: "ended" as const },
    ].map((loop) => ({ loop }));
    const counts = countTaskLoopRules([...tasks, {}]);
    expect(
      [...counts.values()].map(({ cadence, count }) => [
        cadence.cron,
        cadence.timezone,
        count,
      ])
    ).toEqual([
      ["0 9 * * *", "Asia/Singapore", 2],
      ["1 9 * * *", "Asia/Singapore", 1],
      ["2 9 * * *", "Asia/Singapore", 1],
      ["0 9 * * *", "Europe/London", 1],
    ]);
    const key = taskLoopRuleKey(morning);
    expect(tasks.filter((task) => taskLoopRuleKey(task.loop) === key)).toEqual(
      tasks.slice(0, 2)
    );
    expect(taskLoopRuleKey({ ...morning, state: "ended" })).toBeUndefined();
    expect(taskLoopRuleKey({ ...morning, cadence: at(2).cadence })).toBe(
      taskLoopRuleKey(at(2))
    );
  });

  it("merges the spellings of one plain cron pattern into one rule, also from a link", () => {
    for (const [cron, other] of [
      ["0 9 * * 1-5", "0 9 * * MON-FRI"],
      ["0 9 * * 0", "0 9 * * 7"],
      ["0 9 * * *", "00 09 * * *"],
      ["5 * * * *", "5 */1 * * *"],
    ] as const) {
      const counts = countTaskLoopRules([
        { loop: shanghai(cron) },
        { loop: shanghai(other) },
      ]);
      expect([...counts.values()].map(({ count }) => count)).toEqual([2]);
      expect(
        readTaskLoopRuleKey(JSON.stringify(["cron", other, "Asia/Shanghai"]))
      ).toBe(taskLoopRuleKey(shanghai(cron)));
    }
  });

  it("keeps event content and exact cron offsets distinct without interpreting their meaning", () => {
    const event = { ...at(0), cadence: { events: "PR #1 updated" } };
    const other = { ...event, cadence: { events: "PR #2 updated" } };
    expect(
      countTaskLoopRules([{ loop: event }, { loop: other }, { loop: event }]).size
    ).toBe(2);
    expect(offsetCron(0).cadence?.pattern).toEqual(offsetCron(15).cadence?.pattern);
    expect(taskLoopRuleKey(offsetCron(0))).not.toEqual(taskLoopRuleKey(offsetCron(15)));
    expect(taskLoopRuleKey({ ...event, cadence: { everyMinutes: 120 } })).not.toBe(
      taskLoopRuleKey(offsetCron(0))
    );
    for (const loop of [
      event,
      other,
      at(0),
      offsetCron(15),
      {
        ...event,
        cadence: {
          everyMinutes: 30,
          pattern: { kind: "interval" as const, minutes: 30 },
        },
      },
    ]) {
      expect(readTaskLoopRule(taskLoopRuleKey(loop))).toEqual(loop.cadence);
    }
  });

  it("rejects malformed or oversized links and decodes a valid rule without loaded Tasks", () => {
    for (const value of [
      null,
      "not-json",
      '["cron","0 9 * * *"]',
      '["interval",0]',
      '["events","x","extra"]',
      "x".repeat(12_501),
    ]) {
      expect(readTaskLoopRule(value)).toBeUndefined();
      expect(readTaskLoopRuleKey(value)).toBeUndefined();
    }
    expect(readTaskLoopRule('["cron","2 9 * * *","Asia/Singapore"]')?.pattern).toEqual({
      kind: "daily",
      hour: 9,
      minute: 2,
    });
  });
});
