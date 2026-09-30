import type { Meta, StoryObj } from "@storybook/react-vite";
import { Slider } from "../index";

const meta = {
  title: "Base components/Sliders",
  component: Slider,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Slider>;

export default meta;
type Story = StoryObj<typeof meta>;

export const General: Story = {
  render: () => (
    <div className="flex w-80 max-w-full flex-col gap-6">
      <Slider defaultValue={0} />
      <Slider defaultValue={33} />
      <Slider defaultValue={66} />
      <Slider defaultValue={100} />
    </div>
  ),
};

export const Range: Story = {
  render: () => (
    <div className="flex w-80 max-w-full flex-col gap-8">
      <Slider range defaultValue={[0, 50]} />
      <Slider range defaultValue={[25, 75]} labelPosition="bottom" />
      <Slider range defaultValue={[0, 100]} labelPosition="tooltip" />
    </div>
  ),
};

export const Disabled: Story = {
  render: () => <Slider defaultValue={64} disabled />,
};
