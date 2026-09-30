import { useEffect, useState, type ReactNode } from "react";
import { Button, MenuTrigger } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import { ArchiveIcon, MoreHorizontalIcon } from "../icons";
import { Menu, MenuItem, MenuPopover } from "../menu";
import { cx } from "../utils";

export interface TaskArchiveAction {
  disabledReason?: string | undefined;
  run: () => Promise<void>;
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
 */
export function TaskArchiveMenu({
  action: taskAction,
  children,
  inline = false,
}: {
  action?: TaskArchiveAction | undefined;
  children: TaskArchiveMenuChildren;
  inline?: boolean;
}) {
  const action = taskAction?.disabledReason ? undefined : taskAction;
  const Wrapper = inline ? "span" : "div";
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const placeTrigger = typeof children === "function";
  const renderContent = (trigger: ReactNode) =>
    typeof children === "function" ? children(trigger) : children;

  useEffect(() => {
    if (!action) setOpen(false);
  }, [action]);

  const trigger = action ? (
    <ArchiveMenuTrigger
      className={
        placeTrigger
          ? taskMoreButtonClusterClassName
          : taskMoreButtonOverlayRevealClassName
      }
      iconClassName={
        placeTrigger ? taskMoreIconClusterClassName : taskMoreIconOverlayClassName
      }
      onRun={() => {
        setPending(true);
        void action
          .run()
          .catch(() => undefined)
          .finally(() => setPending(false));
      }}
      open={open}
      pending={pending}
      setOpen={setOpen}
    />
  ) : null;
  const content = renderContent(placeTrigger ? trigger : null);

  return (
    <Wrapper
      data-slot={inline ? "task-archive-menu" : undefined}
      className={`group/task-actions relative min-w-0${inline ? " inline-block" : ""}`}
      onContextMenu={(event) => {
        if (action) {
          event.preventDefault();
          setOpen(true);
        }
      }}
    >
      {content}
      {placeTrigger || !action ? null : (
        <span className="absolute right-0.5 top-0.5">{trigger}</span>
      )}
    </Wrapper>
  );
}

function ArchiveMenuTrigger({
  className,
  iconClassName,
  onRun,
  open,
  pending,
  setOpen,
}: {
  className?: string | undefined;
  iconClassName: string;
  onRun: () => void;
  open: boolean;
  pending: boolean;
  setOpen: (open: boolean) => void;
}) {
  const messages = useCommaMessages();

  return (
    <MenuTrigger isOpen={open} onOpenChange={setOpen}>
      <Button
        aria-label={messages.tasks_archive()}
        className={cx(taskMoreButtonClassName, className)}
        onClick={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
      >
        <MoreHorizontalIcon className={iconClassName} />
      </Button>
      <MenuPopover placement="bottom end">
        <Menu aria-label={messages.tasks_archive()} onAction={onRun}>
          <MenuItem
            id="archive"
            icon={<ArchiveIcon />}
            isDisabled={pending}
            textValue={messages.tasks_archive()}
          >
            {messages.tasks_archive()}
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
