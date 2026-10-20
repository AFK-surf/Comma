import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { DeviceSettings, type DeviceAccessLevel } from "../DeviceSettings";

const accessLevels = {
  off: { label: "Off", description: "No access", summary: "No access" },
  read: { label: "Read", description: "Reads files", summary: "Read-only access" },
  full: { label: "Full", description: "Can execute", summary: "Operations allowed" },
};

const item = (id: string, name: string) => ({
  id,
  name,
  connected: true,
  status: "Online",
  agents: [],
  metadata: [`Device ID: ${id}`],
  access: { level: "read" as const, disabled: true, onChange: vi.fn() },
});

describe("Device settings", () => {
  it("shows both devices and changes only the chosen device permission", async () => {
    const guided = vi.fn();
    function Harness() {
      const [level, setLevel] = useState<DeviceAccessLevel>("read");
      return (
        <DeviceSettings
          title="Devices"
          description="Connections and runtimes"
          statusDescription="Connection is separate from readiness"
          summary="2 devices"
          accessDetailsLabel="Permissions & details"
          accessLevels={accessLevels}
          closeLabel="Done"
          guidedLabel="Ask Comma"
          addLabel="Add device"
          addContent={<code>curl install</code>}
          localLabel="This device"
          loadingLabel="Loading"
          emptyLabel="No devices"
          agentsLabel="Agent runtimes"
          emptyAgentsLabel="No agents"
          accessLabel="Access"
          onGuided={guided}
          onLoadMore={vi.fn()}
          hasMore
          devices={[
            {
              id: "local",
              name: "My Mac",
              local: true,
              connected: true,
              status: "Online",
              tasks: { label: "Ready for Tasks", ready: true },
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
              access: { level, disabled: false, onChange: setLevel },
            },
            {
              id: "remote",
              name: "Office",
              connected: false,
              status: "Offline",
              path: "From here: through a relay",
              agents: [],
              access: { level: "read", disabled: true, onChange: vi.fn() },
            },
          ]}
        />
      );
    }
    render(<Harness />);
    const local = within(screen.getByRole("article", { name: "My Mac" }));
    const remote = within(screen.getByRole("article", { name: "Office" }));
    expect(local.getByText("Online")).toBeVisible();
    expect(local.getByText("Ready for Tasks")).toBeVisible();
    expect(remote.getByText("From here: through a relay")).toBeVisible();
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
    expect(screen.getByRole("radio", { name: /Full/ })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: "Done" }));
    await userEvent.click(local.getByRole("button", { name: "Permissions & details" }));
    expect(screen.getByRole("radio", { name: /Read/ })).toBeChecked();
    await userEvent.click(screen.getByRole("radio", { name: /Full/ }));
    expect(screen.getByRole("radio", { name: /Full/ })).toBeChecked();
    await userEvent.click(screen.getByRole("button", { name: "Done" }));
    expect(local.getByText("Operations allowed")).toBeVisible();
    expect(remote.getByText("Read-only access")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Add device" }));
    expect(screen.getByRole("dialog", { name: "Add device" })).toHaveTextContent(
      "curl install"
    );
    await userEvent.click(screen.getByRole("button", { name: "Ask Comma" }));
    expect(guided).toHaveBeenCalledOnce();
  });

  it("shows the Cloud VM in its own section", async () => {
    render(
      <DeviceSettings
        title="Devices"
        description="Connections and runtimes"
        statusDescription="Connection is separate from readiness"
        summary="1 of your computers"
        accessDetailsLabel="Permissions & details"
        accessLevels={accessLevels}
        closeLabel="Done"
        guidedLabel="Ask Comma"
        addLabel="Add device"
        localLabel="This device"
        loadingLabel="Loading"
        emptyLabel="No devices"
        agentsLabel="Agent runtimes"
        emptyAgentsLabel="No agents"
        accessLabel="Access"
        onGuided={vi.fn()}
        onLoadMore={vi.fn()}
        devices={[item("mac", "Office")]}
        cloud={item("vm", "Cloud Workspace")}
        cloudLabel="Cloud VM"
      />
    );
    const section = within(screen.getByRole("region", { name: "Cloud VM" }));
    expect(section.getByRole("heading", { name: "Cloud VM" })).toBeVisible();
    expect(section.getByRole("article", { name: "Cloud Workspace" })).toBeVisible();
    expect(section.queryByRole("article", { name: "Office" })).toBeNull();
    await userEvent.click(
      section.getByRole("button", { name: "Permissions & details" })
    );
    expect(screen.getByRole("dialog", { name: "Cloud Workspace" })).toHaveTextContent(
      "Device ID: vm"
    );
  });
});
