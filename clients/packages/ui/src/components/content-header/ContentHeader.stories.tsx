import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { ContentHeader } from "./ContentHeader";
import { PanelLeftIcon } from "../icons";

const meta = {
  title: "App components/Content Header",
  component: ContentHeader,
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof ContentHeader>;

export default meta;
type Story = StoryObj<typeof meta>;

const WindowPreview = () => {
  const [collapsed, setCollapsed] = useState(false);

  return (
    <div className="relative h-72 w-[720px] overflow-hidden rounded-2xl border-[0.5px] border-primary bg-window p-md shadow-sm">
      <div className="absolute left-5 top-6 z-10 flex gap-sm" aria-hidden>
        <span className="size-3 rounded-full bg-[#ff5f57]" />
        <span className="size-3 rounded-full bg-[#febc2e]" />
        <span className="size-3 rounded-full bg-[#28c840]" />
      </div>
      <button
        aria-label="Toggle sidebar"
        className="absolute left-[104px] top-4 z-10 inline-flex size-7 items-center justify-center rounded-sm text-secondary hover:bg-secondary"
        onClick={() => setCollapsed((current) => !current)}
        type="button"
      >
        <PanelLeftIcon className="size-5" />
      </button>
      <div
        className="ml-auto h-full overflow-hidden rounded-xl bg-primary transition-[width] duration-150 ease-[cubic-bezier(0.22,1,0.36,1)]"
        style={{ width: collapsed ? "100%" : "calc(100% - 282px)" }}
      >
        <ContentHeader>
          <h1 className="m-0 truncate text-sm font-medium text-primary">Inbox</h1>
        </ContentHeader>
      </div>
    </div>
  );
};

export const Default: Story = {
  args: {
    children: <h1 className="m-0 truncate text-sm font-medium text-primary">Tasks</h1>,
  },
  decorators: [
    (Story) => (
      <div className="w-[560px] overflow-hidden rounded-xl border-[0.5px] border-primary bg-primary">
        <Story />
        <div className="h-40" />
      </div>
    ),
  ],
};

export const WindowControlsInset: Story = {
  args: {
    children: null,
  },
  render: () => <WindowPreview />,
};
