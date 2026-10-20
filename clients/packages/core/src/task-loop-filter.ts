import { z } from "zod";
import type { TaskLoop, TaskLoopCadence } from "./contract.ts";
import { readCadence } from "./comma/task-loop.ts";

// A filter value, not a Loop identity. Match the saved trigger, never display
// text, execution progress or stop conditions. Two crons share a key only when
// the parsed pattern describes each of them exactly.
const ruleSchema = z.union([
  z.tuple([z.literal("interval"), z.number().int().positive()]),
  z.tuple([z.literal("cron"), z.string().min(1).max(256), z.string().min(1).max(256)]),
  z.tuple([z.literal("events"), z.string().min(1).max(2_048)]),
]);

/** Ended Loops have no current rule; a new Loop on the same Task supplies one. */
export function taskLoopRuleKey(loop: TaskLoop | undefined): string | undefined {
  const cadence = currentRule(loop);
  return cadence && ruleKey(cadence);
}

/**
 * The rule key of a link value, in the form `taskLoopRuleKey` gives the loaded
 * Tasks, so a link with another spelling of the same cron selects that rule.
 */
export function readTaskLoopRuleKey(value: unknown): string | undefined {
  const decoded = readTaskLoopRule(value);
  const cadence = decoded && ruleCadence(decoded);
  return cadence && ruleKey(cadence);
}

function currentRule(loop: TaskLoop | undefined): TaskLoopCadence | undefined {
  return loop?.state === "ended" || !loop?.cadence
    ? undefined
    : ruleCadence(loop.cadence);
}

/** The cadence as its rule names it, a cron in its canonical spelling; undefined without a rule. */
function ruleCadence(cadence: TaskLoopCadence): TaskLoopCadence | undefined {
  if (cadence.events !== undefined || cadence.everyMinutes !== undefined)
    return cadence;
  if (!cadence.cron || !cadence.timezone) return undefined;
  return { ...cadence, cron: canonicalCron(cadence.cron, cadence) };
}

function ruleKey({ events, everyMinutes, cron, timezone }: TaskLoopCadence): string {
  if (events !== undefined) return JSON.stringify(["events", events]);
  if (everyMinutes !== undefined) return JSON.stringify(["interval", everyMinutes]);
  return JSON.stringify(["cron", cron, timezone]);
}

/**
 * One spelling for each cron that a plain pattern describes exactly: `MON-FRI`
 * and `1-5`, `7` and `0` for Sunday, `09` and `9`, an hour step of 1 and `*`.
 * An interval drops the minute offset of a stepped hour, and a custom cron has
 * no pattern, so those keep the written cron with its whitespace collapsed.
 */
function canonicalCron(cron: string, { pattern }: TaskLoopCadence): string {
  switch (pattern?.kind) {
    case "hourly":
      return `${pattern.minute} * * * *`;
    case "daily":
      return `${pattern.minute} ${pattern.hour} * * *`;
    case "weekdays":
      return `${pattern.minute} ${pattern.hour} * * 1-5`;
    case "weekly":
      return `${pattern.minute} ${pattern.hour} * * ${pattern.days.join(",")}`;
    case "monthly":
      return `${pattern.minute} ${pattern.hour} ${pattern.day} * *`;
    default:
      return cron.trim().replace(/\s+/g, " ");
  }
}

/** Decode a bounded URL value, including a selected rule with no loaded matches. */
export function readTaskLoopRule(value: unknown): TaskLoopCadence | undefined {
  // Covers the longest accepted event text even when every character is JSON-escaped.
  if (typeof value !== "string" || value.length > 12_500) return undefined;
  try {
    const parsed = ruleSchema.safeParse(JSON.parse(value));
    if (!parsed.success) return undefined;
    const rule = parsed.data;
    switch (rule[0]) {
      case "interval":
        return readCadence({ every_minutes: rule[1] });
      case "cron":
        return readCadence({ cron: rule[1], timezone: rule[2] });
      case "events":
        return readCadence({ events: rule[1] });
    }
  } catch {
    return undefined;
  }
}

export interface TaskLoopRuleOption {
  key: string;
  /** As the key names it: a cron in its canonical spelling. */
  cadence: TaskLoopCadence;
  count: number;
}

/** One pass over the loaded projection, only when it changes. No detail reads. */
export function countTaskLoopRules(
  tasks: readonly { loop?: TaskLoop | undefined }[]
): ReadonlyMap<string, TaskLoopRuleOption> {
  const rules = new Map<string, TaskLoopRuleOption>();
  for (const { loop } of tasks) {
    const cadence = currentRule(loop);
    if (!cadence) continue;
    const key = ruleKey(cadence);
    const found = rules.get(key);
    if (found) found.count += 1;
    else rules.set(key, { key, cadence, count: 1 });
  }
  return rules;
}
