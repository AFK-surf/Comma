import {
  formatDate,
  messages,
  taskActivityLabel,
  taskStatusBucketLabel,
  visibleTaskStatusBuckets,
  type CommaLocale,
  type VisibleTaskStatusBucket,
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
import {
  TaskCard,
  TaskCardMeta,
  TaskProgressText,
  type TaskCardProps,
} from "../task-board";
import { useTaskProgress } from "./taskProgress";
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
  id: string;
  lastMessage?: TaskWorkspaceMessage | undefined;
  /** Where the Task was asked for: a chat provider key, or `comma` for the client. */
  origin?: string | undefined;
  statusBucket: TaskStatusBucket;
  title: string;
  updatedAt: number;
  worker?: TaskWorker | undefined;
};

const TASK_STATUS_ICONS: Record<VisibleTaskStatusBucket, ReactNode> = {
  in_progress: <LoaderIcon className="text-sidebar-icon-secondary" />,
  needs_review: <BubbleAlertIcon className="text-yellow-500" />,
  done: <CircleCheckIcon className="text-fg-success-primary" />,
  cancelled: <CircleXIcon className="text-fg-error-primary" />,
};

/** The board's columns, in the order of the statuses every client shows (the core's `taskOrder` sections). */
export const TASK_STATUS_COLUMNS: ReadonlyArray<{
  bucket: TaskStatusBucket;
  icon: ReactNode;
}> = visibleTaskStatusBuckets.map((bucket) => ({
  bucket,
  icon: TASK_STATUS_ICONS[bucket],
}));

export function TaskSummaryCard({
  progress,
  task,
  ...props
}: Omit<TaskCardProps, "footer" | "icon" | "meta" | "title"> & {
  /**
   * What a running Task does now, such as its Worker's latest step, in place
   * of the status words. Ignored once the Task stops running. Without it, the
   * card reads its Task's entry in TaskProgressContext.
   */
  progress?: string | undefined;
  task: TaskSummaryViewModel;
}) {
  const locale = useCommaLocale();
  const followed = useTaskProgress(task.id);

  return (
    <TaskCard
      footer={taskUpdatedAtLabel(task.updatedAt, locale)}
      icon={taskStatusIcon(task.statusBucket)}
      meta={taskMeta(task, locale, progress ?? followed)}
      title={task.title}
      titleIdentity={task.id}
      {...props}
    />
  );
}

/** A Task without a status to show, such as one this person can no longer open, or a row about Tasks in general. */
export function taskNeutralIcon() {
  return <CircleDashedIcon className="text-sidebar-icon-secondary" />;
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
 * task has progress to report: needs-review/done/cancelled have stopped making it — the status icon already
 * carries where they landed — so callers render the line exactly when this
 * returns a string, and shimmer it because it only exists while work runs.
 */
export function taskProgressLabel(
  task: TaskSummaryViewModel,
  locale: CommaLocale
): string | undefined {
  if (task.statusBucket !== "in_progress") return undefined;
  // An idle activity still means running — the worker just has nothing new to
  // report this second — so the line falls back to the status instead of
  // vanishing and making a live task look inert.
  return (
    task.lastMessage?.content ||
    taskActivityLabel(task.activityStatus, locale) ||
    taskStatusLabel(task.statusBucket, locale)
  );
}

function taskMeta(
  task: TaskSummaryViewModel,
  locale: CommaLocale,
  override: string | undefined
) {
  const label = taskProgressLabel(task, locale);
  if (!label) return undefined;
  // A Worker's step comes live from its own Session.
  const progress = override || label;
  return (
    <TaskCardMeta>
      <TaskProgressText className="comma-shiny-text">{progress}</TaskProgressText>
    </TaskCardMeta>
  );
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
