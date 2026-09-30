import type { Meta, StoryObj } from "@storybook/react-vite";
import { Indicator } from "../index";

const indicatorColors = ["gray", "brand", "success", "warning", "error"] as const;

const meta = {
  title: "Base components/Indicators",
  component: Indicator,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Indicator>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Colors: Story = {
  render: () => (
    <div className="flex flex-wrap items-center justify-center gap-6">
      {indicatorColors.map((color) => (
        <span
          key={color}
          className="inline-flex items-center gap-2 text-sm text-secondary"
        >
          <Indicator color={color} pulse={color === "success"} label={color} />
          {color}
        </span>
      ))}
    </div>
  ),
};

export const Sizes: Story = {
  render: () => (
    <div className="flex items-center gap-5">
      <Indicator color="success" size="sm" label="Small" />
      <Indicator color="warning" size="md" label="Medium" />
      <Indicator color="error" size="lg" label="Large" />
    </div>
  ),
};
