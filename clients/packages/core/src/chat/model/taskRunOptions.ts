// The ways a Task can run from now on (`chatView.setTaskRun`), as a picker lists them: inside Comma with the
// workspace's default Task model or a catalog model some profile serves; on the workspace's Cloud VM or one of the
// person's computers that takes Tasks now, with its runtime's default or a model its profiles enabled.
import type { ChatTaskRun, ChatTaskRunChoice } from "@comma/chat-contract";
import type { DevicesValue, ModelsValue, ShownDevice } from "../../contract.ts";

export interface TaskRunOption {
  /** Unique among the options. */
  id: string;
  run: ChatTaskRunChoice;
  /** Where it runs, as a Task's run names it: a computer with the name the person gave it. */
  place: ChatTaskRun["place"];
  /** The model's name; absent for a default, which `runtime` names on a computer. */
  model?: string;
  runtime?: "codex" | "claude";
  /** The model's maker, whose mark the picker shows (`comma` for Comma's own). */
  vendor?: string;
}

const RUNTIMES = ["claude", "codex"] as const;
const RUNTIME_VENDOR = { claude: "anthropic", codex: "openai" } as const;

/** A computer takes a Task now: connected, and its station speaks the Tasks protocol. */
const takesTasks = (device: ShownDevice) =>
  device.status === "connected" &&
  (device.tasks_readiness === undefined || device.tasks_readiness === "ready");

/**
 * The options, Comma's first, then the Cloud VM's, then each computer's; none of a place that cannot take a Task. A
 * Task that cannot move (`within`, where it runs now: a computer) has only that computer's options, of each runtime;
 * one that cannot run inside Comma (`computers`) only the computers'.
 */
export function taskRunOptions(
  models: Pick<ModelsValue, "models"> | null | undefined,
  devices: Pick<DevicesValue, "devices" | "cloud"> | null | undefined,
  limits: { within?: ChatTaskRun | undefined; computers?: boolean | undefined } = {}
): TaskRunOption[] {
  const { within, computers } = limits;
  if (within) {
    const place = within.place;
    return place.kind === "station"
      ? taskRunOptions(models, devices).filter(
          (option) =>
            option.place.kind === "station" && option.place.deviceId === place.deviceId
        )
      : [];
  }
  if (computers)
    return taskRunOptions(models, devices).filter(
      (option) => option.place.kind === "station"
    );
  const salix = { kind: "salix" } as const;
  const options: TaskRunOption[] = [
    { id: "salix", run: { runsOn: salix, model: null }, place: salix, vendor: "comma" },
  ];
  for (const model of models?.models ?? [])
    if (model.serving.length > 0)
      options.push({
        id: `salix:${model.id}`,
        run: { runsOn: salix, model: { kind: "catalog", model: model.id } },
        place: salix,
        model: model.name,
        vendor: model.vendor,
      });
  const cloud = devices?.cloud;
  if (cloud && takesTasks(cloud)) {
    const place = { kind: "cloud_vm" } as const;
    // Its default is Comma's own model, run with Codex.
    options.push({
      id: "cloud_vm",
      run: { runsOn: place, model: null },
      place,
      vendor: "comma",
    });
    options.push(...runtimeOptions("cloud_vm", place, place, cloud, false));
  }
  for (const device of devices?.devices ?? []) {
    if (!takesTasks(device)) continue;
    const runsOn = { kind: "station", deviceId: device.device_id } as const;
    const place = {
      kind: "station",
      deviceId: device.device_id,
      name: device.name,
    } as const;
    options.push(
      ...runtimeOptions(`station:${device.device_id}`, runsOn, place, device, true)
    );
  }
  return options;
}

/** A place's options by runtime: its default (where `defaults`), then each model its profiles enabled. */
function runtimeOptions(
  key: string,
  runsOn: ChatTaskRunChoice["runsOn"],
  place: TaskRunOption["place"],
  device: ShownDevice,
  defaults: boolean
): TaskRunOption[] {
  const options: TaskRunOption[] = [];
  for (const runtime of RUNTIMES) {
    const models = device.task_models?.[runtime];
    // A runtime it reports no models for runs nothing a Task can name: no account for it there.
    if (!models || models.length === 0) continue;
    const vendor = RUNTIME_VENDOR[runtime];
    if (defaults)
      options.push({
        id: `${key}:${runtime}`,
        run: { runsOn, model: { kind: "runtime", provider: runtime } },
        place,
        runtime,
        vendor,
      });
    for (const model of models)
      options.push({
        id: `${key}:${runtime}:${model}`,
        run: { runsOn, model: { kind: "runtime", provider: runtime, model } },
        place,
        model,
        runtime,
        vendor,
      });
  }
  return options;
}
