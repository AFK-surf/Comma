import type { Meta, StoryObj } from "@storybook/react-vite";
import { Tag } from "../index";

const tagColors = ["gray", "brand", "success", "warning", "error"] as const;

const meta = {
  title: "Base components/Tags",
  component: Tag,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Tag>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Colors: Story = {
  render: () => (
    <div className="flex flex-wrap gap-2">
      {tagColors.map((color) => (
        <Tag key={color} color={color}>
          {color}
        </Tag>
      ))}
    </div>
  ),
};

export const Removable: Story = {
  render: () => (
    <div className="flex flex-wrap gap-2">
      <Tag onRemove={() => undefined}>Removable</Tag>
      <Tag color="success" onRemove={() => undefined}>
        Approved
      </Tag>
    </div>
  ),
};
