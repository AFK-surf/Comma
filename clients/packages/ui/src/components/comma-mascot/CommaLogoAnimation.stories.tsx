import type { Meta, StoryObj } from "@storybook/react-vite";
import { CommaLogoAnimation } from "./CommaLogoAnimation";

const meta = {
  title: "Brand/Comma Logo Animation",
  component: CommaLogoAnimation,
  args: {
    cutout: false,
    easing: "easeInOut",
    intervalSeconds: 1.4,
    nestedDelayPercent: 1,
    paused: false,
    progress: 0,
    size: 32,
    zoomSeconds: 2,
  },
  argTypes: {
    cutout: {
      control: "boolean",
    },
    easing: {
      control: "select",
      options: ["easeInOut", "easeOut", "linear"],
    },
    intervalSeconds: {
      control: { min: 0, max: 3, step: 0.1, type: "range" },
    },
    nestedDelayPercent: {
      control: { min: 0, max: 50, step: 1, type: "range" },
    },
    paused: {
      control: "boolean",
    },
    progress: {
      control: { min: 0, max: 1, step: 0.01, type: "range" },
    },
    size: {
      control: { min: 12, max: 560, step: 2, type: "range" },
    },
    zoomSeconds: {
      control: { min: 0.2, max: 8, step: 0.1, type: "range" },
    },
  },
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "A seamless recursive Comma mark: the 263-unit comma circle scales from (542.5, 534.5) to fill the 730-unit mask while that point moves to (365, 365), and the next comma grows from its lower-right.",
      },
    },
  },
} satisfies Meta<typeof CommaLogoAnimation>;

export default meta;
type Story = StoryObj<typeof meta>;

export const InfiniteLoop: Story = {};

export const ChatThinking: Story = {
  args: { size: 16 },
};

export const FrameInspector: Story = {
  args: {
    paused: true,
  },
};

/**
 * On a coloured surface the aperture is cut out of the mark, so the next
 * comma opens onto the surface instead of a disc of the page's colour.
 */
export const CutoutOnColor: Story = {
  args: { cutout: true, size: 96, style: { color: "inherit" } },
  decorators: [
    (Story) => (
      <div className="rounded-2xl bg-brand-solid p-4xl text-white">
        <Story />
      </div>
    ),
  ],
};
