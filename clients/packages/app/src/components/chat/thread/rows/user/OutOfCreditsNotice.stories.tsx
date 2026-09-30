import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../../../../styles.css";
import { OutOfCreditsNotice } from "./OutOfCreditsNotice";

const meta = {
  title: "App components/Chat out of credits",
  component: OutOfCreditsNotice,
  args: {
    onAddCredits: () => {},
    onDiscard: () => {},
    onRetry: () => {},
  },
  decorators: [
    (Story) => (
      <div style={{ width: 560, padding: 24 }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof OutOfCreditsNotice>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};

/** The side chat's width: the action groups wrap instead of truncating. */
export const Narrow: Story = {
  decorators: [
    (Story) => (
      <div style={{ width: 280 }}>
        <Story />
      </div>
    ),
  ],
};
