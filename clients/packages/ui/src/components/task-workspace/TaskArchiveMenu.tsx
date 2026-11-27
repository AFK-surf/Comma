import { useEffect, useState, type ReactNode } from "react";
import { Button, MenuTrigger } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import { ArchiveIcon, ArrowUpRightIcon, MoreHorizontalIcon } from "../icons";
import { Menu, MenuItem, MenuPopover } from "../menu";
import { cx } from "../utils";

export interface TaskArchiveAction {
  disabledReason?: string | undefined;
  run: () => Promise<void>;
}

export interface TaskOpenExternalAction {
  label?: string | undefined;
  run: () => void;
}

type TaskArchiveMenuChildren = ReactNode | ((trigger: ReactNode) => ReactNode);

/**
 * 20px hover surface: 2px padding around the 16px glyph, transparent at rest,
 * `sidebar-bg-item` under the pointer.
 */
const taskMoreButtonClassName =
  "inline-flex size-5 shrink-0 cursor-pointer items-center justify-center rounded-sm border-0 bg-transparent p-xxs text-sidebar-icon-primary outline-none transition-colors duration-[50ms] hover:bg-sidebar-bg-item hover:text-sidebar-icon-primary focus-visible:shadow-focus-gray aria-expanded:bg-sidebar-bg-item aria-expanded:text-sidebar-icon-primary";

const taskMoreButtonOverlayRevealClassName =
  "opacity-0 group-hover/task-actions:opacity-100 focus-visible:opacity-100 aria-expanded:opacity-100";

const taskMoreButtonClusterClassName = "[&_svg]:size-3";
const taskMoreIconClusterClassName = "size-3";
const taskMoreIconOverlayClassName = "size-4";

/**
 * Wraps a Task's navigation control and supplies Archive. Callers that pass
 * element children keep the More button as a trailing overlay sibling. Callers
 * that pass a function receive that same trigger so it can sit with other
 * hover actions instead of covering them. The wrapper stays mounted when
 * Archive comes and goes so the wrapped row does not remount.
 *
 * `overlay="task-card"` places the button on a wrapped TaskCard's title line
 * and makes the title leave it room (task-board.css); the default keeps it in
 * the corner.
 */
export function TaskArchiveMenu({
  action: taskAction,
  children,
  inline = false,
  openExternalAction,
  overlay = "corner",
}: {
  action?: TaskArchiveAction | undefined;
  children: TaskArchiveMenuChildren;
  inline?: boolean;
  openExternalAction?: TaskOpenExternalAction | undefined;
  overlay?: "corner" | "task-card";
}) {
  const action = taskAction?.disabledReason ? undefined : taskAction;
  const hasMenu = Boolean(action || openExternalAction);
  const Wrapper = inline ? "span" : "div";
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const placeTrigger = typeof children === "function";
  const renderContent = (trigger: ReactNode) =>
    typeof children === "function" ? children(trigger) : children;

  useEffect(() => {
    if (!hasMenu) setOpen(false);
  }, [hasMenu]);

  const trigger = hasMenu ? (
    <ArchiveMenuTrigger
      canArchive={Boolean(action)}
      className={
        placeTrigger
          ? taskMoreButtonClusterClassName
          : taskMoreButtonOverlayRevealClassName
      }
      iconClassName={
        placeTrigger ? taskMoreIconClusterClassName : taskMoreIconOverlayClassName
      }
      onArchive={() => {
        if (!action) return;
        setPending(true);
        void action
          .run()
          .catch(() => undefined)
          .finally(() => setPending(false));
      }}
      openExternalAction={openExternalAction}
      open={open}
      pending={pending}
      setOpen={setOpen}
    />
  ) : null;
  const content = renderContent(placeTrigger ? trigger : null);

  return (
    <Wrapper
      data-slot={inline ? "task-archive-menu" : undefined}
      data-task-card-action={
        overlay === "task-card" && hasMenu && !placeTrigger ? "" : undefined
      }
      className={`group/task-actions relative min-w-0${inline ? " inline-block" : ""}`}
      onContextMenu={(event) => {
        if (hasMenu) {
          event.preventDefault();
          setOpen(true);
        }
      }}
    >
      {content}
      {placeTrigger || !hasMenu ? null : (
        <span
          className={
            overlay === "task-card"
              ? "comma-task-card-action"
              : "absolute right-0.5 top-0.5"
          }
        >
          {trigger}
        </span>
      )}
    </Wrapper>
  );
}

function ArchiveMenuTrigger({
  canArchive,
  className,
  iconClassName,
  onArchive,
  open,
  openExternalAction,
  pending,
  setOpen,
}: {
  canArchive: boolean;
  className?: string | undefined;
  iconClassName: string;
  onArchive: () => void;
  open: boolean;
  openExternalAction?: TaskOpenExternalAction | undefined;
  pending: boolean;
  setOpen: (open: boolean) => void;
}) {
  const messages = useCommaMessages();
  // Lists render a trigger per Task; the menu mounts with its first opening
  // and stays mounted so it can animate out.
  const [opened, setOpened] = useState(open);
  if (open && !opened) setOpened(true);

  const openExternalLabel =
    openExternalAction?.label ?? messages.tasks_open_in_browser();
  const triggerLabel = canArchive ? messages.tasks_archive() : openExternalLabel;

  return (
    <MenuTrigger isOpen={open} onOpenChange={setOpen}>
      <Button
        aria-label={triggerLabel}
        className={cx(taskMoreButtonClassName, className)}
        onClick={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
      >
        <MoreHorizontalIcon className={iconClassName} />
      </Button>
      {opened ? (
        <MenuPopover placement="bottom end">
          <Menu
            aria-label={triggerLabel}
            onAction={(key) => {
              if (key === "open-external") {
                openExternalAction?.run();
              } else if (key === "archive") {
                onArchive();
              }
            }}
          >
            {openExternalAction ? (
              <MenuItem
                id="open-external"
                icon={<ArrowUpRightIcon />}
                textValue={openExternalLabel}
              >
                {openExternalLabel}
              </MenuItem>
            ) : null}
            {canArchive ? (
              <MenuItem
                id="archive"
                icon={<ArchiveIcon />}
                isDisabled={pending}
                textValue={messages.tasks_archive()}
              >
                {messages.tasks_archive()}
              </MenuItem>
            ) : null}
          </Menu>
        </MenuPopover>
      ) : null}
    </MenuTrigger>
  );
}
