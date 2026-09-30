import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect } from "storybook/test";
import {
  ClaudeAiIcon,
  DevicesIcon,
  MacbookIcon,
  MoreHorizontalIcon,
  OpenAiIcon,
} from "../icons";
import { PiProviderLogo } from "../provider-brand-logos";
import { SettingsPanel } from "../index";

const meta = {
  title: "App components/Settings",
  component: SettingsPanel,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof SettingsPanel>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => <SettingsPanel className="h-[1008px] w-[1134px]" />,
  play: async ({ canvasElement }) => {
    const panel = canvasElement.querySelector('[data-slot="settings-panel"]');
    const row = canvasElement.querySelector('[data-slot="settings-row"]');

    await expect(panel).toHaveClass("bg-main-panel-bg");
    await expect(row).toHaveClass("bg-main-panel-item-bg");
  },
};

/**
 * One card per connected computer: what it is, what Comma may do there, and what
 * Comma found on it. States report in the trailing edge the controls share.
 */
export const RowStateAndMenu: Story = {
  render: () => (
    <SettingsPanel
      className="h-[720px] w-[1134px]"
      title="Devices"
      sections={[
        {
          id: "devices.office",
          title: "",
          items: [
            {
              id: "devices.office.identity",
              title: "Office Mac Studio",
              description: "macOS · arm64",
              icon: <MacbookIcon />,
              status: { label: "Connected", color: "success" },
              control: {
                type: "menu",
                label: "More",
                icon: <MoreHorizontalIcon />,
                items: [
                  { id: "rename", label: "Rename device", onPress: () => {} },
                  {
                    id: "remove",
                    label: "Delete device",
                    tone: "destructive",
                    onPress: () => {},
                  },
                ],
              },
            },
            {
              id: "devices.office.operations",
              title: "Allow operations",
              description:
                "Let Comma change files and run commands on this computer. With it off, Comma can only read files.",
              control: { type: "toggle", checked: true },
            },
          ],
        },
        {
          // What the computer has, rather than a setting of it.
          id: "devices.office.agents",
          title: "Agents on Office Mac Studio",
          items: [
            {
              id: "devices.office.codex",
              title: "Codex",
              description: "0.52.0",
              icon: <OpenAiIcon />,
              status: { label: "Available", color: "success" },
            },
            {
              id: "devices.office.claude",
              title: "Claude Code",
              description: "2.0.14 · Claude Code reports no authenticated account.",
              icon: <ClaudeAiIcon />,
              status: { label: "Unavailable", color: "warning" },
            },
            {
              id: "devices.office.pi",
              title: "Pi",
              description: "0.85.1",
              icon: <PiProviderLogo />,
              status: { label: "Available", color: "success" },
            },
          ],
        },
        {
          id: "devices.build",
          title: "",
          items: [
            {
              id: "devices.build.identity",
              title: "build-box-01",
              description: "Linux · x86_64",
              icon: <DevicesIcon />,
              status: { label: "Offline", color: "gray" },
            },
            {
              id: "devices.build.operations",
              title: "Allow operations",
              description:
                "Let Comma change files and run commands on this computer. With it off, Comma can only read files.",
              control: { type: "toggle", checked: false, disabled: true },
            },
          ],
        },
      ]}
    />
  ),
};
