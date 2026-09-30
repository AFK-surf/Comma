import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { DeviceSettings } from "../DeviceSettings";

describe("Device settings", () => {
  it("shows both devices and changes only the chosen device permission", async () => {
    const add = vi.fn();
    const manual = vi.fn();
    function Harness() {
      const [allow, setAllow] = useState(false);
      return (
        <DeviceSettings
          title="Devices"
          description="Connections and runtimes"
          statusDescription="Connection is separate from readiness"
          summary="2 devices"
          accessDetailsLabel="Permissions & details"
          readOnlyLabel="Read-only access"
          operationsLabel="Operations allowed"
          closeLabel="Done"
          guidedLabel="Ask Comma"
          addLabel="Add device"
          manualLabel="Manual setup"
          localLabel="This device"
          loadingLabel="Loading"
          emptyLabel="No devices"
          agentsLabel="Agent runtimes"
          emptyAgentsLabel="No agents"
          accessLabel="Allow operations"
          onManual={manual}
          onAdd={add}
          onLoadMore={vi.fn()}
          hasMore
          devices={[
            {
              id: "local",
              name: "My Mac",
              local: true,
              connected: true,
              status: "Online",
              agents: [
                {
                  id: "codex",
                  name: "Codex",
                  status: "Sign in required",
                  ready: false,
                  details: ["Version: 1.0"],
                },
                {
                  id: "codex-other",
                  name: "Codex",
                  status: "Sign in required",
                  ready: false,
                  details: ["Version: 2.0"],
                },
              ],
              access: {
                allowed: allow,
                disabled: false,
                description: allow ? "Can execute" : "Read only",
                onChange: setAllow,
              },
            },
            {
              id: "remote",
              name: "Office",
              connected: false,
              status: "Offline",
              agents: [],
              access: {
                allowed: false,
                disabled: true,
                description: "Read only",
                onChange: vi.fn(),
              },
            },
          ]}
        />
      );
    }
    render(<Harness />);
    const local = within(screen.getByRole("article", { name: "My Mac" }));
    const remote = within(screen.getByRole("article", { name: "Office" }));
    expect(local.getByText("Online")).toBeVisible();
    expect(
      local
        .getAllByText("Sign in required")
        .some((element) => element.closest("summary"))
    ).toBe(true);
    expect(local.getByText("Codex (2)")).toBeVisible();
    expect(local.getByText("Version: 1.0")).not.toBeVisible();
    await userEvent.click(local.getByText("Codex (2)"));
    expect(local.getByText("Version: 1.0")).toBeVisible();
    expect(local.getByText("Version: 2.0")).toBeVisible();
    await userEvent.click(
      remote.getByRole("button", { name: "Permissions & details" })
    );
    expect(screen.getByRole("switch")).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Done" }));
    await userEvent.click(local.getByRole("button", { name: "Permissions & details" }));
    await userEvent.click(screen.getByRole("switch"));
    expect(screen.getByText("Can execute")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Done" }));
    expect(local.getByText("Operations allowed")).toBeVisible();
    expect(remote.getByText("Read-only access")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Add device" }));
    await userEvent.click(screen.getByRole("button", { name: "Ask Comma" }));
    expect(add).toHaveBeenCalledOnce();
    await userEvent.click(screen.getByRole("button", { name: "Add device" }));
    await userEvent.click(screen.getByRole("button", { name: "Manual setup" }));
    expect(manual).toHaveBeenCalledOnce();
  });
});
