import {
  contentFreshnessLabel,
  formatDate,
  messages,
  taskActivityLabel,
  taskStatusBucketLabel,
  type CommaLocale,
} from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import type { ReactNode } from "react";
import {
  ArchiveIcon,
  BubbleAlertIcon,
  CircleCheckIcon,
  CircleDashedIcon,
  CircleXIcon,
  LoaderIcon,
} from "../icons";
import { TaskCard, TaskCardMeta, type TaskCardProps } from "../task-board";
import type { TaskStatusBucket } from "./taskStatus";

export type { TaskStatusBucket } from "./taskStatus";

export type TaskWorker = "codex" | "claude";

export const TASK_WORKERS: readonly TaskWorker[] = ["codex", "claude"];

export type TaskWorkspaceMessage = {
  content: string;
  id: string;
  role: string;
  roleLabel: string;
};

export type TaskSummaryViewModel = {
  archiveVersion?: number | undefined;
  archiveAction?: import("./TaskArchiveMenu").TaskArchiveAction | undefined;
  activityStatus: string;
  freshness: "fresh" | "stale" | "unknown";
  id: string;
  lastMessage?: TaskWorkspaceMessage | undefined;
  /** Where the Task was asked for: a chat provider key, or `comma` for the client. */
  origin?: string | undefined;
  statusBucket: TaskStatusBucket;
  title: string;
  updatedAt: number;
  worker?: TaskWorker | undefined;
};

export const TASK_STATUS_COLUMNS: ReadonlyArray<{
  bucket: TaskStatusBucket;
  icon: ReactNode;
}> = [
  {
    bucket: "backlog",
    icon: <CircleDashedIcon className="text-sidebar-icon-secondary" />,
  },
  {
    bucket: "in_progress",
    icon: <LoaderIcon className="text-sidebar-icon-secondary" />,
  },
  {
    bucket: "needs_review",
    icon: <BubbleAlertIcon className="text-yellow-500" />,
  },
  {
    bucket: "done",
    icon: <CircleCheckIcon className="text-fg-success-primary" />,
  },
  {
    bucket: "cancelled",
    icon: <CircleXIcon className="text-fg-error-primary" />,
  },
];

export function TaskSummaryCard({
  task,
  ...props
}: Omit<TaskCardProps, "footer" | "icon" | "meta" | "title"> & {
  task: TaskSummaryViewModel;
}) {
  const locale = useCommaLocale();

  return (
    <TaskCard
      footer={taskUpdatedAtLabel(task.updatedAt, locale)}
      icon={taskStatusIcon(task.statusBucket)}
      meta={taskMeta(task, locale)}
      title={task.title}
      {...props}
    />
  );
}

export function taskStatusIcon(bucket: TaskStatusBucket) {
  if (bucket === "archived") return <ArchiveIcon />;
  return (
    TASK_STATUS_COLUMNS.find((column) => column.bucket === bucket)?.icon ??
    TASK_STATUS_COLUMNS[0]!.icon
  );
}

/**
 * Progress-line copy for a task, shared by every surface that shows one (the
 * Task card, its inline hover preview, the home Tasks rail). Only a running
 * task has progress to report: backlog has not started, and
 * needs-review/done/cancelled have stopped making it — the status icon already
 * carries where they landed — so callers render the line exactly when this
 * returns a string, and shimmer it because it only exists while work runs.
 */
export function taskProgressLabel(
  task: TaskSummaryViewModel,
  locale: CommaLocale
): string | undefined {
  if (task.statusBucket !== "in_progress") return undefined;
  const freshnessLabel = taskFreshnessLabel(task.freshness, locale);
  // An idle activity still means running — the worker just has nothing new to
  // report this second — so the line falls back to the status instead of
  // vanishing and making a live task look inert.
  const content =
    task.lastMessage?.content ||
    taskActivityLabel(task.activityStatus, locale) ||
    taskStatusLabel(task.statusBucket, locale);
  // A freshness caveat prefixes the progress rather than replacing it: an
  // unknown projection usually just means the preview has not loaded yet
  // (inline Task cards default to it), and swallowing the progress there left
  // a running task saying only "Status unknown".
  return [freshnessLabel, content].filter(Boolean).join(" · ");
}

function taskMeta(task: TaskSummaryViewModel, locale: CommaLocale) {
  const progress = taskProgressLabel(task, locale);
  if (!progress) return undefined;
  return <TaskCardMeta textClassName="comma-shiny-text">{progress}</TaskCardMeta>;
}

export function taskFreshnessLabel(
  freshness: TaskSummaryViewModel["freshness"],
  locale: CommaLocale
): string | undefined {
  return contentFreshnessLabel(freshness, locale);
}

/**
 * Accessible name for a Task card's click target, shared by every surface that
 * wraps one in a button: the card's own text now runs past the title (progress
 * line, "Updated …" footer), so the label states the task, plus the freshness
 * caveat when the projection has one.
 */
export function taskAriaLabel(task: TaskSummaryViewModel, locale: CommaLocale): string {
  return [task.title, taskFreshnessLabel(task.freshness, locale)]
    .filter(Boolean)
    .join(", ");
}

export function taskStatusLabel(bucket: TaskStatusBucket, locale: CommaLocale): string {
  return taskStatusBucketLabel(bucket, locale);
}

export function taskUpdatedAtLabel(timestamp: number, locale: CommaLocale): string {
  if (!timestamp) {
    return messages.tasks_updated_recently(undefined, { locale });
  }
  const milliseconds = timestamp < 10_000_000_000 ? timestamp * 1_000 : timestamp;
  const date = formatDate(milliseconds, locale, {
    month: "short",
    day: "numeric",
  });
  return messages.tasks_updated_date({ date }, { locale });
}
