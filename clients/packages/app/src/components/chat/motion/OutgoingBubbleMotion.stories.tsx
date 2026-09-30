import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../../styles.css";
import { OutgoingBubbleMotionPlayground } from "./OutgoingBubbleMotionPlayground";

const meta = {
  title: "App components/Chat/Message send motion",
  component: OutgoingBubbleMotionPlayground,
  parameters: { layout: "fullscreen", controls: { disable: true } },
} satisfies Meta<typeof OutgoingBubbleMotionPlayground>;

export default meta;
type Story = StoryObj<typeof meta>;

export const SpringPlayground: Story = {};
