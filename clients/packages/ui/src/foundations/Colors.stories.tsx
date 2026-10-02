import type { Meta, StoryObj } from "@storybook/react-vite";
import { palettes } from "../tokens";

const paletteRows = [
  ["brand", palettes.brand],
  ["error", palettes.error],
  ["warning", palettes.warning],
  ["success", palettes.success],
  ["gray", palettes.grayLightMode],
] as const;

const meta = {
  title: "Foundations/Colors",
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Overview: Story = {
  render: () => (
    <div className="grid w-full max-w-[960px] gap-6 p-4 @min-[640px]/comma-window:p-8">
      {paletteRows.map(([name, colors]) => (
        <section key={name} className="grid gap-3">
          <h2 className="text-md font-semibold text-primary">{name}</h2>
          <div className="grid grid-cols-12 overflow-hidden rounded-lg border border-primary">
            {Object.entries(colors).map(([step, value]) => (
              <div
                key={step}
                className="grid gap-2 bg-primary p-2 text-xs text-secondary"
              >
                <div className="h-12 rounded-md" style={{ backgroundColor: value }} />
                <span>{step}</span>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  ),
};

export const TailwindUtilities: Story = {
  render: () => (
    <div className="grid w-full max-w-[520px] gap-4 p-4 text-sm text-secondary @min-[640px]/comma-window:p-8">
      <p>
        <code className="rounded bg-secondary px-1.5 py-0.5 text-primary">
          bg-brand-600
        </code>{" "}
        primitive palette step
      </p>
      <p>
        <code className="rounded bg-secondary px-1.5 py-0.5 text-primary">
          text-primary
        </code>{" "}
        semantic text token
      </p>
      <p>
        <code className="rounded bg-secondary px-1.5 py-0.5 text-primary">
          bg-secondary
        </code>{" "}
        semantic background token
      </p>
      <div className="h-12 rounded-md bg-brand-600 shadow-xs" />
    </div>
  ),
};
