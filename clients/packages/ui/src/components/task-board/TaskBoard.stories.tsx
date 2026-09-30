import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, fireEvent, waitFor, within } from "storybook/test";
import { ResizeContainer } from "../../dev";
import {
  Badge,
  Button,
  CalendarIcon,
  TaskBoard,
  TaskBoardColumn,
  TaskCard,
  TaskCardMeta,
  TaskCardReorderItem,
  TaskCardReorderList,
  TaskListGroup,
  TaskListItem,
  TaskViewToggle,
  type TaskView,
} from "../index";
import {
  contentTaskIconStates,
  type ContentTaskIconState,
} from "../TaskListItem/taskListItemStoryIcons";

const meta = {
  title: "App components/Tasks/Task Board",
  component: TaskCard,
  args: {
    icon: contentTaskIconStates.backlog.renderIcon(),
    title: "Untitled",
  },
  parameters: {
    layout: "fullscreen",
  },
} satisfies Meta<typeof TaskCard>;

export default meta;
type Story = StoryObj<typeof meta>;

const longTitle = "Summarizing recent OpenAI's update and create a HTML";
const wrappedTitle =
  "Summarizing recent OpenAI's update and create a HTML report covering the key changes, reasoning, and what it means for our upcoming agent release";

const ScheduleBadge = () => (
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

const WorkerMeta = () => (
  <TaskCardMeta textClassName="comma-shiny-text">
    Claude worker is working on assign a source
  </TaskCardMeta>
);

type BoardTask = {
  key: string;
  title: string;
  worker?: boolean;
  schedule?: boolean;
  footer: string;
};

type BoardColumn = {
  state: ContentTaskIconState;
  label: string;
  tasks: BoardTask[];
};

const boardColumns: BoardColumn[] = [
  {
    state: "backlog",
    label: "Backlog",
    tasks: [
      {
        key: "backlog-1",
        title: wrappedTitle,
        schedule: true,
        footer: "Created May 9",
      },
      { key: "backlog-2", title: longTitle, footer: "Created May 9" },
    ],
  },
  {
    state: "in-progress",
    label: "In progress",
    tasks: [
      {
        key: "ip-1",
        title: longTitle,
        worker: true,
        schedule: true,
        footer: "Created May 9",
      },
      {
        key: "ip-2",
        title: longTitle,
        schedule: true,
        footer: "Created May 9",
      },
      {
        key: "ip-3",
        title: longTitle,
        schedule: true,
        footer: "Created May 9",
      },
      { key: "ip-4", title: longTitle, footer: "Created May 9" },
    ],
  },
  {
    state: "review",
    label: "Needs Review",
    tasks: [
      { key: "review-1", title: longTitle, footer: "Created May 9" },
      { key: "review-2", title: longTitle, footer: "Created May 9" },
      { key: "review-3", title: longTitle, footer: "Created May 9" },
      { key: "review-4", title: longTitle, footer: "Created May 9" },
    ],
  },
  {
    state: "done",
    label: "Done",
    tasks: [
      { key: "done-1", title: longTitle, footer: "Create May 9" },
      { key: "done-2", title: longTitle, footer: "Create May 9" },
    ],
  },
  {
    state: "cancel",
    label: "Cancel",
    tasks: [],
  },
];

const renderIcon = (state: ContentTaskIconState) =>
  contentTaskIconStates[state].renderIcon();

const renderBoard = () => (
  <TaskBoard className="size-full" scrollAreaProps={{ edgeEffect: "mask" }}>
    {boardColumns.map((column) => (
      <TaskBoardColumn
        count={column.tasks.length}
        emptyState="No tasks"
        icon={renderIcon(column.state)}
        key={column.state}
        label={column.label}
      >
        {column.tasks.map((task) => (
          <TaskCard
            badges={task.schedule ? <ScheduleBadge /> : undefined}
            footer={task.footer}
            icon={renderIcon(column.state)}
            interactive
            key={task.key}
            meta={task.worker ? <WorkerMeta /> : undefined}
            title={task.title}
          />
        ))}
      </TaskBoardColumn>
    ))}
  </TaskBoard>
);

const renderList = () => (
  <div className="flex size-full flex-col gap-xs overflow-auto rounded-xl bg-primary p-md">
    {boardColumns.map((column) => (
      <TaskListGroup
        accent={
          column.state === "review"
            ? "warning"
            : column.state === "done"
              ? "success"
              : column.state === "cancel"
                ? "error"
                : "neutral"
        }
        count={column.tasks.length}
        defaultOpen={column.state !== "cancel"}
        icon={renderIcon(column.state)}
        key={column.state}
        label={column.label}
      >
        {column.tasks.map((task) => (
          <TaskListItem
            icon={renderIcon(column.state)}
            iconKey={column.state}
            key={task.key}
            layout="content"
            tail={
              task.schedule ? (
                <>
                  <ScheduleBadge />
                  <span className="shrink-0 whitespace-nowrap font-normal text-quaternary">
                    {task.footer}
                  </span>
                </>
              ) : (
                task.footer
              )
            }
            title={task.title}
          />
        ))}
      </TaskListGroup>
    ))}
  </div>
);

export const Card: Story = {
  name: "Card",
  parameters: { layout: "centered" },
  render: () => (
    <div className="flex w-[320px] flex-col gap-lg bg-secondary p-xl">
      <TaskCard
        footer="Created May 9"
        icon={renderIcon("backlog")}
        interactive
        title={longTitle}
      />
      <TaskCard
        badges={<ScheduleBadge />}
        footer="Created May 9"
        icon={renderIcon("in-progress")}
        interactive
        meta={<WorkerMeta />}
        title={longTitle}
      />
      <TaskCard
        footer="Created May 9"
        icon={renderIcon("done")}
        interactive
        selected
        title={longTitle}
      />
    </div>
  ),
};

export const Board: Story = {
  name: "Board",
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const column = canvas
      .getByText("Needs Review", { exact: true })
      .closest<HTMLElement>('[data-slot="task-board-column"]');
    const root = column?.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = column?.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const scrollbar = column?.querySelector<HTMLElement>(
      ".comma-scroll-area__scrollbar--vertical"
    );

    await waitFor(() => expect(root).toHaveAttribute("data-has-overflow-y", "true"));
    viewport!.scrollTop = 40;
    fireEvent.scroll(viewport!);

    await waitFor(() => {
      expect(scrollbar).toHaveAttribute("data-scrolling", "true");
      expect(getComputedStyle(scrollbar!).display).not.toBe("none");
    });
  },
  render: () => (
    <ResizeContainer
      centered
      defaultCenterMode
      defaultMode="relative"
      defaultRect={{ width: 1320, height: 360 }}
      defaultResizable
      minHeight={360}
      minWidth={480}
    >
      <div className="absolute inset-0 bg-primary">{renderBoard()}</div>
    </ResizeContainer>
  ),
};

export const ViewSwitch: Story = {
  name: "View Switch",
  render: () => {
    const [view, setView] = useState<TaskView>("board");

    return (
      <ResizeContainer
        centered
        defaultCenterMode
        defaultMode="relative"
        defaultRect={{ width: 1320, height: 720 }}
        defaultResizable
        minHeight={360}
        minWidth={480}
      >
        <div className="absolute inset-0 flex flex-col bg-primary">
          <div className="flex shrink-0 items-center justify-between p-lg">
            <Badge color="gray" size="sm" type="pill-color">
              All tasks
            </Badge>
            <TaskViewToggle onChange={setView} value={view} />
          </div>
          <div className="min-h-0 flex-1 px-md pb-md">
            {view === "board" ? renderBoard() : renderList()}
          </div>
        </div>
      </ResizeContainer>
    );
  },
};

const reorderTitles = [
  "Summarize the latest product feedback",
  "Prepare the onboarding brief",
  "Review the launch checklist",
  "Publish the weekly customer digest",
  "Archive the superseded research workspace",
];

export const Reorder: Story = {
  name: "Reorder",
  parameters: { layout: "centered" },
  render: () => {
    const [order, setOrder] = useState(reorderTitles);

    return (
      <div className="h-[520px] w-[380px] bg-primary p-md">
        <TaskBoardColumn
          className="h-full"
          count={order.length}
          icon={renderIcon("backlog")}
          label="Backlog"
        >
          <TaskCardReorderList ids={order} onReorder={setOrder}>
            {order.map((title) => (
              <TaskCardReorderItem id={title} key={title}>
                <button
                  aria-label={title}
                  className="group/task-card w-full border-0 bg-transparent p-0 text-left"
                  type="button"
                >
                  <TaskCard
                    footer="Updated May 9"
                    icon={renderIcon("backlog")}
                    interactive
                    title={title}
                  />
                </button>
              </TaskCardReorderItem>
            ))}
          </TaskCardReorderList>
        </TaskBoardColumn>
      </div>
    );
  },
};

const liveReorderTitles = ["Task A", "Task B", "Task C"];

/** Regression surface for a projection update arriving while a card is held. */
export const ReorderLiveUpdate: Story = {
  name: "Reorder — live update",
  parameters: { layout: "centered" },
  render: () => {
    const [order, setOrder] = useState(liveReorderTitles);

    return (
      <div className="flex h-[560px] w-[380px] flex-col gap-md bg-primary p-md">
        <Button
          className="self-start"
          hierarchy="secondary-gray"
          onPress={() =>
            setOrder((current) =>
              current.includes("New live task")
                ? current
                : ["New live task", ...current]
            )
          }
          size="sm"
        >
          Insert live task
        </Button>
        <TaskBoardColumn
          className="min-h-0 flex-1"
          count={order.length}
          icon={renderIcon("backlog")}
          label="Backlog"
        >
          <TaskCardReorderList ids={order} onReorder={setOrder}>
            {order.map((title) => (
              <TaskCardReorderItem id={title} key={title}>
                <button
                  aria-label={title}
                  className="group/task-card w-full border-0 bg-transparent p-0 text-left"
                  type="button"
                >
                  <TaskCard
                    footer="Updated May 9"
                    icon={renderIcon("backlog")}
                    interactive
                    title={title}
                  />
                </button>
              </TaskCardReorderItem>
            ))}
          </TaskCardReorderList>
        </TaskBoardColumn>
      </div>
    );
  },
};
