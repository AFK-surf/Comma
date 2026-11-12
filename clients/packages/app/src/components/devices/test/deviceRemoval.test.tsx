import type { DevicesValue } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, expect, it } from "vitest";
import { WebSettings } from "../../../test/settingsHarness";

// Settings › Devices: a removal the server refuses says why when the server names it.

const workspaceId = "wsp_devices";

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  localStorage.setItem("comma.activeWorkspaceId", workspaceId);
});

afterEach(() => {
  localStorage.clear();
});

/** Settings over one offline computer, whose removal fails with `code`; the dialog it leaves open. */
async function refusedRemoval(code: string) {
  const value: DevicesValue = {
    workspace: workspaceId,
    devices: [
      {
        device_id: "dev_old",
        name: "Old Mac",
        status: "disconnected",
        allows_operations: true,
        device_runtimes: [],
      },
    ],
    cloud: null,
    hasMore: false,
    loading: false,
    failed: false,
    checks: {},
  };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "devices" ? value : undefined),
    calls: (name) => {
      if (name === "devices.remove")
        throw Object.assign(new Error("refused"), { code, status: 409 });
      return null;
    },
  });
  render(<WebSettings core={core} />);
  await flush();
  const nav = document.querySelector<HTMLElement>('[data-slot="settings-page"] nav')!;
  fireEvent.click(within(nav).getByText("Devices"));
  await flush();
  fireEvent.click(screen.getByLabelText("More actions for Old Mac"));
  await flush();
  fireEvent.click(screen.getByRole("menuitem", { name: "Delete device" }));
  await flush();
  const dialog = screen.getByRole("dialog");
  fireEvent.click(within(dialog).getByRole("button", { name: /Delete device/ }));
  await flush();
  expect(core.sentTo("devices.remove")).toEqual([
    { workspace: workspaceId, device: "dev_old" },
  ]);
  return within(dialog).getByRole("alert");
}

it("says that the computer's old connection has not confirmed its stop", async () => {
  expect(await refusedRemoval("device_stop_unconfirmed")).toHaveTextContent(
    "earlier connection has not confirmed that it stopped"
  );
});

it("says only that it failed for any other refusal", async () => {
  expect(await refusedRemoval("internal_error")).toHaveTextContent(
    "The result could not be confirmed"
  );
});
