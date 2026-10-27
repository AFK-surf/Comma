import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import {
  DeviceSettings,
  type DeviceAccessLevel,
  type DeviceSettingsItem,
  type DeviceSettingsProps,
} from "../DeviceSettings";

const accessLevels = {
  off: { label: "Off", description: "No access" },
  read: { label: "Read", description: "Reads files" },
  full: { label: "Full", description: "Can execute" },
};

const item = (id: string, name: string): DeviceSettingsItem => ({
  id,
  name,
  connected: true,
  status: "Connected",
  agents: [],
  metadata: [["Device ID", id]],
  access: { level: "read" as const, disabled: true, onChange: vi.fn() },
});

const labels = {
  title: "Devices",
  detailsLabel: "Details",
  deviceLabel: "Device",
  moreLabel: (name: string) => `More for ${name}`,
  offlineLabel: (count: number) => `Offline (${count})`,
  accessLevels,
  closeLabel: "Done",
  guidedLabel: "Ask Comma",
  addLabel: "Add device",
  localLabel: "This device",
  loadingLabel: "Loading",
  emptyLabel: "No devices",
  agentsLabel: "Agents",
  emptyAgentsLabel: "No agents",
  accessLabel: "Access",
  onLoadMore: vi.fn(),
} satisfies Partial<DeviceSettingsProps>;

/** `b` comes after `a` in the document. */
const follows = (a: Node, b: Node) =>
  Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);

describe("Device settings", () => {
  it("shows each agent once with only what keeps it from working, and folds offline computers", async () => {
    const guided = vi.fn();
    const signIn = vi.fn();
    function Harness() {
      const [level, setLevel] = useState<DeviceAccessLevel>("read");
      return (
        <DeviceSettings
          {...labels}
          addContent={<code>curl install</code>}
          onGuided={guided}
          devices={[
            {
              id: "local",
              name: "My Mac",
              local: true,
              connected: true,
              status: "Connected",
              agents: [
                {
                  id: "codex",
                  provider: "codex",
                  name: "Codex",
                  status: "",
                  ready: true,
                  details: [["Version", "1.0"]],
                },
                {
                  id: "codex-other",
                  provider: "codex",
                  name: "Codex",
                  status: "Sign in required",
                  ready: false,
                  details: [["Version", "2.0"]],
                },
                {
                  id: "claude",
                  provider: "claude",
                  name: "Claude Code",
                  status: "",
                  ready: false,
                  signIn: {
                    label: "Sign in for me",
                    pending: false,
                    busy: false,
                    onPress: signIn,
                  },
                },
              ],
              access: { level, disabled: false, onChange: setLevel },
            },
            {
              ...item("remote", "Office"),
              connected: false,
              status: "Offline",
              menu: [
                { id: "remove", label: "Remove", destructive: true, onAction: vi.fn() },
              ],
            },
          ]}
        />
      );
    }
    render(<Harness />);
    const local = within(screen.getByRole("article", { name: "My Mac" }));
    // Two Codex installs show as one row, which says nothing while it works; versions are in the details only.
    expect(local.getAllByText("Codex")).toHaveLength(1);
    expect(local.queryByText("1.0")).toBeNull();
    expect(local.queryByText("Sign in required")).toBeNull();
    // Claude Code is not signed in: the button that signs it in.
    await userEvent.click(local.getByRole("button", { name: "Sign in for me" }));
    expect(signIn).toHaveBeenCalledOnce();

    // An offline computer is one line in its own section, without agents or access.
    const offline = within(screen.getByRole("region", { name: "Offline (1)" }));
    const remote = within(offline.getByRole("article", { name: "Office" }));
    expect(remote.queryByText("Access")).toBeNull();

    // The access level is chosen on the card; each level says what it allows in the menu.
    await userEvent.click(local.getByRole("button", { name: /My Mac Access/ }));
    await userEvent.click(screen.getByRole("option", { name: /Full/ }));
    expect(local.getByRole("button", { name: /My Mac Access/ })).toHaveTextContent(
      "Full"
    );

    // Details open from the computer's menu.
    await userEvent.click(local.getByRole("button", { name: "More for My Mac" }));
    await userEvent.click(screen.getByRole("menuitem", { name: "Details" }));
    const details = screen.getByRole("dialog", { name: "My Mac" });
    expect(details).toHaveTextContent("Version1.0");
    expect(details).toHaveTextContent("Version2.0");
    await userEvent.keyboard("{Escape}");

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
        {...labels}
        onGuided={vi.fn()}
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
      section.getByRole("button", { name: "More for Cloud Workspace" })
    );
    await userEvent.click(screen.getByRole("menuitem", { name: "Details" }));
    expect(screen.getByRole("dialog", { name: "Cloud Workspace" })).toHaveTextContent(
      "Device IDvm"
    );
  });

  it("puts the agents, then access, then the sandbox after a divider", () => {
    render(
      <DeviceSettings
        {...labels}
        onGuided={vi.fn()}
        devices={[
          {
            ...item("local", "My Mac"),
            local: true,
            content: <section aria-label="Sandbox">Sandbox</section>,
            agents: [
              {
                id: "codex",
                provider: "codex",
                name: "Codex",
                status: "",
                ready: true,
              },
            ],
          },
        ]}
      />
    );
    const local = screen.getByRole("article", { name: "My Mac" });
    const agents = within(local).getByRole("region", { name: "Agents" });
    const access = within(local).getByRole("button", { name: /My Mac Access/ });
    const sandbox = within(local).getByRole("region", { name: "Sandbox" });
    expect(follows(agents, access)).toBe(true);
    expect(follows(access, sandbox)).toBe(true);
    // The sandbox is the VMM's: its own part of the card, not inside the agents or with access.
    expect(agents).not.toContainElement(sandbox);
    expect(sandbox.parentElement).toHaveClass("comma-device__sandbox");
  });

  it("chooses an agent's source in a dropdown that chooses nothing by itself, and says when it cannot read it", async () => {
    const chose = vi.fn();
    const link = vi.fn();
    const retry = vi.fn();
    const source = (value?: string) => ({
      label: "Codex Account",
      placeholder: "Choose",
      value,
      disabled: false,
      items: [
        { id: "workspace", label: "Workspace account" },
        { id: "local", label: "This device’s login" },
        { id: "none", label: "Do not use" },
      ],
      onChange: chose,
    });
    const { rerender } = render(
      <DeviceSettings
        {...labels}
        onGuided={vi.fn()}
        devices={[
          {
            ...item("local", "My Mac"),
            local: true,
            agents: [
              {
                id: "codex",
                provider: "codex",
                name: "Codex",
                status: "Choose the account this device uses for this agent",
                ready: false,
                source: source(),
              },
            ],
          },
        ]}
      />
    );
    const local = within(screen.getByRole("article", { name: "My Mac" }));
    // Both sources available and none chosen: the placeholder, not a default; the line says what to do.
    const dropdown = local.getByRole("button", { name: /Codex Account/ });
    expect(dropdown).toHaveTextContent("Choose");
    expect(
      local.getByText("Choose the account this device uses for this agent")
    ).toBeVisible();
    await userEvent.click(dropdown);
    expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual([
      "Workspace account",
      "This device’s login",
      "Do not use",
    ]);
    await userEvent.click(screen.getByRole("option", { name: "Workspace account" }));
    expect(chose).toHaveBeenCalledExactlyOnceWith("workspace");

    // A failed read: a note in the agents section with its retry, no alert at the card's top; the link on a row.
    rerender(
      <DeviceSettings
        {...labels}
        onGuided={vi.fn()}
        devices={[
          {
            ...item("local", "My Mac"),
            local: true,
            agentsProblem: {
              label: "Cannot read the agent settings of this device.",
              retryLabel: "Try again",
              onRetry: retry,
            },
            agents: [
              {
                id: "codex",
                provider: "codex",
                name: "Codex",
                status: "The workspace has no shared account yet",
                ready: false,
                link: { label: "Add workspace account", onPress: link },
                source: source("none"),
              },
            ],
          },
        ]}
      />
    );
    const agents = within(local.getByRole("region", { name: "Agents" }));
    const note = agents.getByRole("alert");
    expect(note).toHaveClass("comma-device__note");
    expect(note).toHaveTextContent("Cannot read the agent settings of this device.");
    expect(screen.getAllByRole("alert")).toHaveLength(1);
    await userEvent.click(within(note).getByRole("button", { name: "Try again" }));
    expect(retry).toHaveBeenCalledOnce();
    expect(local.getByRole("button", { name: /Codex Account/ })).toHaveTextContent(
      "Do not use"
    );
    await userEvent.click(local.getByRole("button", { name: "Add workspace account" }));
    expect(link).toHaveBeenCalledOnce();
  });
});
