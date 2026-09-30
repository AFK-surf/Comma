import type { Meta, StoryObj } from "@storybook/react-vite";
import { Button, Tooltip } from "../index";

const meta = {
  title: "Base components/Tooltips",
  component: Tooltip,
  args: {
    content: "Tooltip",
    children: <Button hierarchy="secondary-gray">Hover target</Button>,
  },
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof Tooltip>;

export default meta;
type Story = StoryObj<typeof meta>;

export const FigmaReference: Story = {
  render: () => (
    <div className="grid place-items-center p-16">
      <Tooltip
        defaultOpen
        delay={0}
        content="Comma assistant"
        placement="right"
        shortcut={["G", "C"]}
      >
        <Button hierarchy="secondary-gray">Hover target</Button>
      </Tooltip>
    </div>
  ),
};

export const KeyboardShortcut: Story = {
  render: () => (
    <div className="grid place-items-center p-16">
      <Tooltip
        defaultOpen
        delay={0}
        content="Comma assistant"
        placement="bottom"
        shortcut={["G", "C"]}
      >
        <Button hierarchy="tertiary-gray">Shortcut</Button>
      </Tooltip>
    </div>
  ),
};

export const SupportingText: Story = {
  render: () => (
    <div className="grid place-items-center p-16">
      <Tooltip
        defaultOpen
        delay={0}
        content="Create task"
        placement="bottom"
        supportingText="Starts a new task in the current workspace."
      >
        <Button hierarchy="secondary-gray">Details</Button>
      </Tooltip>
    </div>
  ),
};

export const DirectionConventions: Story = {
  parameters: {
    layout: "fullscreen",
  },
  render: () => (
    <div className="grid min-h-[420px] grid-cols-[220px_1fr] bg-main-panel-bg">
      <aside className="flex flex-col gap-md border-r border-primary bg-window p-3xl">
        <p className="mb-md text-xs font-medium text-tertiary">
          Sidebar tooltips open right
        </p>
        {["Search", "Inbox", "Comma assistant"].map((label, index) => (
          <Tooltip
            content={label}
            key={label}
            placement="right"
            {...(index === 2 ? { shortcut: ["G", "C"] } : {})}
          >
            <Button hierarchy="tertiary-gray">{label}</Button>
          </Tooltip>
        ))}
      </aside>
      <main className="flex flex-col items-center gap-3xl p-3xl">
        <p className="text-xs font-medium text-tertiary">
          Toolbar and content tooltips open below
        </p>
        <div className="flex items-center gap-md rounded-lg border border-primary bg-popup-secondary p-md shadow-xs">
          {["Back", "Forward", "Share"].map((label) => (
            <Tooltip content={label} key={label} placement="bottom">
              <Button hierarchy="tertiary-gray">{label}</Button>
            </Tooltip>
          ))}
        </div>
      </main>
    </div>
  ),
};
