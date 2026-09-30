import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { Button } from "../Button";
import { Toggle } from "../toggle";
import {
  CommaMascot,
  commaMascotExpressions,
  type CommaMascotExpression,
} from "./index";

const meta = {
  title: "Brand/Comma Mascot",
  component: CommaMascot,
  args: {
    expression: "neutral",
    followPointer: true,
    interactive: true,
    showExpression: true,
    size: 220,
  },
  argTypes: {
    expression: {
      control: "select",
      options: commaMascotExpressions,
    },
    followPointer: {
      control: "boolean",
    },
    showExpression: {
      control: "boolean",
    },
    size: {
      control: { min: 24, max: 320, step: 8, type: "range" },
    },
  },
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "SVG Comma mascot with smoothly morphing eyes, natural neutral-state blinking, and a draggable 6×6 positional-dynamics soft-body mesh. Drag any filled part and release it to feel the spring settle.",
      },
    },
  },
} satisfies Meta<typeof CommaMascot>;

export default meta;
type Story = StoryObj<typeof meta>;

export const ElasticPlayground: Story = {};

const ExpressionPlayground = () => {
  const [expression, setExpression] = useState<CommaMascotExpression>("neutral");
  const [followPointer, setFollowPointer] = useState(true);
  const [showExpression, setShowExpression] = useState(true);
  const [darkMode, setDarkMode] = useState(false);
  return (
    <div
      data-theme={darkMode ? "Dark mode" : "Light mode"}
      className="grid min-w-[44rem] justify-items-center gap-8 rounded-3xl bg-primary p-12 text-primary"
    >
      <CommaMascot
        expression={expression}
        followPointer={followPointer}
        showExpression={showExpression}
        size={240}
      />
      <div className="flex flex-wrap justify-center gap-2">
        {commaMascotExpressions.map((candidate) => (
          <Button
            key={candidate}
            hierarchy={expression === candidate ? "primary" : "secondary-gray"}
            onPress={() => setExpression(candidate)}
            size="sm"
          >
            {candidate}
          </Button>
        ))}
      </div>
      <div className="flex flex-wrap items-center justify-center gap-8">
        <Toggle
          checked={showExpression}
          label="Show expression"
          onChange={(event) => setShowExpression(event.target.checked)}
          size="sm"
          slim
        />
        <Toggle
          checked={followPointer}
          label="Eyes follow pointer"
          onChange={(event) => setFollowPointer(event.target.checked)}
          size="sm"
          slim
        />
        <Toggle
          checked={darkMode}
          label="Dark mode"
          onChange={(event) => setDarkMode(event.target.checked)}
          size="sm"
          slim
        />
      </div>
      <p className="m-0 max-w-80 text-center text-sm text-secondary">
        Drag a filled part for an elastic stretch, then release. The mesh cannot fold
        and always returns to the original mark.
      </p>
    </div>
  );
};

export const Expressions: Story = {
  render: () => <ExpressionPlayground />,
};

export const CompactSizes: Story = {
  render: () => (
    <div className="flex items-end gap-5 rounded-2xl bg-primary p-6">
      {[24, 32, 48, 64].map((size) => (
        <CommaMascot
          key={size}
          interactive={false}
          label={`${size}px Comma mascot`}
          size={size}
        />
      ))}
    </div>
  ),
};

export const Inverse: Story = {
  args: {
    color: "#ffffff",
    eyeColor: "#191a1d",
  },
  render: (args) => (
    <div className="rounded-3xl bg-[#191a1d] p-12">
      <CommaMascot {...args} />
    </div>
  ),
};

export const DarkMode: Story = {
  render: (args) => (
    <div data-theme="Dark mode" className="rounded-3xl bg-primary p-12">
      <CommaMascot {...args} />
    </div>
  ),
};
