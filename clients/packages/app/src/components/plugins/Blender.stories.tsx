import type { BlenderSnapshot } from "@comma/native-bridge";
import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../styles.css";
import { BlenderDetail, type Blender } from "./Blender";
import { PluginBrandArtwork } from "./PluginBrandArtwork";

const snapshot: BlenderSnapshot = {
  revision: 1,
  enabled: true,
  installs: [
    {
      path: "/Applications/Blender.app/Contents/MacOS/Blender",
      version: "4.2.23 LTS",
    },
  ],
  versions: ["4.2.23 LTS"],
  instances: [],
  waiting: 0,
};

const blender = (state: Partial<BlenderSnapshot>): Blender => ({
  available: true,
  snapshot: { ...snapshot, ...state },
  pending: false,
  install: async () => undefined,
  uninstall: async () => undefined,
  setEnabled: async () => undefined,
  open: async () => undefined,
  chooseApp: async () => undefined,
});

const meta = {
  title: "App components/Blender plugin",
  component: BlenderDetail,
  parameters: { layout: "fullscreen" },
  decorators: [
    (Story) => (
      <div className="h-screen">
        <Story />
      </div>
    ),
  ],
  args: {
    copy: {},
    definition: {
      id: "blender",
      name: "Blender",
      icon: <PluginBrandArtwork brand="blender" name="Blender" />,
      summary:
        "Look at, change, render and export your Blender scenes on this computer.",
      description:
        "Look at, change, render and export your Blender scenes on this computer.",
      mcps: [
        {
          id: "blender",
          name: "blender",
          icon: <PluginBrandArtwork brand="blender" name="Blender" />,
        },
      ],
    },
    installed: true,
    installPending: false,
    uninstallPending: false,
    blender: blender({}),
    onBack: () => undefined,
    onTryInChat: () => undefined,
  },
} satisfies Meta<typeof BlenderDetail>;

export default meta;
type Story = StoryObj<typeof meta>;

export const NotInstalled: Story = { args: { installed: false } };

export const NoWindows: Story = {};

export const Connected: Story = {
  args: {
    blender: blender({
      instances: [
        { id: "b1", version: "4.2.23 LTS", file: "/Users/me/robot.blend" },
        { id: "b2", version: "4.2.23 LTS", dirty: true },
      ],
    }),
  },
};

export const Waiting: Story = { args: { blender: blender({ waiting: 1 }) } };

export const Off: Story = { args: { blender: blender({ enabled: false }) } };

export const NotFound: Story = { args: { blender: blender({ installs: [] }) } };
