import type { ListedScreen } from "@comma/core-client";
import type { DevicesValue } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { WebSettings } from "../../../test/settingsHarness";
import { requestScreenOnHome } from "../../remote-screen/pendingScreen";
import { rememberScreenModel } from "../../remote-screen/screenModels";

// Settings › Devices with Debug's mesh setting on: another computer's ⋯ offers its screen; this device's does not, as it
// would show itself inside itself. This device's offers its simulators instead, where its station has any.

vi.mock("../../commaClientSettings", async (original) => {
  const real = await original<typeof import("../../commaClientSettings")>();
  return {
    ...real,
    useOptionalCommaClientSettings: () => ({
      ...real.useOptionalCommaClientSettings(),
      computerMesh: "on",
    }),
  };
});
// (Home's route, where the tab opens: no router here)
vi.mock("@tanstack/react-router", async (original) => ({
  ...(await original<typeof import("@tanstack/react-router")>()),
  useNavigate: () => () => Promise.resolve(),
}));
vi.mock("../../remote-screen/pendingScreen", async (original) => ({
  ...(await original<typeof import("../../remote-screen/pendingScreen")>()),
  requestScreenOnHome: vi.fn(),
}));

const workspaceId = "wsp_view";
const computer = (device_id: string, name: string) =>
  ({
    device_id,
    name,
    station_id: `station-${device_id}`,
    status: "connected",
    screen_view: true,
    allows_operations: true,
    device_runtimes: [],
  }) as unknown as DevicesValue["devices"][number];
const simulator = (udid: string, name: string): ListedScreen => ({
  id: `simulator:${udid}`,
  instance: `${udid}/boot`,
  name,
  title: `${name} · iOS 27.2`,
  width: 0,
  height: 0,
  peek: true,
  capabilities: { input: "touch", buttons: [], panels: [] },
});

/** What this device's station lists. */
let listing: { screens: ListedScreen[]; avds: string[]; simulators: unknown[] };

beforeEach(() => {
  listing = { screens: [], avds: [], simulators: [] };
  vi.mocked(requestScreenOnHome).mockClear();
  installNativeBridgeMock({
    platform: "electron",
    connectorRuntime: {
      state: createNativeStateBridgeMock(() => ({
        revision: 1,
        scopes: [
          { workspaceId, available: true, scope: "" as const, deviceId: "dev_here" },
        ],
      })),
    },
  });
  localStorage.setItem("comma.activeWorkspaceId", workspaceId);
});
afterEach(() => localStorage.clear());

async function devicesPage() {
  const value: DevicesValue = {
    workspace: workspaceId,
    devices: [computer("dev_here", "pengx17"), computer("dev_mbp", "MacBook-Pro-373")],
    cloud: null,
    hasMore: false,
    loading: false,
    failed: false,
    checks: {},
  };
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "devices"
        ? value
        : topic.topic === "workspace"
          ? {
              status: "ready",
              workspace: { id: workspaceId, groupId: "grp", name: "Work" },
              selected: true,
            }
          : undefined,
    calls: (name, params) =>
      name === "devices.listScreens" &&
      (params as { device: string }).device === "dev_here"
        ? listing
        : null,
  });
  render(<WebSettings core={core} />);
  await flush();
  const nav = document.querySelector<HTMLElement>('[data-slot="settings-page"] nav')!;
  fireEvent.click(
    [...nav.querySelectorAll("button")].find(
      (button) => button.textContent?.trim() === "Devices"
    )!
  );
  await flush();
}

/** The ⋯ menu of the card named `name`: its rows. It stays open. */
async function actions(name: string) {
  fireEvent.click(screen.getByLabelText(`More actions for ${name}`));
  await flush();
  return screen.getAllByRole("menuitem").map((item) => item.textContent);
}
const close = async () => {
  fireEvent.keyDown(document.activeElement!, { key: "Escape" });
  await flush();
};

it("offers another computer's screen, not this device's own", async () => {
  await devicesPage();
  expect(await actions("MacBook-Pro-373")).toContain("View screen");
  await close();
  // (this device's card is headed by its name and marked "This device")
  const here = await actions("pengx17");
  expect(here).toContain("Rename device");
  expect(here).not.toContain("View screen");
  // Its station lists no simulator or emulator: nothing to view.
  expect(here).not.toContain("View simulators");
});

it("views this device's simulator chosen last, of those running", async () => {
  listing.screens = [simulator("A", "iPhone 17"), simulator("B", "iPhone Air")];
  rememberScreenModel(workspaceId, "dev_here", "ios", "iPhone Air");
  await devicesPage();
  await actions("pengx17");
  fireEvent.click(screen.getByRole("menuitem", { name: "View simulators" }));
  await flush();
  expect(requestScreenOnHome).toHaveBeenCalledExactlyOnceWith({
    workspaceId,
    device: "dev_here",
    apps: [],
    screen: listing.screens[1],
  });
});

it("opens the models to start where none of this device's runs", async () => {
  listing.simulators = [{ udid: "C", title: "iPhone 17 · iOS 27.2" }];
  await devicesPage();
  await actions("pengx17");
  fireEvent.click(screen.getByRole("menuitem", { name: "View simulators" }));
  await flush();
  expect(requestScreenOnHome).toHaveBeenCalledExactlyOnceWith({
    workspaceId,
    device: "dev_here",
    apps: [],
    target: "models",
  });
});
