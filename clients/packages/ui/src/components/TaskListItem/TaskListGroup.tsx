import * as Collapsible from "@radix-ui/react-collapsible";
import { useState, type ReactNode } from "react";
import { cx } from "../utils";
import { ChevronTriangleDownSmallIcon } from "../icons";
import { Collapse, CollapseContent } from "../collapse";
import {
  taskListGroupBody,
  taskListGroupChevron,
  taskListGroupChevronCollapsed,
  taskListGroupCount,
  taskListGroupHeader,
  taskListGroupHeaderAccent,
  taskListGroupHeaderInner,
  taskListGroupIcon,
  taskListGroupLabel,
  taskListGroupRoot,
  type TaskListGroupAccent,
} from "./styles";

export interface TaskListGroupProps {
  /** Status icon shown next to the group label (same icon system as rows). */
  icon: ReactNode;
  label: ReactNode;
  count?: number;
  /** Tints the header background with the status color, matching the board design. */
  accent?: TaskListGroupAccent;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  children: ReactNode;
  className?: string;
  headerClassName?: string;
}

export const TaskListGroup = ({
  icon,
  label,
  count,
  accent = "neutral",
  open,
  defaultOpen = true,
  onOpenChange,
  children,
  className,
  headerClassName,
}: TaskListGroupProps) => {
  const [internalOpen, setInternalOpen] = useState(open ?? defaultOpen);
  const isOpen = open ?? internalOpen;

  const handleOpenChange = (next: boolean) => {
    if (open === undefined) setInternalOpen(next);
    onOpenChange?.(next);
  };

  return (
    <Collapse
      className={cx(taskListGroupRoot, className)}
      onOpenChange={handleOpenChange}
      open={isOpen}
    >
      <Collapsible.Trigger
        className={cx(
          taskListGroupHeader,
          taskListGroupHeaderAccent[accent],
          headerClassName
        )}
        // The header is a full-width band, not a control the eye reads as a
        // button: the global press scale makes the whole group flinch on the
        // click that only opens or closes it. The chevron and the collapse
        // itself are the feedback.
        data-no-press-feedback
        data-slot="task-list-group-header"
      >
        <span className={taskListGroupHeaderInner}>
          <ChevronTriangleDownSmallIcon
            className={cx(
              taskListGroupChevron,
              !isOpen && taskListGroupChevronCollapsed
            )}
          />
          <span className={taskListGroupIcon} data-slot="task-list-group-icon">
            {icon}
          </span>
          <span className={taskListGroupLabel} data-slot="task-list-group-label">
            {label}
          </span>
          {count !== undefined ? (
            <span className={taskListGroupCount} data-slot="task-list-group-count">
              {count}
            </span>
          ) : null}
        </span>
      </Collapsible.Trigger>
      <CollapseContent className={taskListGroupBody}>{children}</CollapseContent>
    </Collapse>
  );
};
