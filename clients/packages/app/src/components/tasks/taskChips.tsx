import type { TaskStatusBucket } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, type MouseEvent, type ReactNode } from "react";
import { LabelDot } from "./labelColor";
import { TaskOriginIcon, type TaskOriginKey } from "./taskOrigin";

/** A Tasks filter opened from a task property or chip. */
export type TasksFilterLink =
  | { label: string }
  | { platform: TaskOriginKey }
  | { status: TaskStatusBucket }
  | { clientPlatform: string };

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
 * click just does not reach the card.
 */
function Chip({
  children,
  className,
  kind,
  nested = false,
  onOpen,
  size,
  testId,
}: {
  children: ReactNode;
  className: string;
  kind: "label" | "platform";
  nested?: boolean | undefined;
  onOpen?: (() => void) | undefined;
  size?: "md" | "sm" | undefined;
  testId?: string | undefined;
}) {
  if (!onOpen) {
    return (
      <span
        className={className}
        data-chip={kind}
        data-size={size}
        data-testid={testId}
      >
        {children}
      </span>
    );
  }
  const open = (event: MouseEvent) => {
    event.stopPropagation();
    event.preventDefault();
    onOpen();
  };
  if (nested) {
    // Inside the card's button the chip is a pointer-only shortcut: keyboard
    // users reach the same narrowing through the filter menu, and the chip's
    // text stays part of the card's own name.
    return (
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
  }
  return (
    <button
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
