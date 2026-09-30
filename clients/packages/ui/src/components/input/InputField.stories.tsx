import type { Meta, StoryObj } from "@storybook/react-vite";
import { InputField } from "../index";

const meta = {
  title: "Base components/Inputs",
  component: InputField,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof InputField>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <InputField
      label="Email"
      hint="This is a hint text to help user."
      placeholder="olivia@untitledui.com"
      showHelpIcon
    />
  ),
};

export const Destructive: Story = {
  render: () => (
    <InputField
      label="Email"
      destructive
      errorMessage="Please enter a valid email."
      defaultValue="invalid"
    />
  ),
};

export const Disabled: Story = {
  render: () => (
    <InputField label="Email" disabled placeholder="olivia@untitledui.com" />
  ),
};
