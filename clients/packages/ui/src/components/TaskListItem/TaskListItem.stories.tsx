import { useCallback, useState, type ReactNode } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, fn, userEvent, waitFor, within } from "storybook/test";
import {
  defaultTaskListItemPlaygroundParams,
  TaskListItemPlaygroundPanel,
  type TaskListItemPlaygroundParams,
} from "../../debug";
import { ResizeContainer } from "../../dev";
import {
  Badge,
  CalendarIcon,
  ChainLinkIcon,
  EditBigIcon,
  MenuItem,
  MenuSeparator,
  PinIcon,
  TaskListGroup,
  TaskListItem,
  type TaskListItemContextMenuProps,
  type TaskListItemProps,
  TrashCanIcon,
} from "../index";
import {
  contentTaskIconStates,
  type ContentTaskIconState,
  resolveTaskListItemStoryIcon,
  sidebarRunIconStates,
} from "./taskListItemStoryIcons";

const meta = {
  title: "App components/Tasks/Task List Item",
  component: TaskListItem,
  args: {
    icon: contentTaskIconStates.backlog.renderIcon(),
    title: "Untitled",
    layout: "content",
  },
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof TaskListItem>;

export default meta;
type Story = StoryObj<typeof meta>;

const longTitle = "Summarizing recent OpenAI's update and create a HTML";
const onTaskMenuAction = fn();

const TaskListContextMenuItems = () => (
  <>
    <MenuItem icon={<PinIcon />} id="pin">
      Pin task
    </MenuItem>
    <MenuItem icon={<EditBigIcon />} id="rename">
      Rename
    </MenuItem>
    <MenuItem icon={<ChainLinkIcon />} id="copy-link">
      Copy link
    </MenuItem>
    <MenuSeparator />
    <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
      Delete task
    </MenuItem>
  </>
);

type TaskListItemWithActionsProps = Omit<TaskListItemProps, "contextMenu" | "title"> & {
  title: string;
};

const TaskListItemWithActions = ({ title, ...props }: TaskListItemWithActionsProps) => {
  const contextMenu = {
    "aria-label": `Actions for ${title}`,
    onAction: onTaskMenuAction,
    children: <TaskListContextMenuItems />,
  } satisfies TaskListItemContextMenuProps;

  return <TaskListItem {...props} contextMenu={contextMenu} title={title} />;
};

const ScheduleTag = () => (
  <Badge
    className="gap-xs py-xxs pr-md pl-sm text-xs text-quaternary"
    color="gray"
    size="sm"
    type="pill-outline"
  >
    <CalendarIcon className="size-3 shrink-0 text-quaternary" />
    Schedules
  </Badge>
);

const SectionLabel = ({ children }: { children: ReactNode }) => (
  <p className="px-md text-left text-sm font-medium leading-5 tracking-[-0.14px] text-quaternary">
    {children}
  </p>
);

const sidebarItems = [
  {
    key: "today-success",
    iconState: "success" as const,
    title: longTitle,
    tail: "30m",
    dot: true,
    selected: true,
  },
  {
    key: "today-attention",
    iconState: "attention" as const,
    title: longTitle,
    tail: "6h",
    dot: true,
    selected: false,
  },
  {
    key: "yesterday-attention",
    iconState: "attention" as const,
    title: longTitle,
    tail: "6h",
    dot: false,
    selected: false,
  },
  {
    key: "yesterday-attention-2",
    iconState: "attention" as const,
    title: longTitle,
    tail: "6h",
    dot: false,
    selected: false,
  },
  {
    key: "yesterday-failed",
    iconState: "failed" as const,
    title: longTitle,
    tail: "6h",
    dot: false,
    selected: false,
  },
] as const;

type GroupAccent = "neutral" | "warning" | "success" | "error";

type ContentRow = {
  key: string;
  title: string;
  schedule: boolean;
};

type ContentGroup = {
  state: ContentTaskIconState;
  label: string;
  accent: GroupAccent;
  defaultOpen: boolean;
  rows: ContentRow[];
};

const contentGroups: ContentGroup[] = [
  {
    state: "backlog",
    label: "Backlog",
    accent: "neutral",
    defaultOpen: true,
    rows: [
      { key: "backlog-1", title: "Untitled", schedule: false },
      { key: "backlog-2", title: longTitle, schedule: false },
    ],
  },
  {
    state: "in-progress",
    label: "In progress",
    accent: "neutral",
    defaultOpen: true,
    rows: [
      { key: "in-progress-1", title: longTitle, schedule: true },
      { key: "in-progress-2", title: longTitle, schedule: true },
    ],
  },
  {
    state: "review",
    label: "Needs Review",
    accent: "warning",
    defaultOpen: true,
    rows: [
      { key: "review-1", title: longTitle, schedule: true },
      { key: "review-2", title: longTitle, schedule: true },
      { key: "review-3", title: longTitle, schedule: true },
      { key: "review-4", title: longTitle, schedule: true },
    ],
  },
  {
    state: "done",
    label: "Done",
    accent: "success",
    defaultOpen: true,
    rows: [
      { key: "done-1", title: longTitle, schedule: true },
      { key: "done-2", title: longTitle, schedule: true },
    ],
  },
  {
    state: "cancel",
    label: "Cancel",
    accent: "error",
    defaultOpen: false,
    rows: [],
  },
];

const renderContentTail = (date: string, schedule: boolean) =>
  schedule ? (
    <>
      <ScheduleTag />
      <span className="shrink-0 whitespace-nowrap font-normal text-quaternary">
        {date}
      </span>
    </>
  ) : (
    date
  );

type TailMode = "none" | "sidebar-time" | "content-date" | "content-with-tag";

const renderTail = (mode: TailMode) => {
  switch (mode) {
    case "none":
      return undefined;
    case "sidebar-time":
      return "30m";
    case "content-date":
      return "Create May 9";
    case "content-with-tag":
      return renderContentTail("Create May 9", true);
  }
};

export const Playground: Story = {
  name: "Playground",
  parameters: {
    controls: { disable: true },
    layout: "fullscreen",
  },
  render: () => {
    const [params, setParams] = useState(defaultTaskListItemPlaygroundParams);
    const handleParamsChange = useCallback((next: TaskListItemPlaygroundParams) => {
      setParams(next);
    }, []);

    const iconState = resolveTaskListItemStoryIcon(
      params.layout,
      params.contentIconState,
      params.sidebarIconState
    );
    const tail = renderTail(params.tailMode);
    const iconKey =
      params.layout === "sidebar" ? params.sidebarIconState : params.contentIconState;

    return (
      <>
        <TaskListItemPlaygroundPanel onChange={handleParamsChange} />
        <ResizeContainer
          centered
          defaultCenterMode
          defaultMode="relative"
          defaultRect={{ width: 720, height: 96 }}
          defaultResizable
          minHeight={44}
        >
          <div className="flex w-full flex-col rounded-xl bg-primary p-lg">
            <TaskListItemWithActions
              dot={params.dot}
              icon={iconState.icon}
              iconKey={iconKey}
              layout={params.layout}
              selected={params.selected}
              tail={tail}
              title={longTitle}
            />
          </div>
        </ResizeContainer>
      </>
    );
  },
};

export const KeyboardContextMenuInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  render: () => (
    <div className="w-[560px] rounded-xl bg-primary p-lg">
      <TaskListItemWithActions
        aria-label="Keyboard task row"
        icon={contentTaskIconStates.backlog.renderIcon()}
        iconKey="backlog"
        title="Keyboard context menu task"
      />
    </div>
  ),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const row = canvas.getByLabelText("Keyboard task row");

    await userEvent.tab();
    expect(row).toHaveFocus();

    await userEvent.keyboard("{Shift>}{F10}{/Shift}");
    expect(await page.findByRole("menuitem", { name: "Pin task" })).toHaveFocus();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());

    expect(row).toHaveFocus();
    expect(row).toHaveAttribute("data-context-menu-open", "false");
  },
};

export const Sidebar: Story = {
  name: "Sidebar",
  parameters: {
    layout: "fullscreen",
  },
  render: () => (
    <ResizeContainer
      centered
      defaultCenterMode
      defaultMode="relative"
      defaultRect={{ width: 320, height: 440 }}
      defaultResizable
      minWidth={220}
    >
      <div className="flex size-full flex-col gap-lg rounded-xl bg-primary p-md">
        <div className="flex flex-col gap-md">
          <SectionLabel>Today</SectionLabel>
          <div className="flex flex-col gap-xxs">
            {sidebarItems.slice(0, 2).map((item) => (
              <TaskListItemWithActions
                dot={item.dot}
                icon={sidebarRunIconStates[item.iconState].renderIcon()}
                iconKey={item.iconState}
                key={item.key}
                layout="sidebar"
                selected={item.selected}
                tail={item.tail}
                title={item.title}
              />
            ))}
          </div>
        </div>
        <div className="flex flex-col gap-md">
          <SectionLabel>Yesterday</SectionLabel>
          <div className="flex flex-col gap-xxs">
            {sidebarItems.slice(2).map((item) => (
              <TaskListItemWithActions
                dot={item.dot}
                icon={sidebarRunIconStates[item.iconState].renderIcon()}
                iconKey={item.iconState}
                key={item.key}
                layout="sidebar"
                tail={item.tail}
                title={item.title}
              />
            ))}
          </div>
        </div>
      </div>
    </ResizeContainer>
  ),
};

const renderGroupIcon = (state: ContentTaskIconState) =>
  contentTaskIconStates[state].renderIcon();

export const Content: Story = {
  name: "Content",
  parameters: {
    layout: "fullscreen",
  },
  render: () => (
    <ResizeContainer
      centered
      defaultCenterMode
      defaultMode="relative"
      defaultRect={{ width: 720, height: 520 }}
      defaultResizable
      minWidth={360}
    >
      <div className="flex size-full flex-col gap-xs overflow-auto rounded-xl bg-primary p-md">
        {contentGroups.map((group) => (
          <TaskListGroup
            accent={group.accent}
            count={group.rows.length}
            defaultOpen={group.defaultOpen}
            icon={renderGroupIcon(group.state)}
            key={group.state}
            label={group.label}
          >
            {group.rows.map((row) => (
              <TaskListItemWithActions
                icon={renderGroupIcon(group.state)}
                iconKey={group.state}
                key={row.key}
                layout="content"
                tail={renderContentTail("Create May 9", row.schedule)}
                title={row.title}
              />
            ))}
          </TaskListGroup>
        ))}
      </div>
    </ResizeContainer>
  ),
};
