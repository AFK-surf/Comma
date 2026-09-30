import type { Meta, StoryObj } from "@storybook/react-vite";
import { Text } from "../components";
import { typeScale } from "../tokens";

const meta = {
  title: "Foundations/Typography",
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Overview: Story = {
  render: () => (
    <div className="grid w-full max-w-[760px] gap-5 p-4 sm:p-8">
      {Object.entries(typeScale).map(([name, style]) => (
        <div
          key={name}
          className="grid grid-cols-1 items-baseline gap-2 border-b border-secondary pb-4 sm:grid-cols-[160px_minmax(0,1fr)] sm:gap-6"
        >
          <span className="text-sm font-medium text-tertiary">{name}</span>
          <p
            className="break-words font-semibold text-primary"
            style={{
              fontSize: style.fontSize,
              lineHeight: `${style.lineHeight}px`,
              letterSpacing: style.letterSpacing,
            }}
          >
            The quick brown fox
          </p>
        </div>
      ))}
    </div>
  ),
};

export const TextComponent: Story = {
  render: () => (
    <div className="grid w-full max-w-[720px] gap-4 p-4 sm:p-8">
      <Text as="h1" size="displayMd" weight="semibold" className="text-primary">
        Design system typography
      </Text>
      <Text size="textLg" className="text-secondary">
        Text uses Comma type tokens through Tailwind v4 theme variables.
      </Text>
      <Text size="textSm" className="text-tertiary">
        Supporting copy stays compact and readable.
      </Text>
    </div>
  ),
};
