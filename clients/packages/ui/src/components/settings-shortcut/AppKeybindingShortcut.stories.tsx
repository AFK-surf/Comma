import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect, useState, type ReactNode } from "react";
import { expect, fireEvent, fn, userEvent, within } from "storybook/test";
import {
  AppKeybindingShortcut,
  type AppKeybindingShortcutProps,
} from "./AppKeybindingShortcut";
import {
  chordKeybinding,
  sequenceKeybinding,
  type AppKeybinding,
} from "./appKeybinding";

const StorySurface = ({ children }: { children: ReactNode }) => (
  <div className="flex justify-end">{children}</div>
);

const StatefulKeybinding = ({
  onChange,
  onClear,
  value: initialValue,
  ...props
}: AppKeybindingShortcutProps) => {
  const [value, setValue] = useState<AppKeybinding | null>(initialValue);

  useEffect(() => setValue(initialValue), [initialValue]);

  return (
    <AppKeybindingShortcut
      {...props}
      value={value}
      onChange={(binding) => {
        onChange?.(binding);
        setValue(binding);
      }}
      onClear={() => {
        onClear?.();
        setValue(null);
      }}
    />
  );
};

const StatefulKeybindingStory = (props: AppKeybindingShortcutProps) => (
  <StorySurface>
    <StatefulKeybinding {...props} />
  </StorySurface>
);

const meta = {
  title: "App components/Settings/Keybinding",
  component: AppKeybindingShortcut,
  render: (args) => <StatefulKeybindingStory {...args} />,
  args: {
    ariaLabel: "Go to Inbox",
    clearLabel: "Clear shortcut",
    emptyLabel: "Not set",
    onChange: fn(),
    onClear: fn(),
    platform: "macos",
    recordingLabel: "Press shortcut",
    value: sequenceKeybinding("KeyG", "KeyI"),
  },
} satisfies Meta<typeof AppKeybindingShortcut>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  play: async ({ args, canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Go to Inbox: G then I",
    });

    await expect(canvas.getByText("G")).toBeVisible();
    await expect(canvas.getByText("I")).toBeVisible();
    await expect(shortcut).toHaveAttribute("data-state", "idle");
    await expect(args.onChange).not.toHaveBeenCalled();
  },
};

export const Chord: Story = {
  args: {
    ariaLabel: "Pin or unpin task",
    value: chordKeybinding("KeyP", { alt: true, meta: true }),
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(
      canvas.getByRole("button", {
        name: "Pin or unpin task: Option + Command + P",
      })
    ).toBeVisible();
    await expect(canvas.getByText("⌥")).toBeVisible();
    await expect(canvas.getByText("⌘")).toBeVisible();
    await expect(canvas.getByText("P")).toBeVisible();
  },
};

export const Editing: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Go to Inbox: G then I",
    });

    await userEvent.click(shortcut);
    await expect(shortcut).toHaveAttribute("data-state", "editing");
    await expect(shortcut).toHaveAccessibleName("Go to Inbox: Press shortcut");
  },
};

export const RecordingSequence: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Go to Inbox: G then I",
    });

    await userEvent.click(shortcut);
    await fireEvent.keyDown(shortcut, {
      code: "KeyG",
      key: "g",
    });
    await fireEvent.keyDown(shortcut, {
      code: "KeyC",
      key: "c",
    });

    await expect(canvas.getByText("G")).toBeVisible();
    await expect(canvas.getByText("C")).toBeVisible();
  },
};

export const RecordingChordCandidate: Story = {
  args: {
    ariaLabel: "Toggle left sidebar",
    value: chordKeybinding("KeyB", { meta: true }),
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const shortcut = canvas.getByRole("button", {
      name: "Toggle left sidebar: Command + B",
    });

    await userEvent.click(shortcut);
    await fireEvent.keyDown(shortcut, {
      code: "MetaLeft",
      key: "Meta",
      metaKey: true,
    });
    await fireEvent.keyDown(shortcut, {
      code: "Comma",
      key: ",",
      metaKey: true,
    });

    await expect(shortcut).toHaveAttribute("data-state", "recording");
    await expect(canvas.getByText("⌘")).toBeVisible();
    await expect(canvas.getByText(",")).toBeVisible();
  },
};

export const GeneralReference: Story = {
  render: () => (
    <div className="flex flex-col gap-7xl">
      <div className="flex min-w-[calc(var(--spacing-10xl)+var(--spacing-7xl))] justify-end">
        <StatefulKeybinding
          ariaLabel="Go to Comma assistant"
          clearLabel="Clear shortcut"
          emptyLabel="Not set"
          platform="macos"
          value={sequenceKeybinding("KeyG", "KeyC")}
        />
      </div>
      <div className="flex min-w-[calc(var(--spacing-10xl)+var(--spacing-7xl))] justify-end">
        <StatefulKeybinding
          ariaLabel="Go to Settings"
          clearLabel="Clear shortcut"
          emptyLabel="Not set"
          platform="macos"
          value={chordKeybinding("Comma", { meta: true })}
        />
      </div>
      <div className="flex min-w-[calc(var(--spacing-10xl)+var(--spacing-7xl))] justify-end">
        <StatefulKeybinding
          ariaLabel="Toggle right sidebar"
          clearLabel="Clear shortcut"
          emptyLabel="Not set"
          platform="macos"
          value={chordKeybinding("KeyB", { alt: true, meta: true })}
        />
      </div>
    </div>
  ),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(
      canvas.getByRole("button", { name: "Go to Comma assistant: G then C" })
    ).toBeVisible();
    await expect(
      canvas.getByRole("button", { name: "Go to Settings: Command + ," })
    ).toBeVisible();
    await expect(
      canvas.getByRole("button", {
        name: "Toggle right sidebar: Option + Command + B",
      })
    ).toBeVisible();
  },
};
