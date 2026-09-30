import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { expect, fireEvent, userEvent, within } from "storybook/test";
import { Toggle } from "../index";

const ControlledCommitExample = () => {
  const [selected, setSelected] = useState(true);
  const [pendingSelection, setPendingSelection] = useState<boolean | null>(null);

  return (
    <div className="flex flex-col gap-4">
      <Toggle
        aria-label="Delayed controlled toggle"
        checked={selected}
        onChange={(event) => setPendingSelection(event.target.checked)}
        size="md"
        slim
      />
      <button
        disabled={pendingSelection === null}
        onClick={() => {
          if (pendingSelection === null) return;
          setSelected(pendingSelection);
          setPendingSelection(null);
        }}
        type="button"
      >
        Apply pending change
      </button>
      <Toggle
        aria-label="Rejected controlled toggle"
        checked
        onChange={() => undefined}
        size="md"
        slim
      />
    </div>
  );
};

const meta = {
  title: "Base components/Toggles",
  component: Toggle,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Toggle>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <Toggle
      label="Remember me"
      hint="Save my login details for next time."
      defaultChecked
    />
  ),
};

export const Sizes: Story = {
  render: () => (
    <div className="flex flex-col gap-4">
      <Toggle size="sm" label="Small toggle" defaultChecked />
      <Toggle size="md" label="Medium toggle" />
    </div>
  ),
};

export const Disabled: Story = {
  render: () => (
    <Toggle
      label="Disabled toggle"
      hint="Unavailable for your current role."
      disabled
    />
  ),
};

export const ControlledCommit: Story = {
  render: () => <ControlledCommitExample />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const delayed = canvas.getByRole("switch", {
      name: "Delayed controlled toggle",
    });
    const delayedRoot = delayed.closest("label")!;
    const delayedTrack = delayedRoot.querySelector('[data-slot="toggle-base"]');

    await userEvent.hover(delayedRoot);
    await userEvent.click(delayed);

    // The click only reports intent. Until the owner commits it, the knob is
    // still parked on the selected edge.
    await expect(delayed).toBeChecked();
    await expect(delayedTrack).toHaveAttribute("data-selected", "true");
    // Hover is drawn by CSS off the root, so the track carries no hover state.
    await expect(delayedRoot).toHaveAttribute("data-hovered", "true");

    await fireEvent.click(canvas.getByRole("button", { name: "Apply pending change" }));

    // The commit is the only thing that moves it, hover or not.
    await expect(delayed).not.toBeChecked();
    await expect(delayedTrack).toHaveAttribute("data-selected", "false");
    await expect(delayedRoot).toHaveAttribute("data-hovered", "true");

    const rejected = canvas.getByRole("switch", {
      name: "Rejected controlled toggle",
    });
    const rejectedRoot = rejected.closest("label")!;
    const rejectedTrack = rejectedRoot.querySelector('[data-slot="toggle-base"]');

    await userEvent.hover(rejectedRoot);
    await userEvent.click(rejected);

    // A rejected commit never moves the knob.
    await expect(rejected).toBeChecked();
    await expect(rejectedTrack).toHaveAttribute("data-selected", "true");
    await expect(rejectedRoot).toHaveAttribute("data-hovered", "true");
  },
};
