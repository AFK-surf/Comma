import { formatNumber } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "../utils";
import { ScrollArea, type ScrollAreaProps } from "../scroll-area";
import {
  taskBoardColumnBody,
  taskBoardColumnEmpty,
  taskBoardColumnHeader,
  taskBoardColumnHeaderCount,
  taskBoardColumnHeaderIcon,
  taskBoardColumnHeaderLabel,
  taskBoardColumnRoot,
  taskBoardColumnScroll,
  taskBoardColumnViewport,
  TASK_BOARD_COLUMN_WIDTH,
  taskBoardRoot,
  taskBoardTrack,
} from "./styles";

export { TASK_BOARD_COLUMN_WIDTH } from "./styles";

export interface TaskBoardProps {
  /** Columns of the board, typically `TaskBoardColumn` instances. */
  children: ReactNode;
  className?: string;
  trackClassName?: string;
  /** Forwarded options for the horizontal `ScrollArea` wrapper. */
  scrollAreaProps?: Omit<
    ScrollAreaProps,
    "orientation" | "children" | "className" | "contentClassName" | "onScroll"
  >;
}

/** Horizontal, column-based ("kanban") card view for tasks. */
export const TaskBoard = ({
  children,
  className,
  trackClassName,
  scrollAreaProps,
}: TaskBoardProps) => (
  <ScrollArea
    className={cx(taskBoardRoot, className)}
    contentClassName={cx(taskBoardTrack, trackClassName)}
    orientation="horizontal"
    {...scrollAreaProps}
  >
    {children}
  </ScrollArea>
);

export interface TaskBoardColumnProps extends Omit<
  HTMLAttributes<HTMLElement>,
  "title"
> {
  /** Status icon shown next to the column label. */
  icon: ReactNode;
  label: ReactNode;
  count?: number;
  /** Cards for this column, typically `TaskCard` instances. */
  children?: ReactNode;
  /** Rendered in the scroll body when there are no cards. */
  emptyState?: ReactNode;
  /** Forwarded options for the vertical body `ScrollArea`. */
  scrollAreaProps?: Omit<
    ScrollAreaProps,
    "orientation" | "children" | "className" | "contentClassName" | "onScroll"
  >;
  headerClassName?: string;
  bodyClassName?: string;
}

const hasChildren = (children: ReactNode) => {
  if (children == null || children === false) return false;
  if (Array.isArray(children)) {
    return children.some((child) => child != null && child !== false);
  }
  return true;
};

export const TaskBoardColumn = ({
  icon,
  label,
  count,
  children,
  emptyState,
  scrollAreaProps,
  className,
  headerClassName,
  bodyClassName,
  style,
  ...rest
}: TaskBoardColumnProps) => {
  const locale = useCommaLocale();
  const showEmptyState = emptyState != null && !hasChildren(children);
  const { viewportClassName: columnViewportClassName, ...columnScrollAreaProps } =
    scrollAreaProps ?? {};

  return (
    <section
      className={cx(taskBoardColumnRoot, className)}
      data-slot="task-board-column"
      style={{
        width: `var(--task-board-column-width, ${TASK_BOARD_COLUMN_WIDTH}px)`,
        maxWidth: `var(--task-board-column-width, ${TASK_BOARD_COLUMN_WIDTH}px)`,
        ...style,
      }}
      {...rest}
    >
      <header
        className={cx(taskBoardColumnHeader, headerClassName)}
        data-slot="task-board-column-header"
      >
        <span
          aria-hidden
          className={taskBoardColumnHeaderIcon}
          data-slot="task-board-column-icon"
        >
          {icon}
        </span>
        <span
          className={taskBoardColumnHeaderLabel}
          data-slot="task-board-column-label"
        >
          {label}
        </span>
        {count !== undefined ? (
          <span
            className={taskBoardColumnHeaderCount}
            data-slot="task-board-column-count"
          >
            {formatNumber(count, locale)}
          </span>
        ) : null}
      </header>
      <ScrollArea
        className={taskBoardColumnScroll}
        contentClassName={cx(taskBoardColumnBody, bodyClassName)}
        orientation="vertical"
        viewportClassName={cx(taskBoardColumnViewport, columnViewportClassName)}
        {...columnScrollAreaProps}
      >
        {showEmptyState ? (
          <div className={taskBoardColumnEmpty} data-slot="task-board-column-empty">
            {emptyState}
          </div>
        ) : (
          children
        )}
      </ScrollArea>
    </section>
  );
};
