import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { Button } from "../Button";
import { CubeIcon } from "../icons";
import {
  DeviceSettings,
  type DeviceAccessLevel,
  type DeviceSettingsItem,
} from "./DeviceSettings";
import {
  DeviceSettingsStatus,
  deviceSettingsButtonClassName,
} from "./DeviceSettingsContent";

const accessLevels = {
  off: { label: "Off", description: "Agents can't use this computer." },
  read: {
    label: "Read",
    description: "Agents can only read files.",
  },
  full: { label: "Full", description: "Agents can change files and run commands." },
};

/** The sandbox row as the desktop app's compute environment renders it on the card. */
const sandbox = (state: "off" | "settingUp" | "failed" | "ready") => (
  <section className="compute-node-summary" aria-label="Sandbox">
    <div className="comma-device__agent">
      <span className="comma-device__agent-mark" aria-hidden="true">
        <CubeIcon className="size-4" />
      </span>
      <span className="comma-device__agent-identity">
        <span className="comma-device__agent-name">Sandbox</span>
        {state === "settingUp" && (
          <DeviceSettingsStatus pending>Install components · 1/3</DeviceSettingsStatus>
        )}
        {state === "failed" && (
          <span className="comma-device__agent-status" data-attention="true">
            The workspace service could not be reached.
          </span>
        )}
      </span>
      {(state === "off" || state === "failed") && (
        <div className="compute-actions">
          <Button
            className={deviceSettingsButtonClassName}
            hierarchy="primary"
            size="sm"
          >
            {state === "off" ? "Enable this Mac" : "Continue setup"}
          </Button>
        </div>
      )}
    </div>
  </section>
);

const offline = (id: string, name: string): DeviceSettingsItem => ({
  id,
  name,
  connected: false,
  status: "Offline",
  metadata: [
    ["System", "macOS 15.5"],
    ["Chip", "Apple M2 Max"],
  ],
  menu: [
    { id: "remove", label: "Remove", destructive: true, onAction: () => undefined },
  ],
  agents: [],
  access: { level: "full", disabled: true, onChange: () => undefined },
});

type Stage =
  | "choose"
  | "signedOut"
  | "signingIn"
  | "settingUp"
  | "setupFailed"
  | "readFailed"
  | "ready";

const sourceItems = [
  { id: "workspace", label: "Workspace account" },
  { id: "local", label: "This device’s login" },
  { id: "none", label: "Do not use" },
];

function Page({ stage }: { stage: Stage }) {
  const [level, setLevel] = useState<DeviceAccessLevel>("full");
  const [sources, setSources] = useState<
    Record<"claude" | "codex", string | undefined>
  >({
    claude: stage === "choose" ? undefined : "local",
    codex: stage === "choose" ? undefined : "workspace",
  });
  const source = (provider: "claude" | "codex", name: string) => ({
    label: `${name} Account`,
    placeholder: "Choose",
    value: sources[provider],
    disabled: stage === "readFailed",
    items: sourceItems,
    onChange: (id: string) => setSources((held) => ({ ...held, [provider]: id })),
  });
  const signIn = {
    label: "Sign in",
    pending: false,
    busy: false,
    onPress: () => undefined,
  };
  const status = (provider: "claude" | "codex", name: string) => {
    if (stage === "readFailed") return "";
    const chosen = sources[provider];
    if (chosen === undefined)
      return "Choose the account this device uses for this agent";
    if (chosen === "workspace") return "Uses the workspace account";
    if (chosen === "none") return `This device does not run ${name}`;
    if (provider === "claude" && (stage === "signedOut" || stage === "signingIn"))
      return `${name} is not signed in on this Mac`;
    return "Uses this device’s login (dev@example.com)";
  };
  const local: DeviceSettingsItem = {
    id: "local",
    name: "zwg-Macbook.local",
    local: true,
    connected: true,
    status: "Connected",
    metadata: [
      ["Source", "Comma Dev"],
      ["Chip", "Apple M2 Max"],
      ["Memory", "64 GB"],
      ["System", "macOS 15.5"],
      ["Device ID", "dev_7f3c2a"],
    ],
    menu: [
      { id: "rename", label: "Rename", onAction: () => undefined },
      { id: "sandbox", label: "Local settings", onAction: () => undefined },
    ],
    content: sandbox(
      stage === "ready"
        ? "ready"
        : stage === "settingUp"
          ? "settingUp"
          : stage === "setupFailed"
            ? "failed"
            : "off"
    ),
    ...(stage === "readFailed"
      ? {
          agentsProblem: {
            label: "Cannot read the agent settings of this device.",
            retryLabel: "Try again",
            onRetry: () => undefined,
          },
        }
      : {}),
    agents: [
      {
        id: "codex",
        provider: "codex",
        name: "Codex",
        status: status("codex", "Codex"),
        ready: sources.codex === "workspace",
        details: [
          ["Version", "0.48.0"],
          ["Authentication", "ChatGPT"],
        ],
        source: source("codex", "Codex"),
      },
      {
        id: "claude",
        provider: "claude",
        name: "Claude Code",
        status: status("claude", "Claude Code"),
        ready: stage === "ready",
        attention: stage === "signedOut",
        details: [
          ["Version", "2.1.3"],
          ["Authentication", "Signed in"],
        ],
        source: source("claude", "Claude Code"),
        ...(sources.claude === "local" && stage === "signedOut"
          ? { signIn }
          : sources.claude === "local" && stage === "signingIn"
            ? { signIn: { ...signIn, label: "Cancel sign-in", busy: true } }
            : {}),
      },
    ],
    access: { level, disabled: false, onChange: setLevel },
  };
  return (
    <div className="h-[900px] w-[760px] bg-primary">
      <DeviceSettings
        title="Devices"
        addLabel="Add device"
        guidedLabel="Ask Comma to help"
        localLabel="This device"
        loadingLabel="Loading"
        emptyLabel="No computers"
        agentsLabel="Agents"
        emptyAgentsLabel="No agents found"
        accessLabel="Access"
        detailsLabel="Details"
        deviceLabel="Device"
        moreLabel={(name) => `More actions for ${name}`}
        offlineLabel={(count) => `Offline (${count})`}
        accessLevels={accessLevels}
        closeLabel="Close"
        devices={[
          local,
          offline("s1", "zwg-Macbook.local"),
          offline("s2", "office-mini"),
          offline("s3", "build-mac-2"),
        ]}
        onGuided={() => undefined}
        onLoadMore={() => undefined}
      />
    </div>
  );
}

const meta = {
  title: "Settings/DeviceSettings",
  component: Page,
  parameters: { layout: "fullscreen" },
} satisfies Meta<typeof Page>;

export default meta;
type Story = StoryObj<typeof meta>;

export const ChooseSource: Story = { args: { stage: "choose" } };
export const SignedOut: Story = { args: { stage: "signedOut" } };
export const SigningIn: Story = { args: { stage: "signingIn" } };
export const SettingUp: Story = { args: { stage: "settingUp" } };
export const SetupFailed: Story = { args: { stage: "setupFailed" } };
export const ReadFailed: Story = { args: { stage: "readFailed" } };
export const Details: Story = { args: { stage: "ready" } };
export const Ready: Story = { args: { stage: "ready" } };
