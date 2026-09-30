import type { Meta, StoryObj } from "@storybook/react-vite";
import type { ReactNode } from "react";
import { useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { CollapseDebugPanel } from "../../debug";
import { Collapse, CollapseContent } from "../index";
import { ChevronRightSmallIcon, CircleCheckIcon, LoaderIcon } from "../icons";
import { cx } from "../utils";

const CollapseStoryFrame = ({ children }: { children: ReactNode }) => (
  <div className="flex h-screen w-full items-start justify-center overflow-auto p-4xl">
    {children}
  </div>
);

const headerSlotClass =
  "rounded-lg border-2 border-dashed border-red-500 bg-red-500/20 p-lg text-red-800";
const containerSlotClass =
  "rounded-lg border-2 border-dashed border-yellow-500/60 bg-yellow-400/10";
const contentSlotClass = "rounded-lg bg-yellow-400/25 p-lg text-yellow-900";

const meta = {
  title: "Base components/Collapse",
  parameters: {
    layout: "fullscreen",
  },
  decorators: [
    (Story) => (
      <>
        <CollapseDebugPanel />
        <CollapseStoryFrame>
          <Story />
        </CollapseStoryFrame>
      </>
    ),
  ],
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const CollapseVisualization = () => {
  const [open, setOpen] = useState(true);

  return (
    <div className="flex w-[360px] flex-col gap-md">
      <div className={headerSlotClass}>
        <p className="text-sm font-semibold leading-5">自定义 header slot</p>
        <p className="mt-xs text-xs leading-[18px] text-red-700/80">
          由使用方自行渲染，不在 Collapse 组件内。
        </p>
        <button
          type="button"
          className="mt-md rounded-md border border-red-500/40 bg-red-500/10 px-md py-xs text-xs font-medium leading-[18px] text-red-800 outline-none transition-colors hover:bg-red-500/20 focus-visible:shadow-focus-gray"
          aria-expanded={open}
          onClick={() => setOpen((value) => !value)}
        >
          {open ? "收起 content" : "展开 content"}
        </button>
      </div>

      <Collapse open={open} onOpenChange={setOpen}>
        <CollapseContent
          containerClassName={containerSlotClass}
          className={cx(contentSlotClass, "flex flex-col gap-sm")}
        >
          <div>
            <p className="text-sm font-semibold leading-5">content 层（带 padding）</p>
            <p className="mt-xs text-xs leading-[18px] text-yellow-900/80">
              容器只管高度；wrapper 走 opacity，content 走 scale / translate，padding
              加在 content 上。
            </p>
          </div>
          {["Block A", "Block B", "Block C"].map((block) => (
            <div
              key={block}
              className="rounded-md border border-yellow-500/50 bg-yellow-300/30 px-md py-sm text-xs leading-[18px]"
            >
              {block}
            </div>
          ))}
        </CollapseContent>
      </Collapse>
    </div>
  );
};

export const Default: Story = {
  render: () => <CollapseVisualization />,
};

const SidebarRecentTasksSectionDemo = () => {
  const [expanded, setExpanded] = useState(true);

  const recentTasks = [
    { id: "excel", label: "Analyze this Excel file", selected: true },
    { id: "translate", label: "Translate this sentence" },
    { id: "summarize", label: "Summarize recent update", loading: true },
  ];

  return (
    <div className="w-[290px] rounded-xl border-[0.5px] border-primary bg-primary p-md shadow-sm">
      <div className="flex w-full max-w-[270px] items-end overflow-hidden rounded-lg px-md pb-xxs pt-md">
        <AriaButton
          aria-expanded={expanded}
          aria-label={expanded ? "Collapse Recent tasks" : "Expand Recent tasks"}
          className="inline-flex shrink-0 items-center gap-xs rounded-xs text-sidebar-text-tertiary outline-none transition-colors hover:text-sidebar-text-highlight focus-visible:shadow-focus-gray"
          onPress={() => setExpanded((value) => !value)}
        >
          <span className="whitespace-nowrap text-xs font-medium leading-[18px]">
            Recent tasks
          </span>
          <span
            aria-hidden
            className="sidebar-task-section-chevron inline-flex shrink-0"
            data-expanded={expanded}
          >
            <ChevronRightSmallIcon className="size-5 text-sidebar-icon-primary" />
          </span>
        </AriaButton>
      </div>

      <Collapse open={expanded} onOpenChange={setExpanded}>
        <CollapseContent className="flex w-full flex-col gap-xxs">
          {recentTasks.map((item) => (
            <AriaButton
              key={item.id}
              className={cx(
                "flex h-8 w-full max-w-[270px] items-center gap-2 overflow-hidden rounded-lg px-md py-sm text-sm leading-5 tracking-[-0.14px] outline-none transition-colors focus-visible:shadow-focus-gray",
                item.selected
                  ? "bg-sidebar-bg-item text-sidebar-text-highlight"
                  : "text-sidebar-text-secondary hover:bg-sidebar-bg-item hover:text-sidebar-text-highlight"
              )}
            >
              {item.loading ? (
                <LoaderIcon className="size-5 text-sidebar-icon-secondary" />
              ) : (
                <CircleCheckIcon className="size-5 text-fg-success-primary" />
              )}
              <span className="min-w-0 flex-1 truncate text-left">{item.label}</span>
            </AriaButton>
          ))}
        </CollapseContent>
      </Collapse>
    </div>
  );
};

/** LeftSidebar Recent tasks 区块：只展示 header + Collapse 列表，不含完整 sidebar。 */
export const SidebarSection: Story = {
  render: () => <SidebarRecentTasksSectionDemo />,
};
