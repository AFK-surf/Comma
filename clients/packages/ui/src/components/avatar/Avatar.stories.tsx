import type { Meta, StoryObj } from "@storybook/react-vite";
import { Avatar } from "../index";

const meta = {
  title: "Base components/Avatars",
  component: Avatar,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Avatar>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <div className="flex items-center gap-4">
      <Avatar name="Olivia Rhye" online />
      <Avatar name="Phoenix Baker" size="lg" />
      <Avatar name="Lana Steiner" size="sm" online={false} />
    </div>
  ),
};

export const Sizes: Story = {
  render: () => (
    <div className="flex items-end gap-3">
      {(["xs", "sm", "md", "lg", "xl", "2xl"] as const).map((size) => (
        <Avatar key={size} size={size} name="Comma DS" />
      ))}
    </div>
  ),
};
