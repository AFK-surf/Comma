import { useMemo, useRef, useState, type ReactNode } from "react";
import { useInteractOutside } from "react-aria";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
} from "react-aria-components";
import { formatNumber as formatLocalizedNumber, type CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { motionDuration, spacing } from "../../tokens";
import {
  BarsThreeIcon,
  ChevronRightSmallIcon,
  ClaudeAiIcon,
  Filter2Icon,
  LayoutColumnIcon,
  OpenAiIcon,
  SettingsSliderHorizontalIcon,
  SquareCursorIcon,
} from "../icons";
import { InputField } from "../input";
import { Menu, MenuItem, MenuPopover, MenuTrigger, SubmenuTrigger } from "../menu";
import { menuFilterFieldClasses, menuSurfaceClasses } from "../menu/styles";
import { cx } from "../utils";
import type { TaskView } from "../task-board";
import {
  TASK_STATUS_COLUMNS,
  taskStatusIcon,
  taskStatusLabel,
  type TaskStatusBucket,
  type TaskWorker,
} from "./TaskSummaryCard";

export type TaskStatusCounts = Record<TaskStatusBucket, number>;
export type TaskWorkerCounts = Record<TaskWorker, number>;

export interface TaskFilterOption {
  count: number;
  icon?: ReactNode;
  id: string;
  label: string;
}

/**
 * A caller-defined filter dimension (labels, platforms) rendered as one more
 * submenu of the Tasks filter, multi-select like Status and Worker. Selection
 * and the resulting narrowing stay with the caller; the menu only edits the
 * selected set.
 */
export interface TaskFilterSection {
  icon: ReactNode;
  id: string;
  label: string;
  /**
   * Whether the section narrows the list right now. Defaults to "not every
   * option is selected"; a caller whose narrowing came from outside the menu
   * (a deep link to the one platform present) states it explicitly.
   */
  narrowed?: boolean | undefined;
  onChange: (selected: ReadonlySet<string>) => void;
  options: readonly TaskFilterOption[];
  selected: ReadonlySet<string>;
}

export function isTaskFilterSectionNarrowed(section: TaskFilterSection): boolean {
  return (
    section.narrowed ??
    (section.options.length > 0 && section.selected.size < section.options.length)
  );
}

export interface TaskWorkspaceToolbarActionsProps {
  filterSections?: readonly TaskFilterSection[] | undefined;
  onSelectedStatusesChange: (statuses: ReadonlySet<TaskStatusBucket>) => void;
  onSelectedWorkersChange: (workers: ReadonlySet<TaskWorker>) => void;
  onViewChange: (view: TaskView) => void;
  selectedStatuses: ReadonlySet<TaskStatusBucket>;
  selectedWorkers: ReadonlySet<TaskWorker>;
  statusCounts: TaskStatusCounts;
  view: TaskView;
  workerFilterOptions: readonly TaskWorker[];
  workerCounts: TaskWorkerCounts;
}

/**
 * The Tasks toolbar's round icon button. Exported so other product headers
 * (the Inbox rail) render the same control rather than a look-alike.
 */
export const taskToolbarIconButtonClassName =
  "relative inline-flex size-6 shrink-0 scale-100 items-center justify-center rounded-full border border-primary bg-fg-button text-markdown-icon-primary shadow-xs outline-none after:absolute after:left-1/2 after:top-1/2 after:size-10 after:-translate-x-1/2 after:-translate-y-1/2 transition-[scale,background-color,color] duration-[var(--motion-duration-feedback-out)] ease-[var(--motion-easing-smooth-out)] hover:bg-fg-button hover:text-markdown-icon-primary active:scale-[var(--motion-scale-tactile-pressed)] active:duration-[var(--motion-duration-feedback-in)] data-[pressed]:scale-[var(--motion-scale-tactile-pressed)] data-[pressed]:duration-[var(--motion-duration-feedback-in)] focus-visible:shadow-focus-gray-shadow-xs motion-reduce:transition-none motion-reduce:active:scale-100 motion-reduce:data-[pressed]:scale-100 [&_svg]:size-3";

// React Aria's submenu grace area disables pointer events on the parent menu.
// These panels are flush, so keep sibling triggers directly hit-testable.
const connectedSubmenuTriggerClasses = "pointer-events-auto";

function useDismissableNonModalPopover(
  isOpen: boolean,
  onOpenChange: (isOpen: boolean) => void
) {
  const popoverRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  // React Aria intentionally does not dismiss a root non-modal popover on an
  // outside interaction. Keep the surface non-modal so resize handles remain
  // interactive, and restore dismissal with its overlay interaction primitive.
  useInteractOutside({
    isDisabled: !isOpen,
    onInteractOutside: (event) => {
      const target = event.target as Node | null;
      const popoverGroup = popoverRef.current?.parentElement;

      if (
        !target ||
        triggerRef.current?.contains(target) ||
        popoverGroup?.contains(target)
      ) {
        return;
      }

      onOpenChange(false);
    },
    ref: popoverRef,
  });

  return { popoverRef, triggerRef };
}

export function TaskWorkspaceToolbarActions({
  filterSections = [],
  onSelectedStatusesChange,
  onSelectedWorkersChange,
  onViewChange,
  selectedStatuses,
  selectedWorkers,
  statusCounts,
  view,
  workerFilterOptions,
  workerCounts,
}: TaskWorkspaceToolbarActionsProps) {
  return (
    <div
      className="flex min-w-0 items-center gap-md"
      data-slot="task-workspace-toolbar-actions"
    >
      <TaskStatusFilter
        counts={statusCounts}
        filterSections={filterSections}
        onChange={onSelectedStatusesChange}
        onWorkersChange={onSelectedWorkersChange}
        selectedStatuses={selectedStatuses}
        selectedWorkers={selectedWorkers}
        workerFilterOptions={workerFilterOptions}
        workerCounts={workerCounts}
      />
      <TaskViewPicker onChange={onViewChange} view={view} />
    </div>
  );
}

function TaskViewPicker({
  onChange,
  view,
}: {
  onChange: (view: TaskView) => void;
  view: TaskView;
}) {
  const messages = useCommaMessages();
  const nextView = view === "board" ? "list" : "board";
  const [isOpen, setIsOpen] = useState(false);
  const { popoverRef, triggerRef } = useDismissableNonModalPopover(isOpen, setIsOpen);

  return (
    <DialogTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
      <AriaButton
        ref={triggerRef}
        aria-label={
          nextView === "list" ? messages.tasks_list_view() : messages.tasks_board_view()
        }
        className={taskToolbarIconButtonClassName}
        data-current-view={view}
        data-slot="task-view-action"
        data-view-target={nextView}
      >
        <SettingsSliderHorizontalIcon />
      </AriaButton>
      <MenuPopover
        ref={popoverRef}
        isNonModal
        offset={spacing.xs}
        placement="bottom end"
      >
        <AriaDialog
          aria-label={messages.tasks_view()}
          className="w-[var(--spacing-11xl)] rounded-xl bg-popup-secondary p-sm shadow-xs ring-1 ring-primary ring-inset outline-none"
          data-slot="task-view-panel"
        >
          <Menu
            aria-label={messages.tasks_view()}
            className="grid grid-cols-2 gap-sm"
            disallowEmptySelection
            onAction={(key) => {
              if (key === "board" || key === "list") {
                onChange(key);
                setIsOpen(false);
              }
            }}
            selectedKeys={[view]}
            selectionMode="single"
            variant="embedded"
          >
            <MenuItem
              contentClassName="[&_[data-slot=menu-item-icon]]:text-markdown-image-icon-primary"
              gutter="none"
              icon={<LayoutColumnIcon />}
              id="board"
              layout="tile"
            >
              {messages.tasks_board()}
            </MenuItem>
            <MenuItem
              contentClassName="[&_[data-slot=menu-item-icon]]:text-markdown-icon-primary"
              gutter="none"
              icon={<BarsThreeIcon />}
              id="list"
              layout="tile"
            >
              {messages.tasks_list()}
            </MenuItem>
          </Menu>
        </AriaDialog>
      </MenuPopover>
    </DialogTrigger>
  );
}

function TaskStatusFilter({
  counts,
  filterSections,
  onChange,
  onWorkersChange,
  selectedStatuses,
  selectedWorkers,
  workerFilterOptions,
  workerCounts,
}: {
  counts: TaskStatusCounts;
  filterSections: readonly TaskFilterSection[];
  onChange: (statuses: ReadonlySet<TaskStatusBucket>) => void;
  onWorkersChange: (workers: ReadonlySet<TaskWorker>) => void;
  selectedStatuses: ReadonlySet<TaskStatusBucket>;
  selectedWorkers: ReadonlySet<TaskWorker>;
  workerFilterOptions: readonly TaskWorker[];
  workerCounts: TaskWorkerCounts;
}) {
  const messages = useCommaMessages();
  const isFiltered =
    selectedStatuses.size < TASK_STATUS_COLUMNS.length ||
    (workerFilterOptions.length > 0 &&
      selectedWorkers.size < workerFilterOptions.length) ||
    filterSections.some(isTaskFilterSectionNarrowed);
  const [isOpen, setIsOpen] = useState(false);
  const { popoverRef, triggerRef } = useDismissableNonModalPopover(isOpen, setIsOpen);

  return (
    <MenuTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
      <AriaButton
        ref={triggerRef}
        aria-label={messages.tasks_filter_by_status()}
        className={cx(
          taskToolbarIconButtonClassName,
          isFiltered && "bg-tertiary text-fg-brand-primary"
        )}
        data-filtered={isFiltered ? "true" : "false"}
        data-slot="task-status-filter-trigger"
      >
        <Filter2Icon />
        {isFiltered ? (
          // A brand dot on the button's top-right edge, cut out from the
          // toolbar surface, so an active filter reads at a glance.
          <span
            aria-hidden
            className="absolute top-0 right-0 size-sm rounded-full bg-fg-brand-primary ring-2 ring-[var(--color-bg-primary)]"
            data-slot="task-status-filter-badge"
          />
        ) : null}
      </AriaButton>
      <MenuPopover
        closeSubmenusOnPointerLeave
        ref={popoverRef}
        isNonModal
        offset={spacing.xs}
        placement="bottom end"
      >
        <Menu
          aria-label={messages.tasks_filter()}
          className="w-[var(--task-workspace-filter-menu-width)] bg-popup-secondary px-sm py-sm shadow-2xl"
        >
          <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
            <MenuItem
              activeClassName="bg-secondary-hover text-sidebar-text-highlight"
              appearance="sidebar"
              className={connectedSubmenuTriggerClasses}
              contentClassName="h-8"
              gutter="none"
              icon={taskStatusIcon("backlog")}
              id="status"
              shortcut={<ChevronRightSmallIcon className="size-4" />}
            >
              {messages.tasks_filter_status()}
            </MenuItem>
            <MenuPopover isNonModal offset={0} placement="left top">
              <TaskStatusFilterPanel
                counts={counts}
                onChange={onChange}
                selectedStatuses={selectedStatuses}
              />
            </MenuPopover>
          </SubmenuTrigger>
          {workerFilterOptions.length > 0 ? (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
              <MenuItem
                activeClassName="bg-secondary-hover text-sidebar-text-highlight"
                appearance="sidebar"
                className={connectedSubmenuTriggerClasses}
                contentClassName="h-8"
                gutter="none"
                icon={<SquareCursorIcon />}
                id="worker"
                shortcut={<ChevronRightSmallIcon className="size-4" />}
              >
                {messages.tasks_filter_worker()}
              </MenuItem>
              <MenuPopover isNonModal offset={0} placement="left top">
                <WorkerFilterPanel
                  availableWorkers={workerFilterOptions}
                  counts={workerCounts}
                  onChange={onWorkersChange}
                  selectedWorkers={selectedWorkers}
                />
              </MenuPopover>
            </SubmenuTrigger>
          ) : null}
          {filterSections.map((section) => (
            <SubmenuTrigger delay={motionDuration.submenuOpenDelay} key={section.id}>
              <MenuItem
                activeClassName="bg-secondary-hover text-sidebar-text-highlight"
                appearance="sidebar"
                className={connectedSubmenuTriggerClasses}
                contentClassName="h-8"
                gutter="none"
                icon={section.icon}
                id={section.id}
                shortcut={<ChevronRightSmallIcon className="size-4" />}
              >
                {section.label}
              </MenuItem>
              <MenuPopover isNonModal offset={0} placement="left top">
                <TaskSectionFilterPanel section={section} />
              </MenuPopover>
            </SubmenuTrigger>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

/**
 * The searchable, multi-select status list behind the Tasks filter. Exported so
 * the Inbox rail's filter shows the same panel instead of its own list.
 */
export function TaskStatusFilterPanel({
  counts,
  onChange,
  panelClassName,
  renderCount,
  selectedStatuses,
}: {
  counts: TaskStatusCounts;
  onChange: (statuses: ReadonlySet<TaskStatusBucket>) => void;
  /** Overrides the panel width when `renderCount` yields longer labels. */
  panelClassName?: string | undefined;
  /** The count beside each status; defaults to the Tasks "{n} tasks" copy. */
  renderCount?: ((count: number) => ReactNode) | undefined;
  selectedStatuses: ReadonlySet<TaskStatusBucket>;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const visibleStatuses = useMemo(
    () =>
      TASK_STATUS_COLUMNS.filter((column) =>
        taskStatusLabel(column.bucket, locale)
          .toLocaleLowerCase(locale)
          .includes(normalizedQuery)
      ),
    [locale, normalizedQuery]
  );

  return (
    <FilterOptionsPanel
      className={panelClassName}
      empty={visibleStatuses.length === 0}
      label={messages.tasks_filter_status()}
      onQueryChange={setQuery}
      query={query}
    >
      <Menu
        aria-label={messages.tasks_filter_status()}
        className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
        onSelectionChange={(keys) =>
          onChange(
            keys === "all"
              ? new Set(TASK_STATUS_COLUMNS.map((column) => column.bucket))
              : new Set(Array.from(keys, (key) => String(key) as TaskStatusBucket))
          )
        }
        selectedKeys={selectedStatuses}
        selectionMode="multiple"
        shouldCloseOnSelect={false}
        variant="embedded"
      >
        {visibleStatuses.map((column) => {
          const label = taskStatusLabel(column.bucket, locale);
          return (
            <MenuItem
              activeClassName="bg-secondary-hover"
              contentClassName="h-8"
              gutter="none"
              icon={column.icon}
              id={column.bucket}
              key={column.bucket}
              selectionIndicator="checkbox"
              shortcut={
                renderCount ? (
                  renderCount(counts[column.bucket])
                ) : (
                  <TaskCount count={counts[column.bucket]} locale={locale} />
                )
              }
              textValue={label}
            >
              <span className="text-primary">{label}</span>
            </MenuItem>
          );
        })}
      </Menu>
    </FilterOptionsPanel>
  );
}

function WorkerFilterPanel({
  availableWorkers,
  counts,
  onChange,
  selectedWorkers,
}: {
  availableWorkers: readonly TaskWorker[];
  counts: TaskWorkerCounts;
  onChange: (workers: ReadonlySet<TaskWorker>) => void;
  selectedWorkers: ReadonlySet<TaskWorker>;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const workerOptions = [
    {
      icon: <OpenAiIcon />,
      id: "codex" as const,
      label: messages.tasks_filter_worker_codex(),
    },
    {
      icon: <ClaudeAiIcon />,
      id: "claude" as const,
      label: messages.tasks_filter_worker_claude(),
    },
  ];
  const visibleWorkers = workerOptions.filter(
    ({ id, label }) =>
      availableWorkers.includes(id) &&
      label.toLocaleLowerCase(locale).includes(normalizedQuery)
  );

  return (
    <FilterOptionsPanel
      empty={visibleWorkers.length === 0}
      label={messages.tasks_filter_worker()}
      onQueryChange={setQuery}
      query={query}
    >
      <Menu
        aria-label={messages.tasks_filter_worker()}
        className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
        onSelectionChange={(keys) =>
          onChange(
            keys === "all"
              ? new Set(availableWorkers)
              : new Set(Array.from(keys, (key) => String(key) as TaskWorker))
          )
        }
        selectedKeys={selectedWorkers}
        selectionMode="multiple"
        shouldCloseOnSelect={false}
        variant="embedded"
      >
        {visibleWorkers.map((worker) => (
          <MenuItem
            activeClassName="bg-secondary-hover"
            contentClassName="h-8"
            gutter="none"
            id={worker.id}
            icon={worker.icon}
            key={worker.id}
            selectionIndicator="checkbox"
            shortcut={<TaskCount count={counts[worker.id]} locale={locale} />}
            textValue={worker.label}
          >
            <span className="text-primary">{worker.label}</span>
          </MenuItem>
        ))}
      </Menu>
    </FilterOptionsPanel>
  );
}

/** One caller-defined dimension (labels, platforms): the same searchable multi-select as Worker. */
export function TaskSectionFilterPanel({
  panelClassName,
  renderCount,
  section,
}: {
  panelClassName?: string | undefined;
  renderCount?: ((count: number) => ReactNode) | undefined;
  section: TaskFilterSection;
}) {
  const locale = useCommaLocale();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const visibleOptions = section.options.filter((option) =>
    option.label.toLocaleLowerCase(locale).includes(normalizedQuery)
  );

  return (
    <FilterOptionsPanel
      className={panelClassName}
      empty={visibleOptions.length === 0}
      label={section.label}
      onQueryChange={setQuery}
      query={query}
    >
      <Menu
        aria-label={section.label}
        className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
        onSelectionChange={(keys) =>
          section.onChange(
            keys === "all"
              ? new Set(section.options.map((option) => option.id))
              : new Set(Array.from(keys, String))
          )
        }
        selectedKeys={section.selected}
        selectionMode="multiple"
        shouldCloseOnSelect={false}
        variant="embedded"
      >
        {visibleOptions.map((option) => (
          <MenuItem
            activeClassName="bg-secondary-hover"
            contentClassName="h-8"
            gutter="none"
            id={option.id}
            {...(option.icon ? { icon: option.icon } : {})}
            key={option.id}
            selectionIndicator="checkbox"
            shortcut={
              renderCount ? (
                renderCount(option.count)
              ) : (
                <TaskCount count={option.count} locale={locale} />
              )
            }
            textValue={option.label}
          >
            <span className="text-primary">{option.label}</span>
          </MenuItem>
        ))}
      </Menu>
    </FilterOptionsPanel>
  );
}

/**
 * The search-plus-options surface every filter submenu renders (Tasks status /
 * worker, Inbox status / platform / workspace). Exported so those panels stay one design.
 */
export function FilterOptionsPanel({
  children,
  className = "w-56",
  empty,
  label,
  onQueryChange,
  query,
}: {
  children: ReactNode;
  /** The panel's width; widen it when an option's count label runs long. */
  className?: string | undefined;
  empty: boolean;
  label: string;
  onQueryChange: (query: string) => void;
  query: string;
}) {
  const messages = useCommaMessages();
  return (
    <AriaDialog
      aria-label={label}
      className={cx(
        menuSurfaceClasses,
        "flex min-w-0 flex-col overflow-hidden bg-popup-secondary p-0 shadow-2xl",
        className
      )}
    >
      <InputField
        aria-label={messages.tasks_filter_search_placeholder()}
        className="w-full"
        fieldSize="sm"
        onChange={(event) => onQueryChange(event.target.value)}
        placeholder={messages.tasks_filter_search_placeholder()}
        suppressFocusRing
        value={query}
        wrapperClassName={menuFilterFieldClasses}
      />
      {empty ? (
        <p className="m-0 px-lg py-md text-center text-sm text-disabled">
          {messages.tasks_filter_no_options()}
        </p>
      ) : (
        children
      )}
    </AriaDialog>
  );
}

function TaskCount({ count, locale }: { count: number; locale: CommaLocale }) {
  const messages = useCommaMessages();
  return (
    <span className="tabular-nums">
      {messages.tasks_filter_task_count({
        count,
        formattedCount: formatLocalizedNumber(count, locale),
      })}
    </span>
  );
}
