import type { Meta, StoryObj } from "@storybook/react-vite";
import { Popup, Text } from "../index";

const meta = {
  title: "App components/Popup",
  component: Popup,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Popup>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <Popup>
      <Text weight="semibold">Quick actions</Text>
      <Text className="mt-xs text-tertiary" size="textSm">
        Open recent task, duplicate thread, or pin this workspace.
      </Text>
    </Popup>
  ),
};
