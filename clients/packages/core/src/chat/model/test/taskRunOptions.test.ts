import { describe, expect, it } from "vitest";
import type { ShownDevice, ShownModel } from "../../../contract.ts";
import { taskRunOptions } from "../taskRunOptions.ts";

const model = (id: string, serving: string[]): ShownModel => ({
  id,
  name: id.toUpperCase(),
  vendor: "anthropic",
  efforts: [],
  routes: {},
  serving,
});

const device = (id: string, extra: Partial<ShownDevice>): ShownDevice => ({
  device_id: id,
  name: `${id} name`,
  status: "connected",
  allows_operations: true,
  tasks_readiness: "ready",
  device_runtimes: [],
  ...extra,
});

describe("taskRunOptions", () => {
  it("offers Comma's default and the models a profile serves, then each place that takes a Task now", () => {
    const options = taskRunOptions(
      { models: [model("opus", ["prf_1"]), model("unserved", [])] },
      {
        cloud: device("dev_vm", { task_models: { codex: ["gpt-5.5"] } }),
        devices: [
          device("dev_mac", {
            name: "Studio",
            alias: "comma",
            task_models: { claude: ["opus"], codex: [] },
          }),
          device("dev_off", {
            status: "disconnected",
            task_models: { claude: ["opus"] },
          }),
          device("dev_old", {
            tasks_readiness: "station_outdated",
            task_models: { claude: ["opus"] },
          }),
        ],
      }
    );
    expect(options.map((option) => [option.id, option.run])).toEqual([
      ["salix", { runsOn: { kind: "salix" }, model: null }],
      [
        "salix:opus",
        { runsOn: { kind: "salix" }, model: { kind: "catalog", model: "opus" } },
      ],
      ["cloud_vm", { runsOn: { kind: "cloud_vm" }, model: null }],
      [
        "cloud_vm:codex:gpt-5.5",
        {
          runsOn: { kind: "cloud_vm" },
          model: { kind: "runtime", provider: "codex", model: "gpt-5.5" },
        },
      ],
      // A computer's runtime with no models runs nothing a Task can name (no account for it there).
      [
        "station:dev_mac:claude",
        {
          runsOn: { kind: "station", deviceId: "dev_mac" },
          model: { kind: "runtime", provider: "claude" },
        },
      ],
      [
        "station:dev_mac:claude:opus",
        {
          runsOn: { kind: "station", deviceId: "dev_mac" },
          model: { kind: "runtime", provider: "claude", model: "opus" },
        },
      ],
    ]);
    expect(options.at(-1)).toMatchObject({
      place: { kind: "station", deviceId: "dev_mac", name: "Studio" },
      model: "opus",
      runtime: "claude",
      vendor: "anthropic",
    });
  });

  it("offers a Task that cannot move only what runs where it runs, of each runtime", () => {
    const devices = {
      cloud: null,
      devices: [
        device("dev_mac", {
          task_models: { claude: ["opus", "sonnet"], codex: ["gpt-5.5"] },
        }),
        device("dev_pc", { task_models: { claude: ["opus"] } }),
      ],
    };
    const within = {
      place: { kind: "station" as const, deviceId: "dev_mac", name: "Studio" },
      model: { kind: "runtime" as const, provider: "claude", name: "opus" },
    };
    expect(
      taskRunOptions({ models: [model("opus", ["prf_1"])] }, devices, { within }).map(
        (option) => option.id
      )
    ).toEqual([
      "station:dev_mac:claude",
      "station:dev_mac:claude:opus",
      "station:dev_mac:claude:sonnet",
      "station:dev_mac:codex",
      "station:dev_mac:codex:gpt-5.5",
    ]);
  });

  it("offers a Task that runs on computers alone each computer's options, nothing inside Comma", () => {
    const devices = {
      cloud: device("dev_vm", { task_models: { codex: ["gpt-5.5"] } }),
      devices: [
        device("dev_mac", { task_models: { claude: ["opus"] } }),
        device("dev_pc", { task_models: { codex: ["gpt-5.5"] } }),
      ],
    };
    expect(
      taskRunOptions({ models: [model("opus", ["prf_1"])] }, devices, {
        computers: true,
      }).map((option) => option.id)
    ).toEqual([
      "station:dev_mac:claude",
      "station:dev_mac:claude:opus",
      "station:dev_pc:codex",
      "station:dev_pc:codex:gpt-5.5",
    ]);
  });

  it("offers Comma's default alone before the models and computers are read", () => {
    expect(taskRunOptions(undefined, undefined).map((option) => option.id)).toEqual([
      "salix",
    ]);
  });
});
