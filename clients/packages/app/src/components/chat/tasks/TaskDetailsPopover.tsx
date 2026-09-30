import { useCommaMessages } from "@comma/i18n/react";
import { MenuPopover, menuSurfaceClasses } from "@comma/ui";
import { Dialog as AriaDialog, DialogTrigger } from "react-aria-components";
import { ShellIconButton } from "../../ShellIconButton";
import { TaskDetailsPanel, type TaskDetailsPanelProps } from "./TaskDetailsPanel";

export type TaskDetailsPopoverProps = Omit<
  TaskDetailsPanelProps,
  "layout" | "onToggle" | "open"
>;

/**
 * Header trigger for a folded Task route: the same details the second column
 * would show, dropped from the header's trailing button the way the window
 * bar's recent-tasks menu drops from its clock — the menu popover surface and
 * its anchored enter/exit, holding a dialog instead of a menu.
 */
export function TaskDetailsPopover(props: TaskDetailsPopoverProps) {
  const messages = useCommaMessages();
  return (
    <DialogTrigger>
      <ShellIconButton
        className="comma-task-panel-toggle"
        icon="list-bullets"
        label={messages.task_panel_toggle()}
        testId="task-panel-toggle"
      />
      <MenuPopover
        className={`${menuSurfaceClasses} comma-task-panel-popover`}
        placement="bottom end"
      >
        <AriaDialog
          aria-label={messages.task_panel_region()}
          className="outline-none"
          data-testid="task-panel-popover"
        >
          <TaskDetailsPanel {...props} layout="popover" open />
        </AriaDialog>
      </MenuPopover>
    </DialogTrigger>
  );
}
