import type { Meta, StoryObj } from "@storybook/react-vite";
import { ResizeContainer } from "./ResizeContainer";

const meta = {
  title: "Dev components/Resize Container",
  component: ResizeContainer,
  parameters: {
    layout: "fullscreen",
  },
  argTypes: {
    mode: {
      control: "inline-radio",
      options: ["pixel", "relative"],
      description: "x/y/w/h 的读数与窗口 resize 适配方式",
    },
    minWidth: { control: { type: "number", min: 40, step: 10 } },
    minHeight: { control: { type: "number", min: 40, step: 10 } },
  },
} satisfies Meta<typeof ResizeContainer>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Playground: Story = {
  name: "Playground",
  args: {
    defaultMode: "pixel",
    minWidth: 80,
    minHeight: 60,
  },
};

export const Relative: Story = {
  name: "Relative mode",
  args: {
    mode: "relative",
    defaultRect: { x: 80, y: 80, width: 480, height: 320 },
  },
};
