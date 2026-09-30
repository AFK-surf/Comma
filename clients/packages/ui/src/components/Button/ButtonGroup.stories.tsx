import type { Meta, StoryObj } from "@storybook/react-vite";
import { ButtonGroup } from "..";

const teamItems = [
  { id: "design", label: "Design" },
  { id: "product", label: "Product" },
  { id: "engineering", label: "Engineering" },
];

const meta = {
  title: "Base components/Button groups",
  parameters: {
    layout: "centered",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const TextOnly: Story = {
  render: () => <ButtonGroup items={teamItems} defaultValue="product" />,
};

export const WithDotIndicator: Story = {
  render: () => (
    <ButtonGroup
      items={[
        { id: "active", label: "Active", dot: true },
        { id: "paused", label: "Paused" },
        { id: "archived", label: "Archived" },
      ]}
      defaultValue="active"
    />
  ),
};
