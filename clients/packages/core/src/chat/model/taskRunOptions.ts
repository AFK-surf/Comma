// The ways a Task can run from now on (`chatView.setTaskRun`), as a picker lists them: inside Comma with the
// workspace's default Task model or a catalog model some profile serves; on the workspace's Cloud VM (named as its
// Agent VMM Host's station there, not offered once retired elsewhere) or one of the person's computers that takes Tasks
// now, with its runtime's default or a model its profiles enabled; a sandbox Task on its own sandbox, with its
// runtime's default or a model its station runs.
import type { ChatTaskRun, ChatTaskRunChoice } from "@comma/chat-contract";
import type { DevicesValue, ModelsValue, ShownDevice } from "../../contract.ts";

export interface TaskRunOption {
  /** Unique among the options. */
  id: string;
  run: ChatTaskRunChoice;
  /**
   * Where it runs, as a Task's run names it: a computer with the name the person gave it. The Cloud VM is named so also
   * where `run` names it as its Agent VMM Host's station.
   */
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
 * Task that cannot move (`within`, where it runs now: a station, the Cloud VM, or a sandbox Task's own sandbox) has
 * only that place's options, of each runtime (a sandbox's from the models its station runs, `taskModels`: none while it is not
 * connected); one that cannot run inside Comma (`computers`) only the computers'.
 */
export function taskRunOptions(
  models:
    | (Pick<ModelsValue, "models"> & Partial<Pick<ModelsValue, "agents">>)
    | null
    | undefined,
  devices: Pick<DevicesValue, "devices" | "cloud"> | null | undefined,
  limits: { within?: ChatTaskRun | undefined; computers?: boolean | undefined } = {}
): TaskRunOption[] {
  const { within, computers } = limits;
  if (within) {
    const place = within.place;
    if (place.kind === "station")
      return taskRunOptions(models, devices).filter(
        (option) =>
          option.run.runsOn.kind === "station" &&
          option.run.runsOn.deviceId === place.deviceId
      );
    // The server names a Task on the Group's own VM as on the Cloud VM, also where it runs on its Agent VMM Host.
    if (place.kind === "cloud_vm")
      return taskRunOptions(models, devices).filter(
        (option) => option.place.kind === "cloud_vm"
      );
    if (place.kind === "sandbox")
      return runtimeOptions(
        "sandbox",
        { kind: "sandbox" },
        place,
        { task_models: place.taskModels },
        true
      );
    return [];
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
  const taskPlace = models?.agents?.task_place;
  // On an Agent VMM Host the Cloud VM is that Host's station, and a Task names it so; elsewhere it is named as the
  // Cloud VM, which is no place once retired.
  const cloudRunsOn: ChatTaskRunChoice["runsOn"] | null =
    cloud && taskPlace?.cloud_vm_station === cloud.device_id
      ? { kind: "station", deviceId: cloud.device_id }
      : taskPlace?.cloud_vm_retired
        ? null
        : { kind: "cloud_vm" };
  if (cloud && cloudRunsOn && takesTasks(cloud)) {
    const place = { kind: "cloud_vm" } as const;
    // Its default is Comma's own model, run with Codex.
    options.push({
      id: "cloud_vm",
      run: { runsOn: cloudRunsOn, model: null },
      place,
      vendor: "comma",
    });
    options.push(...runtimeOptions("cloud_vm", cloudRunsOn, place, cloud, false));
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

/** A place's options by runtime: its default (where `defaults`), then each model its station runs. */
function runtimeOptions(
  key: string,
  runsOn: ChatTaskRunChoice["runsOn"],
  place: TaskRunOption["place"],
  device: Pick<ShownDevice, "task_models">,
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
