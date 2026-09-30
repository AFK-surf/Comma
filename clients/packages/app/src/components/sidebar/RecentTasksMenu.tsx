import { useCommaMessages } from "@comma/i18n/react";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  NativeSurfaceSuppressor,
  taskStatusIcon,
} from "@comma/ui";
import { useNavigate } from "@tanstack/react-router";
import { Collection, Header, MenuSection } from "react-aria-components";
import { ShellIconButton } from "../ShellIconButton";
import { sidebarTaskNavigationTarget } from "./sidebarTaskNavigation";
import { useSidebarTasks } from "./useSidebarTasks";

const RECENT_TASK_LIMIT = 10;

/**
 * Window bar clock button: the workspace's most recent tasks as a menu. The
 * button sits at the window's right edge, so the menu drops over the Chat
 * Sidebar — where the native browser view paints above every DOM layer. The
 * suppressor swaps that view for a snapshot for as long as the menu is open.
 */
export function RecentTasksMenu() {
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const { recent } = useSidebarTasks();
  const tasks = recent.slice(0, RECENT_TASK_LIMIT);
  const label = messages.nav_recent_tasks();

  return (
    <MenuTrigger>
      <ShellIconButton icon="clock" label={label} />
      <MenuPopover placement="bottom end">
        <NativeSurfaceSuppressor />
        <Menu
          aria-label={label}
          className="w-80"
          onAction={(key) => {
            const task = tasks.find((candidate) => candidate.id === key);
            if (task) void navigate(sidebarTaskNavigationTarget(task));
          }}
          renderEmptyState={() => (
            <div
              className="mx-sm px-md py-sm text-sm text-quaternary"
              data-testid="comma-recent-tasks-empty"
            >
              {messages.shell_recent_tasks_empty()}
            </div>
          )}
        >
          {tasks.length > 0 ? (
            <MenuSection>
              <Header className="mx-sm px-md pb-xs pt-sm text-xs font-medium text-quaternary">
                {label}
              </Header>
              <Collection items={tasks}>
                {(task) => (
                  <MenuItem
                    icon={taskStatusIcon(task.statusBucket)}
                    id={task.id}
                    textValue={task.label}
                  >
                    {task.label}
                  </MenuItem>
                )}
              </Collection>
            </MenuSection>
          ) : null}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
