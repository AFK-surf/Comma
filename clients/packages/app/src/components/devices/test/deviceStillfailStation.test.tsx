import type { DevicesValue, ShownDevice } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, expect, it } from "vitest";
import { WebSettings } from "../../../test/settingsHarness";

// Settings › Devices: a still.fail station is shown as one, beside an ordinary computer.

const workspaceId = "wsp_devices";

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  localStorage.setItem("comma.activeWorkspaceId", workspaceId);
});

afterEach(() => {
  localStorage.clear();
});

const station = (fields: Partial<ShownDevice> = {}): ShownDevice => ({
  device_id: "dev_station",
  device_kind: "stillfail",
  isStillfailStation: true,
  name: "Acme · studio",
  status: "connected",
  allows_operations: true,
  task_models: { codex: ["gpt-5.5", "gpt-5.4-mini"] },
  device_runtimes: [],
  ...fields,
});

const computer: ShownDevice = {
  device_id: "dev_mac",
  name: "Work Mac",
  status: "connected",
  allows_operations: true,
  access: "full",
  device_runtimes: [],
};

async function open(devices: ShownDevice[]) {
  const value: DevicesValue = {
    workspace: workspaceId,
    devices,
    cloud: null,
    hasMore: false,
    loading: false,
    failed: false,
    checks: {},
  };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "devices" ? value : undefined),
    calls: () => null,
  });
  render(<WebSettings core={core} />);
  await flush();
  const nav = document.querySelector<HTMLElement>('[data-slot="settings-page"] nav')!;
  fireEvent.click(within(nav).getByText("Devices"));
  await flush();
  return core;
}

it("shows its brand, that it is a still.fail station, its connection and models, with no access and no agent check", async () => {
  await open([computer, station()]);
  const card = screen.getByRole("article", { name: "Acme · studio" });
  expect(card.querySelector('[data-plugin-brand="stillfail"]')).not.toBeNull();
  expect(within(card).getByText("still.fail station")).toBeInTheDocument();
  expect(within(card).getByText("Connected")).toBeInTheDocument();
  expect(within(card).getByText("Codex")).toBeInTheDocument();
  expect(within(card).getByText("gpt-5.5, gpt-5.4-mini")).toBeInTheDocument();
  expect(within(card).queryByRole("button", { name: /Access/ })).toBeNull();
  expect(within(card).queryByText("No coding agents found")).toBeNull();
  // The computer beside it keeps its own.
  const mac = screen.getByRole("article", { name: "Work Mac" });
  expect(
    within(mac).getByRole("button", { name: /Work Mac Access/ })
  ).toBeInTheDocument();
  expect(within(mac).getByText("No coding agents found")).toBeInTheDocument();
});

it("says nothing of its models when it reports none", async () => {
  await open([station({ task_models: {} })]);
  const card = screen.getByRole("article", { name: "Acme · studio" });
  expect(within(card).queryByText("No coding agents found")).toBeNull();
  expect(within(card).queryByRole("region", { name: "Agents" })).toBeNull();
});

it("offers only Disconnect, which removes the device as the plugin's Disconnect does", async () => {
  const core = await open([station()]);
  fireEvent.click(screen.getByLabelText("More actions for Acme · studio"));
  await flush();
  expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
    "Details",
    "Disconnect",
  ]);
  fireEvent.click(screen.getByRole("menuitem", { name: "Disconnect" }));
  await flush();
  const dialog = screen.getByRole("dialog");
  expect(within(dialog).getByText("Disconnect Acme · studio?")).toBeInTheDocument();
  fireEvent.click(within(dialog).getByRole("button", { name: "Disconnect" }));
  await flush();
  expect(core.sentTo("devices.remove")).toEqual([
    { workspace: workspaceId, device: "dev_station" },
  ]);
});
