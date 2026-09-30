import { taskStatusBucketLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  MacbookIcon,
  PlusSmallIcon,
  taskStatusBucket,
  taskStatusIcon,
} from "@comma/ui";
import { Button as AriaButton } from "react-aria-components";
import {
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { CommaApiClient, CommaConversation, CommaTaskLabel } from "../../../api";
import { LabelDot } from "../../tasks/labelColor";
import type { TasksFilterLink } from "../../tasks/taskChips";
import { TaskOriginIcon, taskOriginKey, taskOriginLabel } from "../../tasks/taskOrigin";
import { TaskLabelPicker } from "./labels/TaskLabelPicker";
import { stateSwapExitMs, useLeaving } from "../motion/useLeaving";
import { useTaskLabelsCatalog } from "./labels/useTaskLabelsCatalog";
import type { ChatBoundWorker } from "../model/conversationChannel";
import { workerMeshGradientStyle } from "../thread/activity/workerAvatar";

export type TaskDetailsDoneState = "idle" | "pending" | "failed";

export interface TaskDetailsPanelProps {
  api?: CommaApiClient | undefined;
  /** True while the Task is awaiting review and the viewer may close it. */
  canDone: boolean;
  conversation: CommaConversation;
  doneState: TaskDetailsDoneState;
  groupId: string;
  worker?: ChatBoundWorker | undefined;
  onDone?: (() => void) | undefined;
  /** Opens the Tasks page narrowed to the clicked property. */
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
  /** Replaces the Task's labels; absent when the viewer cannot edit labels. */
  onSetLabels?: ((labelIds: string[]) => unknown) | undefined;
  open: boolean;
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

export function TaskDetailsPanel({
  api,
  canDone,
  conversation,
  doneState,
  groupId,
  worker,
  onDone,
  onOpenTasksFilter,
  onSetLabels,
  open,
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
  const { catalog } = useTaskLabelsCatalog(api, groupId, shown, labelsKey);
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

  // Needs Review → Done: the old state and its Done button clear first, then
  // the new state arrives; the departing nodes stay mounted through their
  // exit so nothing snaps.
  const leavingBucket = useLeaving(bucket, stateSwapExitMs);
  const statusLayers = leavingBucket === undefined ? [bucket] : [leavingBucket, bucket];
  const doneLeaving = useLeaving(canDone, stateSwapExitMs) === true && !canDone;

  let doneControl: ReactNode = null;
  if (onDone && (canDone || doneLeaving)) {
    doneControl = (
      <span
        className="comma-task-panel-done comma-status-swap-exit"
        data-leaving={doneLeaving ? "true" : undefined}
      >
        <Button
          // The Drive transfer panel's Retry at its compact scale: text-xs on
          // a 2px/4px inset, the label's own 2px making the 6px side inset.
          className="h-auto px-xs py-xxs text-xs"
          hierarchy="secondary-gray"
          isDisabled={doneState === "pending" || doneLeaving}
          onPress={onDone}
          size="sm"
        >
          {doneState === "pending"
            ? messages.task_panel_marking_done()
            : messages.task_panel_done()}
        </Button>
      </span>
    );
  }

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
            <button
              type="button"
              disabled={!onOpenTasksFilter}
              data-interactive={onOpenTasksFilter ? "true" : undefined}
              onClick={() => onOpenTasksFilter?.({ status: bucket })}
              className="comma-task-panel-pill comma-status-swap"
              data-status={bucket}
              data-swapping={leavingBucket === undefined ? undefined : "true"}
              data-testid="task-conversation-status"
            >
              {statusLayers.map((layer) => (
                <span
                  aria-hidden={layer !== bucket || undefined}
                  className="comma-status-swap-layer"
                  data-leaving={layer !== bucket ? "true" : undefined}
                  key={layer}
                >
                  <span
                    aria-hidden
                    className="comma-icon-slot size-5 shrink-0 [&_svg]:size-5"
                  >
                    {taskStatusIcon(layer)}
                  </span>
                  {taskStatusBucketLabel(layer, locale)}
                </span>
              ))}
            </button>
            {doneControl}
          </div>
          {doneState === "failed" ? (
            <p className="comma-task-panel-feedback" role="alert">
              {messages.tasks_accept_result_failed()}
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

        {worker ? (
          <section className="comma-task-panel-section" data-testid="task-panel-worker">
            <h2 className="comma-task-panel-heading">{messages.chat_actor_worker()}</h2>
            <div className="comma-task-panel-row">
              <span className="comma-task-panel-pill">
                <span
                  aria-hidden
                  className="comma-session-avatar"
                  style={workerMeshGradientStyle(
                    worker.actorId ?? worker.participantId
                  )}
                />
                {worker.name || messages.chat_actor_worker()}
              </span>
            </div>
          </section>
        ) : null}

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
              <AriaButton
                aria-label={messages.task_panel_add_label()}
                className="comma-task-panel-add-label"
                ref={addLabelRef}
                isDisabled={labelBusy}
                onPress={(event) => setPickerAnchor(event.target as HTMLElement)}
              >
                <PlusSmallIcon />
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
      </div>
    </aside>
  );
}
