import type { Meta, StoryObj } from "@storybook/react-vite";
import { backdropBlur, focusRing, shadow } from "../tokens";

const focusRingVar = (name: string) => {
  const kebab = name
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .replace(/([a-zA-Z])(\d)/g, "$1-$2")
    .toLowerCase();
  return `var(--shadow-focus-${kebab})`;
};

const meta = {
  title: "Foundations/Effect styles",
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Shadows: Story = {
  render: () => (
    <div className="flex w-full max-w-[840px] flex-wrap gap-6 p-4 @min-[640px]/comma-window:p-8">
      {Object.keys(shadow).map((name) => (
        <div
          key={name}
          className="grid size-32 place-items-center rounded-xl border border-secondary bg-primary text-sm text-secondary"
          style={{ boxShadow: `var(--shadow-${name})` }}
        >
          shadow-{name}
        </div>
      ))}
    </div>
  ),
};

export const FocusRings: Story = {
  render: () => (
    <div className="flex flex-wrap gap-5 p-8">
      {Object.keys(focusRing).map((name) => (
        <button
          key={name}
          type="button"
          className="rounded-md border border-primary bg-primary px-4 py-2 text-sm font-semibold text-primary"
          style={{ boxShadow: focusRingVar(name) }}
        >
          {name}
        </button>
      ))}
    </div>
  ),
};

export const BackdropBlur: Story = {
  render: () => (
    <div className="grid w-full max-w-[640px] gap-4 p-4 @min-[640px]/comma-window:p-8">
      {Object.entries(backdropBlur).map(([name, value]) => (
        <div
          key={name}
          className="rounded-lg border border-primary bg-secondary p-5 text-sm text-primary"
        >
          backdrop-blur-{name}: {value}px
        </div>
      ))}
    </div>
  ),
};
