import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../styles.css";
import { PluginBrandArtwork } from "./PluginBrandArtwork";
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
    icon: <PluginBrandArtwork brand="stillfail" name="still.fail" />,
    connectPending: false,
    onConnectAnother: () => undefined,
    onDisconnect: () => undefined,
    value: {
      stations: [
        {
          id: "dev_a",
          name: "Acme · desk",
          connected: true,
          connectedAt: "2026-11-08T10:00:00Z",
        },
        {
          id: "dev_b",
          name: "Personal · laptop",
          connected: false,
          connectedAt: "2026-11-07T22:00:00Z",
        },
        { id: "dev_c", name: null, connected: false, connectedAt: null },
      ],
      error: null,
      pending: null,
    },
  },
} satisfies Meta<typeof PluginStationsList>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Connected: Story = {};

export const None: Story = {
  args: { value: { stations: [], error: null, pending: null } },
};
