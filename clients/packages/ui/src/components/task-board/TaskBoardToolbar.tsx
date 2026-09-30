import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "../utils";

export interface TaskBoardToolbarProps extends HTMLAttributes<HTMLDivElement> {
  label: ReactNode;
  actions?: ReactNode;
}

/** Tasks board toolbar from Comma App / Tasks (Figma 439:7343). */
export const TaskBoardToolbar = ({
  label,
  actions,
  className,
  ...rest
}: TaskBoardToolbarProps) => (
  <div
    className={cx(
      "box-border flex w-full shrink-0 items-center justify-between gap-md p-lg",
      className
    )}
    data-slot="task-board-toolbar"
    {...rest}
  >
    <span
      className="box-border inline-flex h-6 items-center rounded-full border border-secondary bg-tertiary px-md py-xxs text-sm font-regular leading-5 tracking-[-0.14px] text-primary"
      data-slot="task-board-toolbar-label"
    >
      {label}
    </span>
    {actions ? (
      <div
        className="flex min-w-0 items-center justify-end gap-md"
        data-slot="task-board-toolbar-actions"
      >
        {actions}
      </div>
    ) : null}
  </div>
);

export interface TaskBoardToolbarIconBadgeProps extends Omit<
  HTMLAttributes<HTMLSpanElement>,
  "children"
> {
  icon: ReactNode;
}

/** Decorative icon badge used by the Tasks board toolbar (Figma 439:7346/7347). */
export const TaskBoardToolbarIconBadge = ({
  icon,
  className,
  ...rest
}: TaskBoardToolbarIconBadgeProps) => (
  <span
    aria-hidden
    className={cx(
      "box-border inline-flex size-6 shrink-0 items-center justify-center rounded-full border border-secondary text-quaternary [&_svg]:size-3",
      className
    )}
    data-slot="task-board-toolbar-icon-badge"
    {...rest}
  >
    {icon}
  </span>
);
