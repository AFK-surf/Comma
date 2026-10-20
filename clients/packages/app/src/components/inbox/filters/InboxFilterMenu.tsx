import { useCommaMessages } from "@comma/i18n/react";
import {
  InfinityIcon,
  ChevronRightSmallIcon,
  CircleCheckIcon,
  Filter2Icon,
  SquareGridCircleIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  SubmenuTrigger,
} from "@comma/ui/components/menu";
import {
  TaskSectionFilterPanel,
  TaskStatusFilterPanel,
  taskNeutralIcon,
  taskToolbarIconButtonClassName,
  type TaskStatusCounts,
  type TaskFilterSection,
  type TaskFilterOption,
} from "@comma/ui/components/task-workspace";
import { cx } from "@comma/ui/components/utils";
import { motionDuration, spacing } from "@comma/ui/tokens";
import { Button as AriaButton } from "react-aria-components";
import {
  InboxNotificationCount,
  InboxWorkspaceFilterPanel,
  type InboxWorkspaceSelector,
} from "./InboxFilterPanels";
import {
  TASK_ORIGIN_KEYS,
  TaskOriginIcon,
  taskOriginLabel,
} from "../../tasks/taskOrigin";
import { taskLoopFilterOptions } from "../../tasks/taskChips";
import {
  INBOX_NO_PLATFORM,
  isInboxFiltered,
  type InboxFilters,
  type InboxPlatformCounts,
  type InboxScheduleCounts,
} from "./inboxFilters";

export interface InboxFilterMenuProps {
  filters: InboxFilters;
  onFiltersChange: (filters: InboxFilters) => void;
  statusCounts: TaskStatusCounts;
  platformCounts: InboxPlatformCounts;
  scheduleCounts: InboxScheduleCounts;
  ruleSection?: TaskFilterSection | undefined;
  workspaceSelector?: InboxWorkspaceSelector | undefined;
}

// Every first-level row opens its options panel to the right; the rows share
// one look, mirroring the Tasks filter.
const submenuRowProps = {
  activeClassName: "bg-secondary-hover text-sidebar-text-highlight",
  appearance: "sidebar",
  className: "pointer-events-auto",
  contentClassName: "h-8",
  gutter: "none",
  shortcut: <ChevronRightSmallIcon className="size-4" />,
} as const;

export function InboxFilterMenu({
  filters,
  onFiltersChange,
  platformCounts,
  scheduleCounts,
  ruleSection,
  statusCounts,
  workspaceSelector,
}: InboxFilterMenuProps) {
  const messages = useCommaMessages();
  const hasWorkspaceFilter =
    workspaceSelector !== undefined && workspaceSelector.workspaces.length > 1;
  const isFiltered = isInboxFiltered(filters);
  const platformOptions: TaskFilterOption[] = TASK_ORIGIN_KEYS.filter(
    (key) => platformCounts.has(key) || filters.platforms?.has(key)
  ).map((key) => ({
    count: platformCounts.get(key) ?? 0,
    icon: <TaskOriginIcon className="size-4" origin={key} />,
    id: key,
    label: taskOriginLabel(messages, key),
  }));
  if (
    platformCounts.has(INBOX_NO_PLATFORM) ||
    filters.platforms?.has(INBOX_NO_PLATFORM)
  ) {
    platformOptions.push({
      count: platformCounts.get(INBOX_NO_PLATFORM) ?? 0,
      id: INBOX_NO_PLATFORM,
      label: messages.inbox_filter_platform_unspecified(),
    });
  }
  const platformSection: TaskFilterSection = {
    icon: <SquareGridCircleIcon />,
    id: "platform",
    label: messages.tasks_filter_platform(),
    onChange: (selected) =>
      onFiltersChange({
        ...filters,
        platforms: platformOptions.every((option) => selected.has(option.id))
          ? undefined
          : selected,
      }),
    options: platformOptions,
    selected: filters.platforms ?? new Set(platformOptions.map((option) => option.id)),
  };
  const scheduleOptions = taskLoopFilterOptions(
    scheduleCounts,
    messages,
    filters.schedules
  );
  // Shown, as on the Tasks page, once any Task is a Loop or the filter narrows.
  const scheduleSection: TaskFilterSection | undefined =
    scheduleCounts.scheduled + scheduleCounts.event_triggered + scheduleCounts.unknown >
      0 || filters.schedules !== undefined
      ? {
          icon: <InfinityIcon />,
          id: "schedule",
          label: messages.tasks_loops(),
          onChange: (selected) =>
            onFiltersChange({
              ...filters,
              schedules: scheduleOptions.every((option) => selected.has(option.id))
                ? undefined
                : selected,
            }),
          options: scheduleOptions,
          selected:
            filters.schedules ?? new Set(scheduleOptions.map((option) => option.id)),
        }
      : undefined;

  return (
    <MenuTrigger>
      <AriaButton
        aria-label={messages.inbox_filters_actions()}
        className={cx(
          taskToolbarIconButtonClassName,
          isFiltered && "bg-tertiary text-primary"
        )}
        data-filtered={isFiltered ? "true" : "false"}
        data-testid="inbox-filter-trigger"
      >
        <Filter2Icon />
      </AriaButton>
      {/* Modal (React Aria's default): an outside press dismisses the menu.
          The Tasks filter keeps its surface non-modal so the sidebar resize
          handles stay live under it, and pays for that with a hand-rolled
          outside-dismiss hook; the rail's filter has no such requirement. */}
      <MenuPopover
        closeSubmenusOnPointerLeave
        offset={spacing.xs}
        placement="bottom start"
      >
        <Menu
          aria-label={messages.inbox_filters_actions()}
          className="w-44 bg-popup-secondary px-sm py-sm shadow-2xl"
        >
          <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
            <MenuItem {...submenuRowProps} icon={taskNeutralIcon()} id="status">
              {messages.inbox_filter_task_status()}
            </MenuItem>
            <MenuPopover offset={0} placement="right top">
              <div data-testid="inbox-status-filter">
                <TaskStatusFilterPanel
                  counts={statusCounts}
                  onChange={(statuses) => onFiltersChange({ ...filters, statuses })}
                  // "12 notifications" beside "Needs Review" outgrows the
                  // Tasks panel's width.
                  panelClassName="w-72"
                  renderCount={(count) => <InboxNotificationCount count={count} />}
                  selectedStatuses={filters.statuses}
                />
              </div>
            </MenuPopover>
          </SubmenuTrigger>
          <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
            <MenuItem {...submenuRowProps} icon={platformSection.icon} id="platform">
              {platformSection.label}
            </MenuItem>
            <MenuPopover offset={0} placement="right top">
              <div data-testid="inbox-platform-filter">
                <TaskSectionFilterPanel
                  panelClassName="w-72"
                  renderCount={(count) => <InboxNotificationCount count={count} />}
                  section={platformSection}
                />
              </div>
            </MenuPopover>
          </SubmenuTrigger>
          {scheduleSection ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem {...submenuRowProps} icon={scheduleSection.icon} id="schedule">
                {scheduleSection.label}
              </MenuItem>
              <MenuPopover offset={0} placement="right top">
                <div data-testid="inbox-schedule-filter">
                  <TaskSectionFilterPanel
                    panelClassName="w-72"
                    renderCount={(count) => <InboxNotificationCount count={count} />}
                    section={scheduleSection}
                  />
                </div>
              </MenuPopover>
            </SubmenuTrigger>
          ) : null}
          {/* As on the Tasks page, the trigger rule follows the Loop type. */}
          {ruleSection ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem {...submenuRowProps} icon={ruleSection.icon} id="loopRule">
                {ruleSection.label}
              </MenuItem>
              <MenuPopover offset={0} placement="right top">
                <div data-testid="inbox-loop-rule-filter">
                  <TaskSectionFilterPanel
                    panelClassName="w-72"
                    renderCount={(count) => <InboxNotificationCount count={count} />}
                    section={ruleSection}
                  />
                </div>
              </MenuPopover>
            </SubmenuTrigger>
          ) : null}
          {hasWorkspaceFilter ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem {...submenuRowProps} icon={<CircleCheckIcon />} id="workspace">
                {messages.inbox_workspace()}
              </MenuItem>
              <MenuPopover offset={0} placement="right top">
                <InboxWorkspaceFilterPanel workspaceSelector={workspaceSelector} />
              </MenuPopover>
            </SubmenuTrigger>
          ) : null}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
