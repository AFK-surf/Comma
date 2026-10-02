import type { Meta, StoryObj } from "@storybook/react-vite";
import { radius, spacing } from "../tokens";

const REDLINE = "#ff3030";

const MeasurementCard = ({ size }: { size: "sm" | "lg" }) => (
  <div
    aria-hidden="true"
    className={[
      "relative z-0 aspect-square min-w-0 flex-1 shrink border-[0.5px] bg-white",
      size === "lg" ? "max-w-[300px]" : "max-w-[180px]",
    ].join(" ")}
    style={{ borderColor: REDLINE }}
  >
    <div
      className={[
        "absolute inset-0 border-2 border-[#dedede] bg-white",
        size === "lg" ? "rounded-[48px]" : "rounded-[28px]",
      ].join(" ")}
    />
  </div>
);

const MeasurementGap = ({ value }: { value: number }) => (
  <div
    className="relative z-20 h-full shrink-0 overflow-visible"
    style={{ width: value }}
  >
    <span className="sr-only">{value}px spacing</span>
    <span
      aria-hidden="true"
      className="absolute left-0 right-0 top-1/2 h-px -translate-y-1/2"
      style={{ backgroundColor: REDLINE }}
    />
    <span
      aria-hidden="true"
      data-measurement-badge
      className="absolute left-1/2 top-[calc(50%+7px)] z-30 inline-flex h-4 min-w-[18px] -translate-x-1/2 items-center justify-center rounded px-1 text-center whitespace-nowrap text-white"
      style={{
        backgroundColor: REDLINE,
        fontSize: 10,
        fontWeight: 600,
        lineHeight: "12px",
      }}
    >
      {value}
    </span>
  </div>
);

const SpacingMeasurement = ({ name, value }: { name: string; value: number }) => (
  <div className="grid min-w-0 grid-cols-1 gap-3 @min-[640px]/comma-window:grid-cols-[72px_minmax(0,1fr)] @min-[640px]/comma-window:items-center @min-[640px]/comma-window:gap-6">
    <div className="grid gap-1 @min-[640px]/comma-window:text-right">
      <span className="text-sm font-semibold text-primary">{name}</span>
      <span className="text-xs text-tertiary">{value}px</span>
    </div>
    <div className="flex min-w-0 items-center justify-center overflow-visible">
      <MeasurementCard size="sm" />
      <MeasurementGap value={value} />
      <MeasurementCard size="sm" />
    </div>
  </div>
);

const LargeSpacingMeasurement = ({ value }: { value: number }) => (
  <div className="flex min-h-[520px] items-center justify-center overflow-hidden bg-white p-6 @min-[640px]/comma-window:p-12">
    <div className="flex w-full max-w-[640px] min-w-0 items-center justify-center overflow-visible">
      <MeasurementCard size="lg" />
      <MeasurementGap value={value} />
      <MeasurementCard size="lg" />
    </div>
  </div>
);

const meta = {
  title: "Foundations/Spacing",
  parameters: {
    a11y: {
      context: {
        exclude: ["[data-measurement-badge]"],
      },
      test: "error",
    },
    layout: "fullscreen",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const SpacingScale: Story = {
  render: () => <LargeSpacingMeasurement value={spacing["5xl"]} />,
};

export const AllTokens: Story = {
  render: () => (
    <div className="grid w-full max-w-[760px] gap-8 bg-white p-6 @min-[640px]/comma-window:p-12">
      {Object.entries(spacing).map(([name, value]) => (
        <SpacingMeasurement key={name} name={name} value={value} />
      ))}
    </div>
  ),
};

export const Radius: Story = {
  render: () => (
    <div className="flex w-full max-w-[720px] flex-wrap gap-4 p-4 @min-[640px]/comma-window:p-8">
      {Object.entries(radius).map(([name, value]) => (
        <div key={name} className="grid gap-2 text-center text-xs text-tertiary">
          <div
            className="size-14 border border-brand-300 bg-brand-50"
            style={{ borderRadius: value }}
          />
          <span>{name}</span>
        </div>
      ))}
    </div>
  ),
};
