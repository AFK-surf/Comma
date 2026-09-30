import type { Meta, StoryObj } from "@storybook/react-vite";
import { Checkbox } from "../index";

const meta = {
  title: "Base components/Checkboxes",
  component: Checkbox,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Checkbox>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <Checkbox
      label="Remember me"
      hint="Save my login details for next time."
      defaultChecked
    />
  ),
};

export const Indeterminate: Story = {
  render: () => <Checkbox label="Select all" indeterminate />,
};

export const Disabled: Story = {
  render: () => <Checkbox label="Disabled checkbox" disabled />,
};
