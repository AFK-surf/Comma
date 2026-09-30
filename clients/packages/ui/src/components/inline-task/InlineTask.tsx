import {
  cloneElement,
  useEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactElement,
  type ReactNode,
  type RefObject,
} from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { ArchiveIcon, ExpandSimpleIcon, PanelRightIcon } from "../icons";
import { Menu, MenuItem, MenuPopover } from "../menu";
import { suspendHoverCards } from "../hover-card/HoverCard";
import type { TaskArchiveAction } from "../task-workspace/TaskArchiveMenu";
import { HoverCard } from "../hover-card";
import {
  TaskSummaryCard,
  taskStatusIcon,
  type TaskSummaryViewModel,
} from "../task-workspace";
import { cx } from "../utils";

type InlineTaskTriggerProps = HTMLAttributes<HTMLElement> & {
  "aria-label"?: string | undefined;
  children?: ReactNode;
  className?: string | undefined;
  "data-testid"?: string | undefined;
};

export interface InlineTaskProps {
  archiveAction?: TaskArchiveAction | undefined;
  /** The hover card's chips: the Task's labels and platform, as on every Task card. */
  badges?: ReactNode | undefined;
  dataTestId?: string | undefined;
  defaultOpen?: boolean | undefined;
  link?: ReactElement<InlineTaskTriggerProps> | undefined;
  onOpenTask?: (() => void) | undefined;
  onOpenInSidebar?: (() => void) | undefined;
  previewBoundaryRef?: RefObject<Element | null> | undefined;
  onOpenChange?: ((open: boolean) => void) | undefined;
  showHoverPreview?: boolean | undefined;
  task: TaskSummaryViewModel;
  unavailable?: boolean | undefined;
  unavailableLabel?: string | undefined;
}

/**
 * Compact Task mention for prose. Consumers own navigation and data loading;
 * Comma UI owns the visual states and rich hover presentation.
 */
export function InlineTask({
  archiveAction,
  badges,
  dataTestId,
  defaultOpen,
  link,
  onOpenChange,
  onOpenTask,
  onOpenInSidebar,
  previewBoundaryRef,
  showHoverPreview = true,
  task,
  unavailable = false,
  unavailableLabel,
}: InlineTaskProps) {
  const messages = useCommaMessages();
  const action = archiveAction?.disabledReason ? undefined : archiveAction;
  const hasMenu = Boolean(action || onOpenTask || onOpenInSidebar);
  const anchor = useRef<HTMLElement | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (menuOpen) return suspendHoverCards();
  }, [menuOpen]);

  if (task.statusBucket === "archived" && !unavailable) {
    return (
      <span
        aria-disabled="true"
        className="comma-inline-task comma-inline-task--archived"
        data-status="archived"
        data-testid={dataTestId}
        onContextMenu={(event) => {
          event.preventDefault();
          event.stopPropagation();
        }}
      >
        <span aria-hidden className="comma-inline-task-icon">
          {taskStatusIcon("archived")}
        </span>
        <span className="comma-inline-task-title">{task.title}</span>
      </span>
    );
  }

  if (unavailable || !link) {
    const label = unavailableLabel ?? messages.chat_ref_task_unavailable();
    return (
      <span
        aria-label={label}
        className="comma-inline-task comma-inline-task--unavailable"
        data-testid={dataTestId}
      >
        <span aria-hidden className="comma-inline-task-icon">
          {taskStatusIcon("backlog")}
        </span>
        <span>{label}</span>
      </span>
    );
  }

  const trigger = cloneElement(link, {
    className: cx("comma-inline-task", link.props.className),
    "data-testid": dataTestId,
    onContextMenu: (event) => {
      link.props.onContextMenu?.(event);
      if (!hasMenu || event.defaultPrevented) return;
      event.preventDefault();
      anchor.current = event.currentTarget;
      setMenuOpen(true);
    },
    onKeyDown: (event) => {
      link.props.onKeyDown?.(event);
      if (!hasMenu || event.defaultPrevented) return;
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        anchor.current = event.currentTarget;
        setMenuOpen(true);
      }
    },
    children: (
      <>
        <span aria-hidden className="comma-inline-task-icon">
          {taskStatusIcon(task.statusBucket)}
        </span>
        <span className="comma-inline-task-title">{task.title}</span>
      </>
    ),
  });

  return (
    <>
      {showHoverPreview ? (
        <HoverCard
          boundaryRef={previewBoundaryRef}
          content={
            <TaskSummaryCard
              // inset-shadow-none is what drops the card's own 0.5px stroke;
              // shadow-none only clears the outer shadow, and the popup already
              // draws the border around this content.
              badges={badges}
              className="pointer-events-none border-0 bg-transparent inset-shadow-none shadow-none"
              task={task}
            />
          }
          delay={0}
          placement="bottom start"
          {...(defaultOpen === undefined ? {} : { defaultOpen })}
          {...(onOpenChange === undefined ? {} : { onOpenChange })}
        >
          {trigger}
        </HoverCard>
      ) : (
        trigger
      )}
      {hasMenu && menuOpen ? (
        <MenuPopover
          triggerRef={anchor}
          isOpen
          onOpenChange={setMenuOpen}
          placement="bottom start"
        >
          <Menu
            aria-label={messages.chat_ref_task()}
            onAction={(key) => {
              if (key === "open-task" || key === "open-sidebar") {
                setMenuOpen(false);
                if (key === "open-task") onOpenTask?.();
                else onOpenInSidebar?.();
                return;
              }
              if (key !== "archive" || !action) return;
              setPending(true);
              void action
                .run()
                .catch(() => undefined)
                .finally(() => {
                  setPending(false);
                  setMenuOpen(false);
                });
            }}
          >
            {onOpenInSidebar ? (
              <MenuItem id="open-sidebar" icon={<PanelRightIcon />}>
                {messages.chat_task_open_sidebar()}
              </MenuItem>
            ) : null}
            {onOpenTask ? (
              <MenuItem id="open-task" icon={<ExpandSimpleIcon />}>
                {messages.chat_task_open()}
              </MenuItem>
            ) : null}
            {action ? (
              <MenuItem id="archive" icon={<ArchiveIcon />} isDisabled={pending}>
                {messages.tasks_archive()}
              </MenuItem>
            ) : null}
          </Menu>
        </MenuPopover>
      ) : null}
    </>
  );
}
