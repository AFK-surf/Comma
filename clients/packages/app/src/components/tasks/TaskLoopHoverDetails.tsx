import type { TaskLoop } from "@comma/core-client";
import { useTaskLoopDetails } from "./useTaskLoopDetails";

/** The card preview: the chip's trigger type over the same rows as Properties. */
export function TaskLoopHoverDetails({ loop }: { loop: TaskLoop }) {
  const { label, details } = useTaskLoopDetails(loop);
  return (
    <div className="flex flex-col gap-md">
      <p className="text-sm font-medium text-primary">{label}</p>
      <ul className="flex flex-col gap-md">
        {details.map(({ key, Icon, text, title, tone }) => (
          <li
            key={key}
            className="comma-task-loop-detail flex items-start gap-md text-sm text-secondary"
            data-tone={tone}
            title={title}
          >
            <span aria-hidden="true" className="comma-task-loop-detail-icon">
              <Icon className="size-xl text-quaternary" />
            </span>
            <span className="min-w-0 break-words">{text}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
