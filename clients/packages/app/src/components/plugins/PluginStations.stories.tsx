import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../styles.css";
import { PluginStationsList } from "./PluginStations";

const meta = {
  title: "App components/still.fail stations",
  component: PluginStationsList,
  decorators: [
    (Story) => (
      <div className="w-[560px] p-xl">
        <Story />
      </div>
    ),
  ],
  args: {
    connectPending: false,
    onConnectAnother: () => undefined,
    onDisconnect: () => undefined,
    value: {
      stations: [
        {
          id: "dev_a",
          name: "pengx17 · Pengs-Mac-Mini-2",
          connected: true,
          connectedAt: "2026-11-08T10:00:00Z",
          workspace: "pengx17",
          emoji: "🦊",
          station: "Pengs-Mac-Mini-2",
          stationCount: 3,
        },
        {
          id: "dev_b",
          name: "AFK-surf Engineering · Office-Host-2",
          connected: false,
          connectedAt: "2026-11-07T22:00:00Z",
          workspace: "AFK-surf Engineering",
          emoji: null,
          station: "Office-Host-2",
          stationCount: null,
        },
        {
          id: "dev_c",
          name: null,
          connected: false,
          connectedAt: null,
          workspace: null,
          emoji: null,
          station: null,
          stationCount: null,
        },
      ],
      notificationLevel: "action_needed",
      notificationPending: false,
      error: null,
      pending: null,
    },
  },
} satisfies Meta<typeof PluginStationsList>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Connected: Story = {};

export const None: Story = {
  args: {
    value: {
      stations: [],
      notificationLevel: "action_needed",
      notificationPending: false,
      error: null,
      pending: null,
    },
  },
};
