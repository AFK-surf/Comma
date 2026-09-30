import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "../utils";
import {
  taskCardBadges,
  taskCardBody,
  taskCardDisabled,
  taskCardFooter,
  taskCardIcon,
  taskCardIconSlot,
  taskCardInteractive,
  taskCardMeta,
  taskCardMetaSpacer,
  taskCardMetaText,
  taskCardRoot,
  taskCardRow,
  taskCardSelected,
  taskCardChecked,
  taskCardTitle,
} from "./styles";

export interface TaskCardProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  /** Status icon shown on the first title line (18px). */
  icon: ReactNode;
  title: ReactNode;
  /** Secondary line aligned under the title, e.g. a worker status. */
  meta?: ReactNode;
  /** Inline badges/tags such as a schedule indicator. */
  badges?: ReactNode;
  /** Footer caption, e.g. "Created May 9". */
  footer?: ReactNode;
  /** Adds hover/focus affordances for clickable cards. */
  interactive?: boolean;
  selected?: boolean;
  /** Part of a multi-selection (brand stroke and wash). */
  checked?: boolean;
  disabled?: boolean;
  titleClassName?: string;
  footerClassName?: string;
}

export const TaskCard = ({
  icon,
  title,
  meta,
  badges,
  footer,
  interactive = false,
  selected = false,
  checked = false,
  disabled = false,
  titleClassName,
  footerClassName,
  className,
  ...rest
}: TaskCardProps) => (
  <div
    className={cx(
      taskCardRoot,
      interactive && !disabled && taskCardInteractive,
      selected && taskCardSelected,
      checked && taskCardChecked,
      disabled && taskCardDisabled,
      className
    )}
    data-checked={checked ? "true" : undefined}
    data-disabled={disabled ? "true" : undefined}
    data-selected={selected ? "true" : undefined}
    data-slot="task-card"
    {...rest}
  >
    <div className={taskCardBody} data-slot="task-card-body">
      <div className={taskCardRow}>
        <span aria-hidden className={taskCardIconSlot} data-slot="task-card-icon">
          <span className={taskCardIcon}>{icon}</span>
        </span>
        <span className={cx(taskCardTitle, titleClassName)} data-slot="task-card-title">
          {title}
        </span>
      </div>
      {meta ? (
        <div className={taskCardRow} data-slot="task-card-meta-row">
          <span aria-hidden className={taskCardMetaSpacer} />
          <div className="min-w-0 flex-1">{meta}</div>
        </div>
      ) : null}
    </div>
    {badges ? (
      <div className={taskCardBadges} data-slot="task-card-badges">
        {badges}
      </div>
    ) : null}
    {footer ? (
      <p className={cx(taskCardFooter, footerClassName)} data-slot="task-card-footer">
        {footer}
      </p>
    ) : null}
  </div>
);

export interface TaskCardMetaProps {
  children: ReactNode;
  className?: string;
  /** Applied to the truncating text node, e.g. the running-task shimmer. */
  textClassName?: string;
}

/**
 * Single-line meta row. It carries no glyph of its own: the row sits under the
 * title, indented past an empty copy of the status-icon slot, so the status is
 * stated once and the line reads as a continuation of the title.
 */
export const TaskCardMeta = ({
  children,
  className,
  textClassName,
}: TaskCardMetaProps) => (
  <div className={cx(taskCardMeta, className)} data-slot="task-card-meta">
    <span className={cx(taskCardMetaText, textClassName)}>{children}</span>
  </div>
);
