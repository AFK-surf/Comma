import type { Meta, StoryObj } from "@storybook/react-vite";
import { CheckboxGroup } from "../index";

const meta = {
  title: "Base components/Checkbox groups",
  parameters: {
    layout: "centered",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <CheckboxGroup
      legend="Notifications"
      hint="Choose what you want to be notified about."
      options={[
        { id: "email", label: "Email", hint: "Get emails about activity." },
        { id: "sms", label: "Phone", hint: "Get texts about activity." },
      ]}
      defaultValue={["email"]}
    />
  ),
};

export const WithDisabledOption: Story = {
  render: () => (
    <CheckboxGroup
      legend="Notification channels"
      defaultValue={["email"]}
      options={[
        { id: "email", label: "Email", hint: "Send product and account updates." },
        {
          id: "desktop",
          label: "Desktop",
          hint: "Show operating system notifications.",
        },
        { id: "sms", label: "SMS", disabled: true },
      ]}
    />
  ),
};
