import type { ManualTaskStatus } from "@comma/chat-contract";
import { taskStatusBucketLabel, type TaskStatusBucket } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  CheckIcon,
  CloudIcon,
  MacbookIcon,
  PeopleCircleIcon,
  PlusSmallIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { taskStatusBucket, taskStatusIcon } from "@comma/ui/components/task-workspace";
import { Button as AriaButton } from "react-aria-components";
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CommaConversation, CommaTaskLabel } from "@comma/core/api-schemas";
import type { ChatTaskActivity } from "@comma/chat-contract";
import type { TaskLoop } from "@comma/core-client";
import { LabelDot } from "../../tasks/labelColor";
import type { TasksFilterLink } from "../../tasks/taskChips";
import { TaskOriginIcon, taskOriginKey, taskOriginLabel } from "../../tasks/taskOrigin";
import { TaskLabelPicker } from "./labels/TaskLabelPicker";
import { TaskActivitySection } from "./TaskActivitySection";
import { TaskLoopSection } from "./TaskLoopSection";
import { useTaskLabelsCatalog } from "./labels/useTaskLabelsCatalog";
import type { ChatTaskRun } from "@comma/core/chat";
import { taskRunLabel } from "./taskRunLabel";

export type TaskDetailsStatusState = "idle" | "pending" | "failed";

export interface TaskDetailsPanelProps {
  /** The Task's milestones as its Activity; absent while the Task has none. */
  activity?: ChatTaskActivity | undefined;
  /** The Task's Agent works now; the Activity ends with a live row while the Task is in progress. */
  activityWorking?: boolean | undefined;
  /** The Task's facts the panel shows; a Loop Task's Loop comes as `loop`. */
  conversation: Pick<
    CommaConversation,
    "client_platform" | "id" | "labels" | "origin" | "status"
  >;
  groupId: string;
  /** A Loop Task's Loop, as the core read it; absent for every other Task. */
  loop?: TaskLoop | undefined;
  /** Where the Task runs and its model; the panel names no Agent. */
  run?: ChatTaskRun | undefined;
  /** Opens the Tasks page narrowed to the clicked property. */
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
  /**
   * Ends an in-progress or in-review Task by hand; absent when the viewer
   * cannot change this Task's status.
   */
  onSetStatus?: ((status: ManualTaskStatus) => unknown) | undefined;
  /** Replaces the Task's labels; absent when the viewer cannot edit labels. */
  onSetLabels?: ((labelIds: string[]) => unknown) | undefined;
  /** Who made the Task, where the panel says so (a Task a station hosts). */
  creator?: string | undefined;
  /** Whether the Task can carry labels at all (a Task a station hosts cannot): without, no Label section. */
  labeled?: boolean | undefined;
  /** Reads the Task's history the Activity has not read yet (`activity.earlier`). */
  onReadEarlierActivity?: (() => void) | undefined;
  /** Shows an Activity step's message in the Task chat; absent where no chat is shown. */
  onRevealActivityStep?: ((messageId: string) => void) | undefined;
  open: boolean;
  statusState?: TaskDetailsStatusState | undefined;
  /**
   * `column`: the second column of a Task route or the chat sidebar, folded
   * below the host's breakpoint.
   * `popover`: inside the trigger's popover once the column has folded.
   * `embedded`: the read-only Comma Web panel owns the outer scroll area.
   */
  layout?: "column" | "popover" | "embedded";
}

const PLATFORM_KEYS = [
  "macos",
  "windows",
  "linux",
  "ios",
  "android",
  "web",
  "unknown",
] as const;
type PlatformKey = (typeof PLATFORM_KEYS)[number];

function platformKey(platform: string | undefined): PlatformKey | undefined {
  if (!platform) return undefined;
  return PLATFORM_KEYS.find((key) => key === platform) ?? "unknown";
}

const manualStatusTargets: ReadonlyArray<{
  bucket: TaskStatusBucket;
  status: ManualTaskStatus;
}> = [
  { bucket: "done", status: "completed" },
  { bucket: "cancelled", status: "cancelled" },
];

const currentStatusKey = "current-status";

export function TaskDetailsPanel({
  activity,
  activityWorking = false,
  conversation,
  groupId,
  run,
  onOpenTasksFilter,
  onReadEarlierActivity,
  onRevealActivityStep,
  onSetLabels,
  onSetStatus,
  creator,
  labeled = true,
  loop,
  open,
  statusState = "idle",
  layout = "column",
}: TaskDetailsPanelProps) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const bucket = taskStatusBucket(conversation.status);
  const origin = taskOriginKey(conversation.origin);
  const platform =
    origin === "comma" ? platformKey(conversation.client_platform) : undefined;
  // At most the visible route and sidebar panels read once per membership change.
  // A server-approved new label must become visible without reopening the Task.
  const labelsKey = JSON.stringify([conversation.id, conversation.labels ?? []]);
  // The read starts when the details are first shown. A fold is the window's
  // width, not a new look at the Task: folding and unfolding while the window
  // is dragged across the breakpoint reads nothing more.
  const [shown, setShown] = useState(open);
  if (open && !shown) setShown(true);
  const { catalog } = useTaskLabelsCatalog(groupId, shown, labelsKey);
  const [labelBusy, setLabelBusy] = useState(false);

  const appliedIds = useMemo(() => conversation.labels ?? [], [conversation.labels]);
  const catalogById = useMemo(() => {
    const byId = new Map<string, CommaTaskLabel>();
    for (const label of catalog?.labels ?? []) byId.set(label.id, label);
    return byId;
  }, [catalog]);
  const applied = useMemo(
    () => appliedIds.flatMap((id) => catalogById.get(id) ?? []),
    [appliedIds, catalogById]
  );
  // A label deleted from the catalog leaves its id on the Task; the server
  // refuses any write naming it. Every write starts from the labels still in
  // the catalog, so a stale id can never block the next add or remove.
  const knownAppliedIds = useMemo(() => applied.map((label) => label.id), [applied]);
  const catalogLabels = catalog?.labels ?? [];
  const labelRequestNeedsAttention = useMemo(
    () =>
      catalog?.proposals.some(
        (proposal) =>
          (proposal.status === "pending" ||
            (proposal.status === "approved" &&
              ["pending", "conflict"].includes(proposal.application_status ?? ""))) &&
          ["create", "apply"].includes(proposal.op) &&
          proposal.payload["conversation_id"] === conversation.id
      ) ?? false,
    [catalog, conversation.id]
  );

  const changeLabels = useCallback(
    async (next: string[]) => {
      if (!onSetLabels) return;
      setLabelBusy(true);
      try {
        await onSetLabels(next);
      } finally {
        setLabelBusy(false);
      }
    },
    [onSetLabels]
  );
  // An unchecked chip starts leaving the moment the picker row is pressed,
  // ahead of the write; if the write fails it simply settles back into place.
  const [leavingLabelIds, setLeavingLabelIds] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const pickLabels = useCallback(
    async (next: string[]) => {
      const removed = knownAppliedIds.filter((id) => !next.includes(id));
      if (removed.length > 0) {
        setLeavingLabelIds((current) => new Set([...current, ...removed]));
      }
      try {
        await changeLabels(next);
      } finally {
        if (removed.length > 0) {
          setLeavingLabelIds((current) => {
            const rest = new Set(current);
            for (const id of removed) rest.delete(id);
            return rest;
          });
        }
      }
    },
    [changeLabels, knownAppliedIds]
  );
  // The picker opens from whichever chip or "+" was pressed, so it sits
  // under the pointer.
  const addLabelRef = useRef<HTMLButtonElement>(null);
  const [pickerAnchor, setPickerAnchor] = useState<HTMLElement | null>(null);
  const pickerAnchorRef = useMemo(() => ({ current: pickerAnchor }), [pickerAnchor]);
  // A removed chip cannot position the open picker. Use the permanent button
  // before the browser paints, including when labels change outside this panel.
  useLayoutEffect(() => {
    if (pickerAnchor && !pickerAnchor.isConnected) {
      setPickerAnchor(addLabelRef.current);
    }
  }, [applied, pickerAnchor]);
  const canPickLabels = onSetLabels !== undefined && catalogLabels.length > 0;

  const platformLabel = (key: PlatformKey): string => {
    switch (key) {
      case "macos":
        return messages.task_panel_platform_macos();
      case "windows":
        return messages.task_panel_platform_windows();
      case "linux":
        return messages.task_panel_platform_linux();
      case "ios":
        return messages.task_panel_platform_ios();
      case "android":
        return messages.task_panel_platform_android();
      case "web":
        return messages.task_panel_platform_web();
      default:
        return messages.task_panel_platform_unknown();
    }
  };

  const statusTargets = onSetStatus
    ? manualStatusTargets.filter((target) => target.bucket !== bucket)
    : [];
  // A status change swaps the pill at once, with no exit or enter motion.
  const statusPill = (
    <>
      <span aria-hidden className="comma-icon-slot size-5 shrink-0 [&_svg]:size-5">
        {taskStatusIcon(bucket)}
      </span>
      {taskStatusBucketLabel(bucket, locale)}
    </>
  );
  // The pill opens the menu only when the Task can be ended by hand.
  const statusMenuEnabled = statusTargets.length > 0;

  const onStatusAction = (key: string | number) => {
    const target = statusTargets.find((candidate) => candidate.bucket === key);
    if (target && statusState !== "pending") onSetStatus?.(target.status);
  };

  return (
    <aside
      // A folded column is gone for assistive tech too.
      aria-hidden={!open}
      aria-label={messages.task_panel_region()}
      className="comma-task-panel"
      data-layout={layout}
      data-open={open ? "true" : "false"}
      data-testid="task-details-panel"
    >
      <div className="comma-task-panel-inner">
        <section
          className="comma-task-panel-section"
          data-testid="task-panel-properties"
        >
          <h2 className="comma-task-panel-heading">
            {messages.task_panel_properties()}
          </h2>
          <div className="comma-task-panel-row">
            <MenuTrigger>
              <AriaButton
                isDisabled={!statusMenuEnabled}
                data-interactive={statusMenuEnabled ? "true" : undefined}
                className="comma-task-panel-pill"
                data-status-pending={statusState === "pending" ? "true" : undefined}
                data-status={bucket}
                data-testid="task-conversation-status"
              >
                {statusPill}
              </AriaButton>
              <MenuPopover placement="bottom start">
                <Menu
                  aria-label={messages.task_panel_status_menu()}
                  onAction={onStatusAction}
                >
                  <MenuItem
                    icon={taskStatusIcon(bucket)}
                    // A stable id: React Aria refuses an item whose id changes,
                    // and the current status changes while the menu is mounted.
                    id={currentStatusKey}
                    key={currentStatusKey}
                    shortcut={<CheckIcon />}
                    textValue={taskStatusBucketLabel(bucket, locale)}
                  >
                    {taskStatusBucketLabel(bucket, locale)}
                  </MenuItem>
                  {statusTargets.map((target) => (
                    <MenuItem
                      icon={taskStatusIcon(target.bucket)}
                      id={target.bucket}
                      isDisabled={statusState === "pending"}
                      key={target.bucket}
                      textValue={taskStatusBucketLabel(target.bucket, locale)}
                    >
                      {taskStatusBucketLabel(target.bucket, locale)}
                    </MenuItem>
                  ))}
                </Menu>
              </MenuPopover>
            </MenuTrigger>
          </div>
          {statusState === "failed" ? (
            <p className="comma-task-panel-feedback" role="alert">
              {messages.task_panel_status_failed()}
            </p>
          ) : null}
          {origin ? (
            <div className="comma-task-panel-row">
              {onOpenTasksFilter ? (
                <button
                  className="comma-task-panel-pill"
                  data-interactive="true"
                  data-origin={origin}
                  data-testid="task-panel-origin"
                  onClick={() => onOpenTasksFilter({ platform: origin })}
                  type="button"
                >
                  <TaskOriginIcon origin={origin} />
                  {taskOriginLabel(messages, origin)}
                </button>
              ) : (
                <span
                  className="comma-task-panel-pill"
                  data-origin={origin}
                  data-testid="task-panel-origin"
                >
                  <TaskOriginIcon origin={origin} />
                  {taskOriginLabel(messages, origin)}
                </span>
              )}
            </div>
          ) : null}
          {run ? (
            <div className="comma-task-panel-row" data-testid="task-panel-run">
              <span className="comma-task-panel-pill">
                {run.place.kind === "station" ? (
                  <MacbookIcon className="size-5 text-quaternary" />
                ) : (
                  <CloudIcon className="size-5 text-quaternary" />
                )}
                {taskRunLabel(messages, run)}
              </span>
            </div>
          ) : null}
          {creator ? (
            <div className="comma-task-panel-row" data-testid="task-panel-creator">
              <span className="comma-task-panel-pill">
                <PeopleCircleIcon className="size-5 text-quaternary" />
                {messages.task_panel_created_by({ name: creator })}
              </span>
            </div>
          ) : null}
          {platform ? (
            <div className="comma-task-panel-row" data-testid="task-panel-platform">
              <button
                className="comma-task-panel-pill"
                type="button"
                disabled={!onOpenTasksFilter}
                data-interactive={onOpenTasksFilter ? "true" : undefined}
                onClick={() => onOpenTasksFilter?.({ clientPlatform: platform })}
              >
                <MacbookIcon className="size-5 text-quaternary" />
                {platformLabel(platform)}
              </button>
            </div>
          ) : null}
        </section>

        {labeled ? (
          <section className="comma-task-panel-section" data-testid="task-panel-labels">
            <h2 className="comma-task-panel-heading">{messages.task_panel_label()}</h2>
            <div className="comma-task-panel-chips">
              {applied.map((label) =>
                canPickLabels ? (
                  <button
                    className="comma-task-label-chip"
                    data-interactive="true"
                    data-leaving={leavingLabelIds.has(label.id) ? "true" : undefined}
                    key={label.id}
                    onClick={(event) => setPickerAnchor(event.currentTarget)}
                    type="button"
                  >
                    <LabelDot color={label.color} />
                    {label.name}
                  </button>
                ) : (
                  <span
                    className="comma-task-label-chip"
                    data-leaving={leavingLabelIds.has(label.id) ? "true" : undefined}
                    key={label.id}
                  >
                    <LabelDot color={label.color} />
                    {label.name}
                  </span>
                )
              )}
              {applied.length === 0 && !canPickLabels ? (
                <span className="comma-task-panel-empty">
                  {messages.task_panel_no_labels()}
                </span>
              ) : null}
              {canPickLabels ? (
                // With no label on the Task the button says what it does, outlined
                // like a label chip; after a label it is the bare plus.
                <AriaButton
                  {...(applied.length > 0
                    ? { "aria-label": messages.task_panel_add_label() }
                    : { "data-labeled": "true" })}
                  className="comma-task-panel-add-label"
                  ref={addLabelRef}
                  isDisabled={labelBusy}
                  onPress={(event) => setPickerAnchor(event.target as HTMLElement)}
                >
                  <PlusSmallIcon />
                  {applied.length > 0 ? null : messages.task_panel_add_label()}
                </AriaButton>
              ) : null}
            </div>
            {canPickLabels ? (
              <TaskLabelPicker
                anchorRef={pickerAnchorRef}
                appliedIds={knownAppliedIds}
                isDisabled={labelBusy}
                isOpen={pickerAnchor !== null}
                labels={catalogLabels}
                onChange={(next) => void pickLabels(next)}
                onOpenChange={(isOpen) => {
                  if (!isOpen) setPickerAnchor(null);
                }}
              />
            ) : null}
            {labelRequestNeedsAttention ? (
              <p
                className="comma-task-panel-muted"
                data-testid="task-panel-label-pending"
              >
                {messages.task_panel_label_pending()}
              </p>
            ) : null}
          </section>
        ) : null}

        {loop ? (
          <TaskLoopSection loop={loop} onOpenTasksFilter={onOpenTasksFilter} />
        ) : null}

        {activity ? (
          <TaskActivitySection
            activity={activity}
            onReadEarlier={onReadEarlierActivity}
            onRevealStep={onRevealActivityStep}
            working={bucket === "in_progress" && activityWorking}
          />
        ) : null}
      </div>
    </aside>
  );
}
