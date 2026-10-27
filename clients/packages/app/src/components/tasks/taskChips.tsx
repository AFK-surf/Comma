import type { TaskStatusBucket } from "@comma/ui/components/task-workspace";
import { useCommaMessages } from "@comma/i18n/react";
import type { ProductInboxItem, TaskLoop } from "@comma/core-client";
import type { TaskFilterOption } from "@comma/ui/components/task-workspace";
import {
  CalendarIcon,
  EyeIcon,
  InfinityIcon,
  MacbookIcon,
  MergedIcon,
  PullRequestClosedIcon,
  PullRequestIcon,
} from "@comma/ui/components/icons";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, type MouseEvent, type ReactElement, type ReactNode } from "react";
import { HoverCard, type HoverCardProps } from "@comma/ui/components/hover-card";
import { TaskLoopHoverDetails } from "./TaskLoopHoverDetails";
import {
  TASK_LOOP_FILTER_KEYS,
  taskLoopFilterKey,
  taskLoopFilterLabel,
  taskLoopLabel,
  type TaskLoopFilterKey,
  type TaskLoopFilterCounts,
} from "./taskLoopLabels";
import { LabelDot } from "./labelColor";
import { TaskOriginIcon, type TaskOriginKey } from "./taskOrigin";

/** A Tasks filter opened from a task property or chip. */
export type TasksFilterLink =
  | { label: string }
  | { platform: TaskOriginKey }
  | { status: TaskStatusBucket }
  | { clientPlatform: string }
  /** A Loop trigger type, or Tasks without a Loop. */
  | { schedule: TaskLoopFilterKey }
  | { loopRule: string };

/** Opens Tasks with the selected property as its filter. */
export function useOpenTasksFilter(): (filter: TasksFilterLink) => void {
  const navigate = useNavigate();
  return useCallback(
    (filter: TasksFilterLink) => {
      void navigate({ search: filter, to: "/tasks" });
    },
    [navigate]
  );
}

/**
 * The chip either is a button of its own (Task properties panel) or sits
 * inside a card that is already a button, where it stays a plain span whose
 * click just does not reach the card. A span chip opens its hover card on
 * pointer hover only: it is not a tab stop inside the card's button or link.
 */
function Chip({
  children,
  className,
  kind,
  nested = false,
  onOpen,
  size,
  testId,
  ariaLabel,
  hoverContent,
  hoverClassName = "",
  hoverPlacement,
}: {
  children: ReactNode;
  className: string;
  kind: "label" | "platform" | "pull-request" | "schedule";
  nested?: boolean | undefined;
  onOpen?: (() => void) | undefined;
  size?: "md" | "sm" | undefined;
  testId?: string | undefined;
  ariaLabel?: string | undefined;
  hoverContent?: ReactNode;
  hoverClassName?: string | undefined;
  hoverPlacement?: HoverCardProps["placement"] | undefined;
}) {
  const open = (event: MouseEvent) => {
    event.stopPropagation();
    event.preventDefault();
    onOpen?.();
  };
  let chip: ReactElement;
  if (!onOpen) {
    chip = (
      <span
        aria-label={ariaLabel}
        className={className}
        data-chip={kind}
        data-size={size}
        data-testid={testId}
      >
        {children}
      </span>
    );
  } else if (nested) {
    // A chip inside the card's button stays a pointer-only filter shortcut.
    // Keyboard users open Properties through the card or use the filter menu.
    chip = (
      <span
        className={className}
        data-interactive="true"
        data-chip={kind}
        data-testid={testId}
        onClick={open}
        role="presentation"
      >
        {children}
      </span>
    );
  } else {
    chip = (
      <button
        aria-label={ariaLabel}
        className={className}
        data-interactive="true"
        data-chip={kind}
        data-testid={testId}
        onClick={open}
        type="button"
      >
        {children}
      </button>
    );
  }
  return hoverContent ? (
    <HoverCard
      className={hoverClassName}
      content={hoverContent}
      pointerOnly={!onOpen || nested}
      {...(hoverPlacement ? { placement: hoverPlacement } : {})}
    >
      {chip}
    </HoverCard>
  ) : (
    chip
  );
}

export function TaskLabelChip({
  color,
  name,
  nested,
  onOpen,
  size = "md",
  testId,
}: {
  color: string | undefined;
  name: string;
  nested?: boolean;
  onOpen?: (() => void) | undefined;
  /** `sm` drops the vertical padding for chips that sit inside a text line. */
  size?: "md" | "sm";
  testId?: string | undefined;
}) {
  return (
    <Chip
      className="comma-task-label-chip"
      kind="label"
      nested={nested}
      onOpen={onOpen}
      size={size}
      testId={testId}
    >
      <LabelDot color={color} />
      <span className="comma-task-label-chip-text">{name}</span>
    </Chip>
  );
}

/** A coding Task's pull request, as its card shows it. */
export type TaskPullRequest = NonNullable<ProductInboxItem["pullRequest"]>;

const pullRequestStateIcons = {
  closed: PullRequestClosedIcon,
  draft: PullRequestIcon,
  merged: MergedIcon,
  open: PullRequestIcon,
} as const satisfies Record<TaskPullRequest["state"], typeof PullRequestIcon>;

/**
 * The Task's pull request: its number, with its state as the mark and, for assistive technology, in words after the
 * number. With `onOpen` (a card) it opens the pull request on click, like the other chips; without (a hover
 * card) it only shows.
 */
export function TaskPullRequestChip({
  nested,
  onOpen,
  pullRequest,
}: {
  nested?: boolean;
  onOpen?: (() => void) | undefined;
  pullRequest: TaskPullRequest;
}) {
  const messages = useCommaMessages();
  const Icon = pullRequestStateIcons[pullRequest.state];
  const name = messages.coding_pr_link({ number: String(pullRequest.number) });
  const state = {
    closed: messages.recommendations_pr_state_closed(),
    draft: messages.recommendations_pr_state_draft(),
    merged: messages.recommendations_pr_state_merged(),
    open: messages.recommendations_pr_state_open(),
  }[pullRequest.state];
  return (
    <Chip
      className="comma-task-label-chip comma-task-pull-request-chip"
      kind="pull-request"
      nested={nested}
      onOpen={onOpen}
      testId="task-card-pull-request"
    >
      <span aria-hidden data-state={pullRequest.state} title={state}>
        <Icon />
      </span>
      <span className="comma-task-label-chip-text">{name}</span>
      {/* A chip inside a card is a plain span, which carries no aria-label: the state is words in its text. */}
      <span className="app-sr-only">{`, ${state}`}</span>
    </Chip>
  );
}

export function TaskPlatformChip({
  label,
  nested,
  onOpen,
  origin,
  testId,
}: {
  label: string;
  nested?: boolean;
  onOpen?: (() => void) | undefined;
  origin: TaskOriginKey;
  testId?: string | undefined;
}) {
  return (
    <Chip
      className="comma-task-label-chip comma-task-platform-chip"
      kind="platform"
      nested={nested}
      onOpen={onOpen}
      testId={testId}
    >
      <TaskOriginIcon origin={origin} />
      <span className="comma-task-label-chip-text">{label}</span>
    </Chip>
  );
}

/**
 * Where a Task a station hosts runs: on which machine, with which model, and whether the machine is offline (where
 * this device knows).
 */
export function TaskHostChip({
  host,
  nested,
  testId,
}: {
  host: { machine: string | null; online: boolean | null; model: string | null };
  nested?: boolean;
  testId?: string | undefined;
}) {
  const messages = useCommaMessages();
  const where = [host.machine, host.model].filter(Boolean).join(" · ");
  return (
    <Chip
      className="comma-task-label-chip comma-task-platform-chip"
      kind="platform"
      nested={nested}
      testId={testId}
    >
      <MacbookIcon />
      <span className="comma-task-label-chip-text">
        {where ? messages.station_task_on({ where }) : messages.station_task_hosted()}
        {host.online === false ? ` · ${messages.station_task_offline()}` : ""}
      </span>
    </Chip>
  );
}

/** A Loop's trigger label on cards, or its icon in the compact Inbox rail. */
export function TaskScheduleChip({
  loop,
  iconOnly = false,
  nested,
  onOpen,
  testId,
}: {
  loop: TaskLoop;
  iconOnly?: boolean;
  nested?: boolean;
  onOpen?: (() => void) | undefined;
  testId?: string | undefined;
}) {
  const messages = useCommaMessages();
  const label = taskLoopLabel(loop, messages);
  return (
    <Chip
      className={`comma-task-label-chip comma-task-schedule-chip${iconOnly ? " comma-task-schedule-chip-icon" : ""}`}
      kind="schedule"
      nested={nested}
      onOpen={onOpen}
      testId={testId}
      ariaLabel={iconOnly ? label : undefined}
      hoverClassName="comma-task-loop-hover-card"
      hoverContent={<TaskLoopHoverDetails loop={loop} />}
      // In the Inbox the icons stack one row apart: the preview opens beside
      // the icon, so it never covers the icon of the row below.
      hoverPlacement={iconOnly ? "end" : undefined}
    >
      <TaskLoopTypeIcon kind={taskLoopFilterKey(loop)} />
      {iconOnly ? null : <span className="comma-task-label-chip-text">{label}</span>}
    </Chip>
  );
}

function TaskLoopTypeIcon({ kind }: { kind: TaskLoopFilterKey }) {
  if (kind === "scheduled") return <CalendarIcon />;
  if (kind === "event_triggered") return <EyeIcon />;
  if (kind === "unknown") return <InfinityIcon />;
  return <span aria-hidden className="size-md" />;
}

/** Tasks and Inbox offer the same cadence choices and keep unknown cadences separate. */
export function taskLoopFilterOptions(
  counts: TaskLoopFilterCounts,
  messages: ReturnType<typeof useCommaMessages>,
  selected?: ReadonlySet<string>
): TaskFilterOption[] {
  return TASK_LOOP_FILTER_KEYS.filter(
    (key) => key !== "unknown" || counts.unknown > 0 || selected?.has(key)
  ).map((key) => ({
    id: key,
    count: counts[key],
    label: taskLoopFilterLabel(key, messages),
    icon: <TaskLoopTypeIcon kind={key} />,
  }));
}

/**
 * "+N labels" for the labels a squeezed list row folds away. Rendered after
 * the label chips wherever they appear; only the list's compact container
 * state shows it (cards wrap their chips and never need it).
 */
export function TaskLabelOverflowChip({ count }: { count: number }) {
  const messages = useCommaMessages();
  return (
    <span className="comma-task-label-chip comma-task-chip-more" data-chip="more">
      <span className="comma-task-label-chip-text">
        {messages.tasks_labels_more({ count })}
      </span>
    </span>
  );
}
