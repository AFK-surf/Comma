import type { Meta, StoryObj } from "@storybook/react-vite";
import { Badge } from "../index";

const badgeColors = ["gray", "brand", "success", "warning", "error"] as const;

const meta = {
  title: "Base components/Badges",
  component: Badge,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Badge>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Types: Story = {
  render: () => (
    <div className="flex flex-wrap gap-2">
      <Badge type="pill-color">Pill color</Badge>
      <Badge type="pill-outline">Pill outline</Badge>
      <Badge type="badge-color">Badge color</Badge>
      <Badge type="badge-modern">Badge modern</Badge>
    </div>
  ),
};

export const Colors: Story = {
  render: () => (
    <div className="flex flex-wrap gap-2">
      {badgeColors.map((color) => (
        <Badge key={color} color={color} dot>
          {color}
        </Badge>
      ))}
    </div>
  ),
};
