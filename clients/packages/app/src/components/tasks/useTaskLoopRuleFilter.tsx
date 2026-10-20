import {
  readTaskLoopRule,
  type TaskLoopRuleOption,
} from "@comma/core/task-loop-filter";
import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { InfinityIcon } from "@comma/ui/components/icons";
import type {
  TaskFilterOption,
  TaskFilterSection,
} from "@comma/ui/components/task-workspace";
import { useMemo } from "react";
import {
  taskLoopFilterLabel,
  taskLoopTriggerText,
  taskLoopTriggerType,
  taskLoopZoneClock,
} from "./taskLoopLabels";

type CommaMessages = ReturnType<typeof useCommaMessages>;

const ALL_TASKS = "all";

/**
 * Both lists use the same single-rule picker. All tasks clears this dimension.
 * The section changes only when its rules, selection or `onChange` change, so
 * pass a stable `onChange`.
 */
export function useTaskLoopRuleFilter(
  rules: ReadonlyMap<string, TaskLoopRuleOption>,
  taskCount: number,
  selected: string | undefined,
  onChange: (key: string | undefined) => void
): TaskFilterSection | undefined {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  return useMemo(() => {
    if (rules.size === 0 && !selected) return undefined;
    const entries = [...rules.values()];
    // A selected rule with no loaded Task stays, so the picker shows what filters the list.
    if (selected && !rules.has(selected)) {
      const cadence = readTaskLoopRule(selected);
      if (cadence) entries.push({ key: selected, cadence, count: 0 });
    }
    return {
      id: "loopRule",
      icon: <InfinityIcon />,
      label: messages.tasks_filter_loop_rule(),
      options: [
        { id: ALL_TASKS, label: messages.tasks_all(), count: taskCount },
        ...ruleOptions(entries, messages, locale),
      ],
      selected: new Set([selected ?? ALL_TASKS]),
      narrowed: selected !== undefined,
      selectionMode: "single",
      onChange: (keys) => {
        const key = keys.values().next().value;
        onChange(key === ALL_TASKS ? undefined : key);
      },
    };
  }, [rules, selected, taskCount, messages, locale, onChange]);
}

interface RuleRow extends TaskFilterOption {
  cadence: TaskLoopRuleOption["cadence"];
}

/**
 * One option for each rule, sorted by its label so that Task activity never
 * moves a row. Each rule has its own label: where two rules read the same, the
 * cron, the IANA zone or the trigger type that tells them apart is added to
 * those rules only. The hover text names a foreign zone in full.
 */
function ruleOptions(
  entries: readonly TaskLoopRuleOption[],
  messages: CommaMessages,
  locale: CommaLocale
): TaskFilterOption[] {
  const clock = taskLoopZoneClock();
  const rows = entries.map(({ key, cadence, count }): RuleRow => {
    const trigger = taskLoopTriggerText(cadence, messages, locale, clock);
    return { id: key, count, cadence, label: trigger.text, title: trigger.title };
  });
  addWhereLabelsMatch(rows, (row) => row.cadence.cron);
  addWhereLabelsMatch(rows, (row) => row.cadence.timezone);
  // Event text can read like a schedule ("Every 5 minutes").
  addWhereLabelsMatch(rows, (row) =>
    taskLoopFilterLabel(taskLoopTriggerType(row.cadence), messages)
  );
  const collator = new Intl.Collator(locale, { numeric: true });
  return rows
    .toSorted(
      (a, b) =>
        collator.compare(a.label, b.label) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
    )
    .map(({ id, count, label, title }) => ({ id, count, label, title }));
}

/**
 * Adds `part` to the label and hover text of the rows that share a label, when
 * `part` differs between them.
 */
function addWhereLabelsMatch(
  rows: readonly RuleRow[],
  part: (row: RuleRow) => string | undefined
): void {
  for (const group of Map.groupBy(rows, (row) => row.label).values()) {
    if (new Set(group.map(part)).size < 2) continue;
    for (const row of group) {
      const value = part(row);
      if (!value) continue;
      row.label = `${row.label} · ${value}`;
      if (row.title) row.title = `${row.title} · ${value}`;
    }
  }
}
