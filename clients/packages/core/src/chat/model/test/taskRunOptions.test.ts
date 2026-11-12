import { describe, expect, it } from "vitest";
import type { AgentModels, ShownDevice, ShownModel } from "../../../contract.ts";
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

/** The models page with no models and the workspace's Task place facts. */
const agents = (task_place: AgentModels["task_place"]) => ({
  models: [],
  agents: {
    workspace_id: "ws",
    agents: { router: { agent_id: "agt_router", name: "Router", role: "router" } },
    task_model: { selection: { kind: "builtin" } },
    task_place,
  } satisfies AgentModels,
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

  it("offers a sandbox Task the models its station runs, on its sandbox; none while the sandbox is not connected", () => {
    const devices = {
      cloud: device("dev_vm", { task_models: { codex: ["gpt-5.5"] } }),
      devices: [device("dev_mac", { task_models: { claude: ["opus"] } })],
    };
    const place = {
      kind: "sandbox" as const,
      state: "ready",
      taskModels: { claude: ["opus"], codex: [] },
    };
    const options = taskRunOptions({ models: [model("opus", ["prf_1"])] }, devices, {
      within: { place, model: { kind: "runtime", provider: "codex" } },
    });
    expect(options.map((option) => [option.id, option.run])).toEqual([
      [
        "sandbox:claude",
        { runsOn: { kind: "sandbox" }, model: { kind: "runtime", provider: "claude" } },
      ],
      [
        "sandbox:claude:opus",
        {
          runsOn: { kind: "sandbox" },
          model: { kind: "runtime", provider: "claude", model: "opus" },
        },
      ],
    ]);
    expect(options[0]).toMatchObject({ place, runtime: "claude", vendor: "anthropic" });
    expect(
      taskRunOptions({ models: [model("opus", ["prf_1"])] }, devices, {
        within: { place: { kind: "sandbox", state: "stopped" } },
      })
    ).toEqual([]);
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

  it("names the Cloud VM on an Agent VMM Host as its station, and offers a retired one elsewhere nothing", () => {
    const devices = {
      cloud: device("dev-cloudvm-abc", { task_models: { codex: ["gpt-5.5"] } }),
      devices: [],
    };
    const onHost = { kind: "station", deviceId: "dev-cloudvm-abc" } as const;
    // Retired or not, the Host's station is what a Task names; the picker still says Cloud VM.
    for (const retired of [true, false]) {
      const options = taskRunOptions(
        agents({
          place: { kind: "salix" },
          cloud_vm_retired: retired,
          cloud_vm_station: "dev-cloudvm-abc",
        }),
        devices
      );
      expect(options.map((option) => [option.id, option.run])).toEqual([
        ["salix", { runsOn: { kind: "salix" }, model: null }],
        ["cloud_vm", { runsOn: onHost, model: null }],
        [
          "cloud_vm:codex:gpt-5.5",
          {
            runsOn: onHost,
            model: { kind: "runtime", provider: "codex", model: "gpt-5.5" },
          },
        ],
      ]);
      expect(options[1]?.place).toEqual({ kind: "cloud_vm" });
    }
    // A Task that runs there and cannot move keeps the Cloud VM's options: the server names its place the Cloud VM.
    const there = taskRunOptions(
      agents({ place: { kind: "salix" }, cloud_vm_station: "dev-cloudvm-abc" }),
      devices,
      { within: { place: { kind: "cloud_vm" } } }
    );
    expect(there.map((option) => option.id)).toEqual([
      "cloud_vm",
      "cloud_vm:codex:gpt-5.5",
    ]);
    expect(there.map((option) => option.run.runsOn)).toEqual([onHost, onHost]);
    // Retired on Cloudflare, a Task there has nothing to switch to.
    expect(
      taskRunOptions(
        agents({ place: { kind: "salix" }, cloud_vm_retired: true }),
        devices,
        { within: { place: { kind: "cloud_vm" } } }
      )
    ).toEqual([]);
    // A Cloudflare Cloud VM is never named as a station; retired, it is no place.
    expect(
      taskRunOptions(
        agents({ place: { kind: "salix" }, cloud_vm_retired: true }),
        devices
      ).map((option) => option.id)
    ).toEqual(["salix"]);
    expect(
      taskRunOptions(agents({ place: { kind: "salix" } }), devices).map(
        (option) => option.run.runsOn
      )
    ).toEqual([{ kind: "salix" }, { kind: "cloud_vm" }, { kind: "cloud_vm" }]);
  });

  it("offers Comma's default alone before the models and computers are read", () => {
    expect(taskRunOptions(undefined, undefined).map((option) => option.id)).toEqual([
      "salix",
    ]);
  });
});
