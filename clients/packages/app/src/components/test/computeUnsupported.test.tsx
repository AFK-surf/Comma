import type { ComputeValue, DevicesValue } from "@comma/core/contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, within } from "@comma/test-utils/render";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { beforeEach, expect, it } from "vitest";
import { SettingsCategory } from "../../test/settingsHarness";
import { useDeviceSettingsCategory } from "../devices/useDeviceSettingsCategory";

// Settings › Devices' compute environment where this computer cannot host one: the desktop app on Windows or an
// Intel Mac shows none; a browser still offers the desktop app.

const workspace = "wsp_compute";

async function openDevices() {
  const core = createScriptedCore({
    values: (topic): ComputeValue | DevicesValue | undefined =>
      topic.topic === "compute"
        ? ({
            workspace,
            projection: { environments: [], workloads: [], next_workload_cursor: null },
            error: false,
            creation: null,
            accepted: null,
          } as unknown as ComputeValue)
        : topic.topic === "devices"
          ? {
              workspace,
              devices: [],
              cloud: null,
              hasMore: false,
              loading: false,
              failed: false,
              checks: {},
            }
          : undefined,
    calls: () => null,
  });
  const router = createRouter({
    routeTree: createRootRoute({
      component: () => <SettingsCategory category={useDeviceSettingsCategory(true)} />,
    }),
    history: createMemoryHistory(),
  });
  await router.load();
  render(core.wrap(<RouterProvider router={router} />));
  return within(await screen.findByLabelText("Settings content"));
}

beforeEach(() => {
  localStorage.setItem("comma.activeWorkspaceId", workspace);
});

it("shows no compute environment in the desktop app on a computer that cannot host one", async () => {
  // The desktop app's compute node on a computer that cannot host one (the bridge's unavailable state).
  installNativeBridgeMock({ platform: "electron" });
  const content = await openDevices();
  await content.findByRole("heading", { name: "Devices" });
  expect(content.queryByRole("region", { name: "Sandbox" })).not.toBeInTheDocument();
  expect(
    content.queryByRole("button", { name: "Open the desktop app" })
  ).not.toBeInTheDocument();
});

it("offers the desktop app in a browser", async () => {
  installNativeBridgeMock({ platform: "web" });
  const content = await openDevices();
  const section = within(await content.findByRole("region", { name: "Sandbox" }));
  expect(section.getByRole("button", { name: "Open the desktop app" })).toBeVisible();
});
