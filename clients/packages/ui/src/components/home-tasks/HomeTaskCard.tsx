import { TaskArchiveMenu } from "../task-workspace/TaskArchiveMenu";
import { messages } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import { memo, type ReactNode } from "react";
import { Badge } from "../Badge";
import {
  TaskSummaryCard,
  taskAriaLabel,
  type TaskSummaryViewModel,
} from "../task-workspace/TaskSummaryCard";
import { homeTaskCardButton } from "./styles";

export interface HomeTaskCardProps<
  T extends TaskSummaryViewModel = TaskSummaryViewModel,
> {
  /** Extra badges after the worker badge: the Tasks board's label and platform chips. */
  badges?: ReactNode;
  onOpen: (task: T) => void;
  task: T;
}

/**
 * The home rail renders the Tasks board's card verbatim — the shared
 * TaskSummaryCard inside the same transparent button wrapper — so a task reads
 * the same wherever it is shown: identical chrome, status icon, shimmering
 * progress line, and "Updated …" footer. Only the worker badge is extra, and
 * the card carries it in the slot the shared component already exposes.
 */
function HomeTaskCardImpl<T extends TaskSummaryViewModel>({
  badges,
  onOpen,
  task,
}: HomeTaskCardProps<T>) {
  const locale = useCommaLocale();
  const workerLabel =
    task.worker === "codex"
      ? messages.tasks_filter_worker_codex(undefined, { locale })
      : task.worker === "claude"
        ? messages.tasks_filter_worker_claude(undefined, { locale })
        : undefined;

  return (
    <TaskArchiveMenu action={task.archiveAction}>
      <button
        aria-label={taskAriaLabel(task, locale)}
        className={homeTaskCardButton}
        data-testid="home-task-card"
        onClick={() => onOpen(task)}
        type="button"
      >
        <TaskSummaryCard
          badges={
            workerLabel || badges ? (
              <>
                {workerLabel ? (
                  <Badge color="gray" size="sm" type="pill-outline">
                    {workerLabel}
                  </Badge>
                ) : null}
                {badges}
              </>
            ) : undefined
          }
          interactive
          task={task}
          titleClassName="line-clamp-2"
        />
      </button>
    </TaskArchiveMenu>
  );
}

/** Memoized while keeping the task-model generic intact. */
export const HomeTaskCard = memo(HomeTaskCardImpl) as typeof HomeTaskCardImpl;
