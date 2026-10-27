import { useTopic } from "@comma/core-client";
import type { ChatTaskAction, ChatTaskRunChoice } from "@comma/chat-contract";
import { taskRunOptions, type ChatTaskRun, type TaskRunOption } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown, type DropdownItem } from "@comma/ui/components/dropdown";
import { useMemo, useState } from "react";
import { WorkerModelMark } from "../thread/activity/WorkerModelMark";
import { taskRunLabel, taskRunPlace } from "./taskRunLabel";

type CommaMessages = ReturnType<typeof useCommaMessages>;

const RUNTIME_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex" };

/** An option's model in reader words: its name, or the default it stands for. */
function optionLabel(messages: CommaMessages, option: TaskRunOption): string {
  if (option.model) return option.model;
  if (option.runtime)
    return messages.task_panel_run_model_runtime_default({
      runtime: RUNTIME_NAMES[option.runtime] ?? option.runtime,
    });
  return messages.task_run_default_model();
}

/** Why a switch was refused, in the reader's words where the reason is known. */
export function taskRunRefusal(messages: CommaMessages, error: unknown): string {
  const detail = (error as { detail?: unknown } | null)?.detail as
    | { code?: unknown; reason?: unknown; message?: unknown }
    | undefined;
  if (detail?.code !== "task_run_refused") return messages.task_run_failed();
  switch (detail.reason) {
    case "device_offline":
      return messages.task_run_refused_offline();
    case "station_outdated":
      return messages.task_run_refused_outdated();
    case "cloud_vm_not_running":
      return messages.task_run_refused_cloud_vm();
    case "task_running":
      return messages.task_run_refused_running();
    default:
      return typeof detail.message === "string" && detail.message
        ? messages.task_run_refused({ why: detail.message })
        : messages.task_run_failed();
  }
}

/**
 * What a person picks a Task's next model from, and the switch: the options (`taskRunOptions`) as dropdown items,
 * each under where it runs, the one picked, and whether the switch runs or why it was refused.
 */
export function useTaskRunChoice(
  workspaceId: string,
  onSwitch: (run: ChatTaskRunChoice) => Promise<unknown>,
  /**
   * Where a Task that cannot move runs (only what runs there is offered), and whether it runs on computers alone (not
   * inside Comma).
   */
  limits: { within?: ChatTaskRun | undefined; computers?: boolean | undefined } = {}
) {
  const messages = useCommaMessages();
  const { value: models } = useTopic({ topic: "models", prefer: workspaceId });
  const { value: devices } = useTopic({ topic: "devices", prefer: workspaceId });
  const { within, computers } = limits;
  const options = useMemo(
    () => taskRunOptions(models, devices, { within, computers }),
    [models, devices, within, computers]
  );
  const [chosen, setChosen] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const items = useMemo<DropdownItem[]>(
    () =>
      options.map((option) => ({
        id: option.id,
        label: optionLabel(messages, option),
        group: taskRunPlace(messages, option.place),
        leading: <WorkerModelMark className="size-4" vendor={option.vendor} />,
      })),
    [messages, options]
  );
  const picked = options.find((option) => option.id === chosen);
  /** Switches to the option picked; `done` once the server took it. */
  const switchRun = (done?: () => void) => {
    if (!picked || busy) return;
    setBusy(true);
    setError(undefined);
    onSwitch(picked.run).then(
      () => {
        setBusy(false);
        done?.();
      },
      (reason: unknown) => {
        setBusy(false);
        setError(taskRunRefusal(messages, reason));
      }
    );
  };
  return {
    busy,
    chosen,
    error,
    items,
    loading: !models || !devices,
    picked,
    setChosen,
    switchRun,
  };
}

/**
 * Runs a Task on another model, perhaps in another place: Comma's models, the Cloud VM's and those of the person's
 * computers that take a Task now (`taskRunOptions`), each under where it runs. The Task goes on from where it is;
 * the new model reads what was said so far.
 */
export function TaskRunDialog({
  unsupported = [],
  onClose,
  onSwitch,
  run,
  workspaceId,
}: {
  /**
   * What the Task cannot take: `move`, it switches only to another runtime or model where it runs; `comma`, it runs on
   * computers alone.
   */
  unsupported?: readonly ChatTaskAction[] | undefined;
  onClose: () => void;
  /** Settles once the server took it; fails with why not. */
  onSwitch: (run: ChatTaskRunChoice) => Promise<unknown>;
  /** Where the Task runs now, to say so. */
  run: ChatTaskRun | undefined;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const { busy, chosen, error, items, loading, picked, setChosen, switchRun } =
    useTaskRunChoice(workspaceId, onSwitch, {
      ...(unsupported.includes("move") ? { within: run } : {}),
      computers: unsupported.includes("comma"),
    });

  return (
    <Dialog
      isOpen
      isDismissable={!busy}
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
      title={messages.task_run_title()}
      description={messages.task_run_description()}
      actions={[
        {
          label: messages.task_run_cancel(),
          hierarchy: "secondary-gray",
          disabled: busy,
          onPress: onClose,
        },
        {
          label: messages.task_run_confirm(),
          hierarchy: "primary",
          disabled: !picked || busy,
          onPress: () => switchRun(onClose),
        },
      ]}
    >
      <div className="flex flex-col gap-lg" data-testid="task-run-dialog">
        {run ? (
          // Where it runs now, as the Task panel names it, above what it will run on.
          <div className="flex flex-col gap-1.5" data-testid="task-run-current">
            <span className="text-sm font-medium text-secondary">
              {messages.task_run_current()}
            </span>
            <div className="flex min-w-0 items-center gap-sm rounded-md bg-secondary px-[calc(var(--spacing-lg)+var(--spacing-xxs))] py-md text-sm text-secondary">
              <WorkerModelMark className="size-4 shrink-0" vendor={run.vendor} />
              <span className="truncate">{taskRunLabel(messages, run)}</span>
            </div>
          </div>
        ) : null}
        <div className="flex flex-col gap-sm">
          <Dropdown
            ariaLabel={messages.task_run_model()}
            className="w-full"
            disabled={busy}
            items={items}
            label={messages.task_run_model()}
            loading={loading}
            onChange={setChosen}
            placeholder={messages.task_run_pick()}
            {...(chosen ? { value: chosen } : {})}
          />
          {error ? (
            <p role="alert" className="text-pretty text-xs text-error-primary">
              {error}
            </p>
          ) : null}
        </div>
      </div>
    </Dialog>
  );
}
