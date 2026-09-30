import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect, useState, type ReactNode } from "react";
import { expect, fireEvent, fn, userEvent, within } from "storybook/test";
import { SettingsShortcut, type SettingsShortcutProps } from "./SettingsShortcut";

const StorySurface = ({ children }: { children: ReactNode }) => (
  <div className="flex justify-end">{children}</div>
);

const StatefulShortcut = ({
  onChange,
  onClear,
  value: initialValue,
  ...props
}: SettingsShortcutProps) => {
  const [value, setValue] = useState(initialValue);

  useEffect(() => setValue(initialValue), [initialValue]);

  return (
    <SettingsShortcut
      {...props}
      value={value}
      onChange={(shortcut) => {
        const result = onChange?.(shortcut);
        setValue(shortcut);
        return result;
      }}
      onClear={() => {
        const result = onClear?.();
        setValue(null);
        return result;
      }}
    />
  );
};

const StatefulShortcutStory = (props: SettingsShortcutProps) => (
  <StorySurface>
    <StatefulShortcut {...props} />
  </StorySurface>
);

const meta = {
  title: "App components/Settings/Shortcut",
  component: SettingsShortcut,
  render: (args) => <StatefulShortcutStory {...args} />,
  args: {
    ariaLabel: "Open Side Chat",
    clearLabel: "Clear shortcut",
    emptyLabel: "Not set",
    onChange: fn(),
    onClear: fn(),
    recordingLabel: "Press shortcut",
    value: {
      key: "z",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    },
  },
} satisfies Meta<typeof SettingsShortcut>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  play: async ({ args, canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });

    await expect(canvas.getByText("⌃")).toBeVisible();
    await expect(canvas.getByText("Z")).toBeVisible();
    await expect(shortcut).toHaveAttribute("data-state", "idle");
    await expect(args.onChange).not.toHaveBeenCalled();
  },
};

export const Editing: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });

    await userEvent.click(shortcut);
    await expect(shortcut).toHaveAttribute("data-state", "editing");
    await expect(shortcut).toHaveAccessibleName("Open Side Chat: Press shortcut");
  },
};

export const DarkEditing: Story = {
  globals: {
    theme: "dark",
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });

    await userEvent.click(shortcut);
    await expect(shortcut).toHaveAttribute("data-state", "editing");
    await expect(shortcut).toHaveAccessibleName("Open Side Chat: Press shortcut");
  },
};

export const RecordingCandidate: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });

    await userEvent.click(shortcut);
    await fireEvent.keyDown(shortcut, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });
    await fireEvent.keyDown(shortcut, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    await expect(shortcut).toHaveAttribute("data-state", "recording");
    await expect(canvas.getByText("⌃")).toBeVisible();
    await expect(canvas.getByText("K")).toBeVisible();
  },
};

export const PendingRegistration: Story = {
  args: {
    onChange: fn(() => new Promise<void>(() => undefined)),
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });

    await userEvent.click(shortcut);
    await fireEvent.keyDown(shortcut, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    await fireEvent.keyUp(shortcut, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    await expect(shortcut).toHaveAccessibleName("Open Side Chat: Ctrl + K");
    await expect(shortcut).toHaveAttribute("aria-busy", "true");
    await expect(shortcut).toHaveAttribute("aria-disabled", "true");
    await expect(shortcut).toHaveFocus();
  },
};

export const RegistrationError: Story = {
  args: {
    errorMessage: "Couldn’t register this shortcut. The previous shortcut is active.",
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByRole("alert")).toBeVisible();
    await expect(
      canvas.getByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toHaveAttribute("data-state", "error");
  },
};

export const CommaboardReference: Story = {
  render: () => (
    <div className="flex flex-col gap-7xl">
      <div className="flex min-w-[calc(var(--spacing-10xl)+var(--spacing-7xl))] justify-end">
        <StatefulShortcut
          ariaLabel="Reference shortcut"
          clearLabel="Clear shortcut"
          emptyLabel="Not set"
          onClear={() => undefined}
          value={{
            key: "e",
            modifiers: {
              alt: true,
              control: false,
              meta: false,
              shift: false,
            },
          }}
        />
      </div>
      <div className="flex min-w-[calc(var(--spacing-10xl)+var(--spacing-7xl))] justify-end">
        <StatefulShortcut
          ariaLabel="Voice input"
          clearLabel="Clear shortcut"
          emptyLabel="Not set"
          onClear={() => undefined}
          value={{
            key: "m",
            modifiers: {
              alt: false,
              control: true,
              meta: false,
              shift: false,
            },
          }}
        />
      </div>
    </div>
  ),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(
      canvas.getByRole("button", { name: "Reference shortcut: Alt + E" })
    ).toBeVisible();
    await expect(
      canvas.getByRole("button", { name: "Voice input: Ctrl + M" })
    ).toBeVisible();
  },
};
