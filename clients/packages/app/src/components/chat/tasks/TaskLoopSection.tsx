import { taskLoopRuleKey } from "@comma/core/task-loop-filter";
import { Button } from "react-aria-components";
import type { TasksFilterLink } from "../../tasks/taskChips";
import type { TaskLoop } from "@comma/core-client";
import { useTaskLoopDetails } from "../../tasks/useTaskLoopDetails";

/** Only the trigger is actionable: it opens Tasks with this exact rule. */
export function TaskLoopSection({
  loop,
  onOpenTasksFilter,
}: {
  loop: TaskLoop;
  onOpenTasksFilter?: ((link: TasksFilterLink) => void) | undefined;
}) {
  const { label, details } = useTaskLoopDetails(loop);
  const rule = taskLoopRuleKey(loop);
  return (
    <section
      className="comma-task-panel-section comma-task-loop-section"
      data-state={loop.state}
      data-testid="task-panel-schedule"
    >
      <h2 className="comma-task-panel-heading">{label}</h2>
      <ul className="flex flex-col gap-xs">
        {details.map(({ key, Icon, text, title, tone }) =>
          key === "cadence" && rule && onOpenTasksFilter ? (
            <li key={key}>
              <Button
                className="comma-task-panel-pill"
                data-testid="task-panel-loop-cadence"
                data-interactive="true"
                onPress={() => onOpenTasksFilter({ loopRule: rule })}
              >
                <span aria-hidden="true" className="comma-icon-slot size-5 shrink-0">
                  <Icon className="size-5 text-quaternary" />
                </span>
                <span className="comma-task-loop-rule" title={title}>
                  {text}
                </span>
              </Button>
            </li>
          ) : (
            <li
              key={key}
              className="comma-task-loop-detail flex items-start gap-xs text-sm text-secondary"
              data-testid={
                key === "ended" ? "task-panel-schedule-next" : `task-panel-loop-${key}`
              }
              data-tone={tone}
              title={title}
            >
              <span aria-hidden="true" className="comma-icon-slot size-5 shrink-0">
                <Icon className="size-5 text-quaternary" />
              </span>
              <span className="min-w-0 break-words">{text}</span>
            </li>
          )
        )}
      </ul>
    </section>
  );
}
