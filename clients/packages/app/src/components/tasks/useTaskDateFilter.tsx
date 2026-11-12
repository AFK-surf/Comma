import { useCommaMessages } from "@comma/i18n/react";
import {
  CalendarEditIcon,
  CalendarIcon,
  CalendarRepeatIcon,
} from "@comma/ui/components/icons";
import type {
  TaskFilterOption,
  TaskFilterSection,
  TaskFilterSectionGroup,
} from "@comma/ui/components/task-workspace";
import { useMemo } from "react";
import type { TaskViewModel } from "./useWorkspaceTasks";

type CommaMessages = ReturnType<typeof useCommaMessages>;

/** The dates of a Task the Dates filter narrows by. */
export const TASK_DATE_FIELDS = ["created", "updated"] as const;
export type TaskDateField = (typeof TASK_DATE_FIELDS)[number];

/** How far back a date may lie, on the local calendar: days, months or years before now. */
const WINDOWS = {
  "1d": { days: 1 },
  "3d": { days: 3 },
  "1w": { days: 7 },
  "1m": { months: 1 },
  "3m": { months: 3 },
  "6m": { months: 6 },
  "1y": { months: 12 },
} as const satisfies Record<string, { days: number } | { months: number }>;
export type TaskDateWindow = keyof typeof WINDOWS;
const TASK_DATE_WINDOWS = Object.keys(WINDOWS) as TaskDateWindow[];

/** For each date, the window it must lie in; a date absent here does not narrow. */
export type TaskDateSelection = Partial<Record<TaskDateField, TaskDateWindow>>;

const ALL_TASKS = "all";

/**
 * The first moment of `window` before `now`. A month back from a day the
 * earlier month lacks (31 March) lands on that month's last day.
 */
export function taskDateWindowStart(window: TaskDateWindow, now: number): number {
  const at = new Date(now);
  const span: { days: number } | { months: number } = WINDOWS[window];
  if ("days" in span) {
    at.setDate(at.getDate() - span.days);
    return at.getTime();
  }
  const day = at.getDate();
  at.setDate(1);
  at.setMonth(at.getMonth() - span.months);
  const lastDay = new Date(at.getFullYear(), at.getMonth() + 1, 0).getDate();
  at.setDate(Math.min(day, lastDay));
  return at.getTime();
}

function taskDate(task: TaskViewModel, field: TaskDateField): number | undefined {
  return field === "created" ? task.createdAt : task.updatedAt;
}

/** Whether every date `selection` names lies in its window; a Task without that date does not. */
export function taskMatchesDates(
  task: TaskViewModel,
  selection: TaskDateSelection,
  now: number
): boolean {
  return TASK_DATE_FIELDS.every((field) => {
    const window = selection[field];
    if (!window) return true;
    const at = taskDate(task, field);
    return at !== undefined && at >= taskDateWindowStart(window, now);
  });
}

/**
 * The Dates submenu: a single-select window for each date, with All tasks
 * clearing it, and how many loaded Tasks each window keeps. `now` is when the
 * windows end. Pass a stable `onChange`.
 */
export function useTaskDateFilter(
  tasks: readonly TaskViewModel[],
  selection: TaskDateSelection,
  now: number,
  onChange: (field: TaskDateField, window: TaskDateWindow | undefined) => void
): TaskFilterSectionGroup {
  const messages = useCommaMessages();
  return useMemo(
    () => ({
      icon: <CalendarIcon />,
      id: "dates",
      label: messages.tasks_filter_dates(),
      sections: TASK_DATE_FIELDS.map((field): TaskFilterSection => {
        const selected = selection[field];
        return {
          icon: field === "created" ? <CalendarEditIcon /> : <CalendarRepeatIcon />,
          id: `date:${field}`,
          label: dateFieldLabel(field, messages),
          options: [
            { id: ALL_TASKS, label: messages.tasks_all(), count: tasks.length },
            ...windowOptions(tasks, field, now, messages),
          ],
          selected: new Set([selected ?? ALL_TASKS]),
          narrowed: selected !== undefined,
          selectionMode: "single",
          onChange: (keys) => {
            const key = keys.values().next().value;
            onChange(
              field,
              key === ALL_TASKS ? undefined : TASK_DATE_WINDOWS.find((w) => w === key)
            );
          },
        };
      }),
    }),
    [messages, now, onChange, selection, tasks]
  );
}

function windowOptions(
  tasks: readonly TaskViewModel[],
  field: TaskDateField,
  now: number,
  messages: CommaMessages
): TaskFilterOption[] {
  const dates = tasks.flatMap((task) => taskDate(task, field) ?? []);
  return TASK_DATE_WINDOWS.map((window) => {
    const start = taskDateWindowStart(window, now);
    return {
      id: window,
      label: windowLabel(window, messages),
      count: dates.filter((at) => at >= start).length,
    };
  });
}

function dateFieldLabel(field: TaskDateField, messages: CommaMessages): string {
  return field === "created"
    ? messages.tasks_filter_created_date()
    : messages.tasks_filter_updated_date();
}

function windowLabel(window: TaskDateWindow, messages: CommaMessages): string {
  switch (window) {
    case "1d":
      return messages.tasks_filter_date_1d();
    case "3d":
      return messages.tasks_filter_date_3d();
    case "1w":
      return messages.tasks_filter_date_1w();
    case "1m":
      return messages.tasks_filter_date_1m();
    case "3m":
      return messages.tasks_filter_date_3m();
    case "6m":
      return messages.tasks_filter_date_6m();
    case "1y":
      return messages.tasks_filter_date_1y();
  }
}
