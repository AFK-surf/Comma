import userEvent from "@testing-library/user-event";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { Toaster, toast } from "../../toast";
import { describe, expect, it, vi } from "vitest";
import { motionDuration } from "../../../tokens";
import {
  CircleDashedIcon,
  ExclamationTriangleIcon,
  SettingsSliderHorizontalIcon,
  SquareCursorIcon,
} from "../../icons";
import { TaskWorkspace, type TaskWorkspaceTask } from "../TaskWorkspace";

// Icons render in raw mode (paths only, no <mask id>), so glyph identity is
// asserted by comparing against a reference render of the icon component.
function iconSvgMarkup(icon: React.ReactElement) {
  const { container, unmount } = render(icon);
  const markup = container.querySelector("svg")?.innerHTML;
  unmount();
  return markup;
}

function containsIconGlyph(root: Element | null | undefined, icon: React.ReactElement) {
  const reference = iconSvgMarkup(icon);
  return [...(root?.querySelectorAll("svg[data-comma-icon]") ?? [])].some(
    (svg) => svg.innerHTML === reference
  );
}

describe("TaskWorkspace", () => {
  it("announces loading without rendering task columns", () => {
    const { container } = render(<TaskWorkspace loading tasks={[]} />);
    expect(screen.getByRole("status")).toHaveAccessibleName("Loading task");
    expect(container.querySelector('[data-slot="task-workspace"]')).toHaveAttribute(
      "aria-busy",
      "true"
    );
    expect(container.querySelector('[data-slot="task-board-column"]')).toBeNull();
  });

  it("centers the generic error state and delegates retry through the secondary button", async () => {
    const onRetry = vi.fn();
    const { container } = render(
      <TaskWorkspace
        loadError="private transport detail"
        onRetry={onRetry}
        tasks={[]}
      />
    );

    const state = container.querySelector('[data-slot="task-workspace-error-state"]');
    const retryButton = screen.getByRole("button", { name: "Try again" });

    expect(state).toHaveClass(
      "flex",
      "size-full",
      "items-center",
      "justify-center",
      "p-xl"
    );
    expect(screen.getByRole("alert")).toBe(state);
    expect(screen.getByRole("heading", { name: "Error" })).toBeInTheDocument();
    expect(
      screen.getByText("Task could not be refreshed. Try again in a moment.")
    ).toHaveClass("text-balance");
    expect(screen.queryByText("private transport detail")).toBeNull();
    expect(containsIconGlyph(state, <ExclamationTriangleIcon />)).toBe(true);
    expect(retryButton).toHaveClass(
      "bg-button-secondary-bg",
      "text-button-secondary-fg",
      "border-button-secondary-border"
    );

    await userEvent.click(retryButton);

    expect(onRetry).toHaveBeenCalledOnce();
  });

  it("renders a truthful error without a retry action when recovery is unavailable", () => {
    render(<TaskWorkspace loadError="private transport detail" tasks={[]} />);

    expect(screen.getByRole("alert")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Error" })).toBeInTheDocument();
    expect(screen.getByText("Task list unavailable")).toHaveClass("text-balance");
    expect(
      screen.queryByText("Task could not be refreshed. Try again in a moment.")
    ).toBeNull();
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
    expect(screen.queryByText("private transport detail")).toBeNull();
  });

  it("keeps refresh errors as a toast when task content is still available", async () => {
    const { container, unmount } = render(
      <>
        <Toaster />
        <TaskWorkspace loadError="Refresh failed" tasks={[taskFixture()]} />
      </>
    );

    expect(await screen.findByTestId("tasks-sync-error")).toHaveTextContent(
      "Refresh failed"
    );
    expect(screen.getByText("Review task UI")).toBeInTheDocument();
    expect(
      container.querySelector('[data-slot="task-workspace-error-state"]')
    ).toBeNull();
    unmount();
    toast.dismissAll();
  });

  it("renders the designed empty state without status sections", async () => {
    const onChatWithComma = vi.fn();
    const onCreateTask = vi.fn();
    const { container } = render(
      <>
        <Toaster />
        <TaskWorkspace
          capabilityState="planned"
          onChatWithComma={onChatWithComma}
          onCreateTask={onCreateTask}
        />
      </>
    );

    expect(screen.queryByRole("heading", { name: "Tasks" })).toBeNull();
    expect(screen.getByText("All tasks")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "List view" })).toBeInTheDocument();
    const toolbarActions = container.querySelector(
      '[data-slot="task-workspace-toolbar-actions"]'
    );
    expect(toolbarActions).toHaveClass("gap-md");
    expect(toolbarActions).not.toHaveClass("gap-xl");
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveClass(
      "shadow-xs"
    );
    expect(screen.getByRole("button", { name: "List view" })).toHaveClass("shadow-xs");
    expect(container.querySelector('[data-slot="task-workspace"]')).toHaveClass(
      "h-full"
    );
    expect(container.querySelector('[data-slot="task-board-column"]')).toBeNull();
    expect(
      screen.getByText(
        "You can create tasks directly through the worker or use the Comma assistant to intelligently create and assign tasks."
      )
    ).toBeInTheDocument();
    expect(await screen.findByTestId("tasks-not-connected")).toHaveTextContent(
      "Task data is not connected yet. The board UI is ready."
    );

    await userEvent.click(screen.getByRole("button", { name: "Create new task" }));
    await userEvent.click(screen.getByRole("button", { name: "Chat with Comma" }));

    expect(onCreateTask).toHaveBeenCalledOnce();
    expect(onChatWithComma).toHaveBeenCalledOnce();
  });

  it("omits empty-state actions that do not have a real callback", () => {
    render(<TaskWorkspace tasks={[]} />);

    expect(screen.getByText("No tasks")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Create new task" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Chat with Comma" })).toBeNull();
  });

  it("opens the view panel and switches to the complete status list", async () => {
    const user = userEvent.setup();
    const { container } = render(<TaskWorkspace tasks={[taskFixture()]} />);

    // Only the status the task is actually in gets a column; the four empty
    // ones say nothing the filter does not already say.
    expect(container.querySelectorAll('[data-slot="task-board-column"]')).toHaveLength(
      1
    );
    expect(screen.getByRole("button", { name: "Review task UI" })).toHaveClass(
      "group/task-card"
    );
    expect(screen.getByText("In progress")).toBeInTheDocument();
    expect(screen.queryByText("Backlog")).toBeNull();
    expect(screen.queryAllByText("No tasks")).toHaveLength(0);

    const viewTrigger = screen.getByRole("button", { name: "List view" });
    expect(viewTrigger).toHaveAttribute("data-current-view", "board");
    expect(viewTrigger).toHaveClass(
      "border-primary",
      "bg-fg-button",
      "text-markdown-icon-primary",
      "hover:bg-fg-button",
      "hover:text-markdown-icon-primary",
      "data-[pressed]:scale-[var(--motion-scale-tactile-pressed)]",
      "data-[pressed]:duration-[var(--motion-duration-feedback-in)]"
    );
    expect(containsIconGlyph(viewTrigger, <SettingsSliderHorizontalIcon />)).toBe(true);

    await user.click(viewTrigger);

    const viewPanel = screen.getByRole("dialog", { name: "View" });
    expect(viewPanel).toHaveClass(
      "w-[var(--spacing-11xl)]",
      "rounded-xl",
      "bg-popup-secondary",
      "p-sm",
      "shadow-xs",
      "ring-1",
      "ring-primary"
    );
    const viewMenu = within(viewPanel).getByRole("menu", { name: "View" });
    expect(viewMenu).toHaveClass("grid", "grid-cols-2", "gap-sm");
    const boardOption = within(viewMenu).getByRole("menuitemradio", {
      name: "Board",
    });
    const listOption = within(viewMenu).getByRole("menuitemradio", {
      name: "List",
    });
    expect(boardOption).toHaveAttribute("aria-checked", "true");
    expect(boardOption.firstElementChild).toHaveClass(
      "min-h-[var(--spacing-7xl)]",
      "rounded-sm",
      "bg-fg-button-active",
      "ring-1",
      "ring-primary",
      "text-primary"
    );
    expect(boardOption.firstElementChild).toHaveClass(
      "[&_[data-slot=menu-item-icon]]:text-markdown-image-icon-primary"
    );
    expect(boardOption.querySelector('[data-slot="menu-item-icon"]')).toHaveClass(
      "size-2xl"
    );
    await user.hover(boardOption);
    expect(boardOption.querySelector('[data-slot="menu-item-icon"]')).not.toHaveClass(
      "text-fg-secondary"
    );
    await user.unhover(boardOption);
    expect(listOption).toHaveAttribute("aria-checked", "false");
    expect(listOption.firstElementChild).toHaveClass(
      "bg-fg-button-secondary",
      "text-primary"
    );
    expect(listOption.firstElementChild).toHaveClass(
      "[&_[data-slot=menu-item-icon]]:text-markdown-icon-primary"
    );
    await user.hover(listOption);
    expect(listOption.querySelector('[data-slot="menu-item-icon"]')).not.toHaveClass(
      "text-fg-secondary"
    );

    await user.click(listOption);

    const list = screen.getByTestId("tasks-list");
    expect(within(list).getByText("In progress")).toBeInTheDocument();
    expect(within(list).getByText("Review task UI")).toBeInTheDocument();
    // Groups follow the board: a status with no tasks gets no header row.
    expect(within(list).queryByText("Backlog")).toBeNull();
    expect(within(list).queryByText("Needs Review")).toBeNull();
    expect(within(list).queryByText("No tasks")).toBeNull();

    const taskRow = within(list).getByRole("button", { name: "Review task UI" });
    expect(taskRow).toHaveAttribute("data-slot", "task-list-item");
    expect(taskRow).toHaveClass("p-lg");
    expect(taskRow).toHaveTextContent("Updated");

    // The group keeps its status tint and opts out of the global press scale:
    // a band this wide flinching on a click that only collapses it reads as a
    // glitch, not as feedback.
    const groupHeader = within(list).getByRole("button", { name: "In progress1" });
    expect(groupHeader).toHaveAttribute("data-state", "open");
    expect(groupHeader).toHaveClass("bg-secondary");
    expect(groupHeader).toHaveAttribute("data-no-press-feedback");
    expect(screen.queryByRole("dialog", { name: "View" })).toBeNull();
    const boardViewTrigger = screen.getByRole("button", { name: "Board view" });
    expect(boardViewTrigger).toHaveAttribute("data-current-view", "list");
    expect(containsIconGlyph(boardViewTrigger, <SettingsSliderHorizontalIcon />)).toBe(
      true
    );
  });

  it("dismisses non-modal toolbar panels on an outside interaction", async () => {
    const user = userEvent.setup();
    render(<TaskWorkspace tasks={[taskFixture()]} />);

    const filterTrigger = screen.getByRole("button", { name: "Filter tasks" });
    await user.click(filterTrigger);

    expect(document.querySelector("[inert]")).toBeNull();
    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    await user.click(document.body);
    expect(filterMenu).not.toBeInTheDocument();

    await user.click(filterTrigger);
    const reopenedFilterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    await user.click(
      within(reopenedFilterMenu).getByRole("menuitem", { name: "Status" })
    );
    expect(await screen.findByRole("dialog", { name: "Status" })).toBeVisible();

    await user.click(document.body);

    expect(screen.queryByRole("dialog", { name: "Status" })).toBeNull();
    expect(screen.queryByRole("menu", { name: "Filter tasks" })).toBeNull();

    await user.click(screen.getByRole("button", { name: "List view" }));
    expect(screen.getByRole("dialog", { name: "View" })).toBeVisible();

    await user.click(document.body);

    expect(screen.queryByRole("dialog", { name: "View" })).toBeNull();
  });

  it("hides Worker filtering unless the caller supplies available options", async () => {
    const user = userEvent.setup();
    render(<TaskWorkspace tasks={[taskFixture({ worker: undefined })]} />);

    const filterTrigger = screen.getByRole("button", { name: "Filter tasks" });
    expect(screen.getByText("All tasks")).toBeVisible();
    expect(filterTrigger).toHaveAttribute("data-filtered", "false");
    expect(
      filterTrigger.querySelector('[data-slot="task-status-filter-badge"]')
    ).toBeNull();

    await user.click(filterTrigger);

    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    expect(within(filterMenu).queryByRole("menuitem", { name: "Worker" })).toBeNull();
    expect(within(filterMenu).getByRole("menuitem", { name: "Status" })).toBeVisible();
  });

  it("renders caller filter sections as multi-select submenus", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <TaskWorkspace
        filterSections={[
          {
            icon: <SquareCursorIcon />,
            id: "label",
            label: "Label",
            onChange,
            options: [
              { count: 2, id: "work", label: "Work" },
              { count: 1, id: "none", label: "No label" },
            ],
            selected: new Set(["work", "none"]),
          },
        ]}
        tasks={[taskFixture()]}
      />
    );

    const filterTrigger = screen.getByRole("button", { name: "Filter tasks" });
    expect(filterTrigger).toHaveAttribute("data-filtered", "false");
    await user.click(filterTrigger);
    await user.click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Label",
      })
    );
    const panel = await screen.findByRole("dialog", { name: "Label" });
    await user.click(within(panel).getByRole("menuitemcheckbox", { name: /Work/ }));

    expect(onChange).toHaveBeenCalledWith(new Set(["none"]));
  });

  it("carries the caller's badges into list rows, ahead of the date", async () => {
    const user = userEvent.setup();
    render(
      <TaskWorkspace
        renderTaskBadges={(task) => <span data-testid="row-badge">{task.title}</span>}
        tasks={[taskFixture()]}
      />
    );

    await user.click(screen.getByRole("button", { name: "List view" }));
    await user.click(screen.getByRole("menuitemradio", { name: "List" }));

    const row = within(screen.getByTestId("tasks-list")).getByRole("button", {
      name: "Review task UI",
    });
    const slot = row.querySelector('[data-slot="task-list-item-badges"]');
    expect(slot).not.toBeNull();
    expect(within(slot as HTMLElement).getByTestId("row-badge")).toHaveTextContent(
      "Review task UI"
    );
    expect(
      slot!.compareDocumentPosition(
        row.querySelector('[data-slot="task-list-item-tail"]')!
      ) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy();
  });

  it("shift-clicks cards into a selection the bar hands to Comma, and clears it", async () => {
    const user = userEvent.setup();
    const onAskComma = vi.fn();
    const onOpenTask = vi.fn();
    render(
      <TaskWorkspace
        onAskComma={onAskComma}
        onOpenTask={onOpenTask}
        tasks={[
          taskFixture({ id: "task-a", title: "Task A" }),
          taskFixture({ id: "task-b", title: "Task B" }),
          taskFixture({ id: "task-c", title: "Task C" }),
        ]}
      />
    );
    expect(screen.queryByTestId("tasks-selection-bar")).toBeNull();

    // A plain click still opens; shift starts the selection.
    await user.click(card("Task A"));
    expect(onOpenTask).toHaveBeenCalledTimes(1);
    await user.keyboard("{Shift>}");
    await user.click(card("Task A"));
    await user.keyboard("{/Shift}");
    const bar = await screen.findByTestId("tasks-selection-bar");
    expect(bar).toHaveTextContent("1 selected");
    expect(card("Task A")).toHaveAttribute("data-checked", "true");

    // While one stands, plain clicks toggle instead of opening.
    await user.click(card("Task B"));
    expect(onOpenTask).toHaveBeenCalledTimes(1);
    expect(bar).toHaveTextContent("2 selected");
    await user.click(card("Task B"));
    expect(bar).toHaveTextContent("1 selected");
    await user.click(card("Task C"));

    await user.click(within(bar).getByRole("button", { name: "Ask Comma" }));
    expect(onAskComma).toHaveBeenCalledTimes(1);
    expect(
      onAskComma.mock.calls[0]![0].map((task: TaskWorkspaceTask) => task.id)
    ).toEqual(["task-a", "task-c"]);
    expect(screen.queryByTestId("tasks-selection-bar")).toBeNull();

    await user.keyboard("{Shift>}");
    await user.click(card("Task B"));
    await user.keyboard("{/Shift}");
    expect(await screen.findByTestId("tasks-selection-bar")).toBeVisible();
    await user.keyboard("{Escape}");
    expect(screen.queryByTestId("tasks-selection-bar")).toBeNull();
  });

  it("selects list rows through their checkbox and closes from the bar", async () => {
    const user = userEvent.setup();
    const onAskComma = vi.fn();
    const onOpenTask = vi.fn();
    render(
      <TaskWorkspace
        onAskComma={onAskComma}
        onOpenTask={onOpenTask}
        tasks={[
          taskFixture({ id: "task-a", title: "Task A" }),
          taskFixture({ id: "task-b", title: "Task B" }),
        ]}
      />
    );
    await user.click(screen.getByRole("button", { name: "List view" }));
    await user.click(screen.getByRole("menuitemradio", { name: "List" }));

    await user.click(screen.getByRole("checkbox", { name: "Select Task A" }));
    const bar = await screen.findByTestId("tasks-selection-bar");
    expect(bar).toHaveTextContent("1 selected");
    expect(onOpenTask).not.toHaveBeenCalled();
    const rowB = within(screen.getByTestId("tasks-list")).getByRole("button", {
      name: "Task B",
    });
    await user.click(rowB);
    expect(bar).toHaveTextContent("2 selected");
    expect(rowB).toHaveAttribute("data-checked", "true");

    await user.click(screen.getByTestId("tasks-clear-selection"));
    expect(screen.queryByTestId("tasks-selection-bar")).toBeNull();
    await user.click(rowB);
    expect(onOpenTask).toHaveBeenCalledTimes(1);
  });

  it("archives the checked Tasks that allow it and reports the ones left in place", async () => {
    const user = userEvent.setup();
    const run = vi.fn(async () => undefined);
    render(
      <>
        <Toaster />
        <TaskWorkspace
          onAskComma={vi.fn()}
          onOpenTask={vi.fn()}
          tasks={[
            taskFixture({ archiveAction: { run }, id: "task-a", title: "Task A" }),
            taskFixture({
              archiveAction: {
                disabledReason: "Finish the task before archiving",
                run,
              },
              id: "task-b",
              title: "Task B",
            }),
          ]}
        />
      </>
    );
    await user.keyboard("{Shift>}");
    await user.click(card("Task A"));
    await user.keyboard("{/Shift}");
    const bar = await screen.findByTestId("tasks-selection-bar");
    const archive = within(bar).getByRole("button", { name: "Archive" });
    expect(archive).toBeEnabled();

    await user.click(card("Task B"));
    expect(bar).toHaveTextContent("2 selected");
    await user.click(archive);

    await waitFor(() => expect(run).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(screen.queryByTestId("tasks-selection-bar")).toBeNull());
    expect(
      await screen.findByTestId("tasks-archive-selected-skipped")
    ).toHaveTextContent("1 left in place");
  });

  it("offers no archive while nothing checked allows it", async () => {
    const user = userEvent.setup();
    render(
      <TaskWorkspace
        onAskComma={vi.fn()}
        onOpenTask={vi.fn()}
        tasks={[
          taskFixture({
            archiveAction: {
              disabledReason: "Finish the task before archiving",
              run: vi.fn(),
            },
            id: "task-b",
            title: "Task B",
          }),
        ]}
      />
    );
    await user.keyboard("{Shift>}");
    await user.click(card("Task B"));
    await user.keyboard("{/Shift}");
    const bar = await screen.findByTestId("tasks-selection-bar");
    expect(within(bar).getByRole("button", { name: "Archive" })).toBeDisabled();
  });

  it("counts a narrowed caller section as an active filter", () => {
    const { container } = render(
      <TaskWorkspace
        filterSections={[
          {
            icon: <SquareCursorIcon />,
            id: "platform",
            label: "Platform",
            onChange: vi.fn(),
            options: [
              { count: 1, id: "slack", label: "Slack" },
              { count: 1, id: "comma", label: "Comma" },
            ],
            selected: new Set(["slack"]),
          },
        ]}
        tasks={[taskFixture()]}
      />
    );

    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
    expect(
      container.querySelector('[data-slot="task-status-filter-badge"]')
    ).not.toBeNull();
  });

  it("uses rich status labels for menu typeahead", async () => {
    const user = userEvent.setup();
    render(<TaskWorkspace tasks={[taskFixture()]} />);

    await user.click(screen.getByRole("button", { name: "Filter tasks" }));
    await user.click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Status",
      })
    );

    const statusMenu = within(
      await screen.findByRole("dialog", { name: "Status" })
    ).getByRole("menu", { name: "Status" });
    within(statusMenu).getByRole("menuitemcheckbox", { name: "Backlog" }).focus();

    await user.keyboard("d");

    expect(
      within(statusMenu).getByRole("menuitemcheckbox", { name: "Done" })
    ).toHaveFocus();
  });

  it("uses rich worker labels for menu typeahead", async () => {
    const user = userEvent.setup();
    render(
      <TaskWorkspace
        tasks={[taskFixture({ worker: "codex" })]}
        workerFilterOptions={["codex", "claude"]}
      />
    );

    await user.click(screen.getByRole("button", { name: "Filter tasks" }));
    await user.click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Worker",
      })
    );

    const workerMenu = within(
      await screen.findByRole("dialog", { name: "Worker" })
    ).getByRole("menu", { name: "Worker" });
    within(workerMenu).getByRole("menuitemcheckbox", { name: "Claude" }).focus();

    await user.keyboard("co");

    expect(
      within(workerMenu).getByRole("menuitemcheckbox", { name: "Codex" })
    ).toHaveFocus();
  });

  it("opens the status panel and filters task sections", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <TaskWorkspace
        tasks={[
          taskFixture(),
          taskFixture({
            activityStatus: "completed",
            conversationId: "cnv_task_done",
            id: "task_done",
            statusBucket: "done",
            title: "Ship the task filter",
            worker: "claude",
          }),
          taskFixture({
            conversationId: "cnv_task_running_2",
            id: "task_running_2",
            title: "Verify the task filter",
          }),
        ]}
        workerFilterOptions={["codex", "claude"]}
      />
    );

    const trigger = screen.getByRole("button", {
      name: "Filter tasks",
    });
    await user.click(trigger);

    expect(document.querySelector("[inert]")).toBeNull();

    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    const statusEntry = within(filterMenu).getByRole("menuitem", {
      name: "Status",
    });
    const workerEntry = within(filterMenu).getByRole("menuitem", {
      name: "Worker",
    });
    expect(filterMenu).toHaveClass(
      "w-[var(--task-workspace-filter-menu-width)]",
      "bg-popup-secondary",
      "px-sm",
      "py-sm",
      "shadow-2xl"
    );
    expect(statusEntry).toHaveAttribute("data-appearance", "sidebar");
    expect(statusEntry).toHaveClass("pointer-events-auto");
    expect(statusEntry).not.toHaveClass("px-sm");
    expect(statusEntry.firstElementChild).toHaveClass(
      "h-8",
      "text-sidebar-text-secondary"
    );
    expect(statusEntry.querySelector('[data-slot="menu-item-icon"]')).toHaveClass(
      "text-sidebar-icon-primary"
    );
    expect(containsIconGlyph(statusEntry, <CircleDashedIcon />)).toBe(true);
    expect(containsIconGlyph(workerEntry, <SquareCursorIcon />)).toBe(true);
    expect(workerEntry).toHaveClass("pointer-events-auto");
    expect(
      workerEntry.querySelector('[data-slot="menu-item-shortcut"] svg')
    ).toHaveClass("size-4");
    await user.click(statusEntry);

    const panel = await screen.findByRole("dialog", { name: "Status" });
    expect(panel).toHaveClass(
      "w-56",
      "rounded-xl",
      "border-[length:var(--border-width-0-5)]",
      "border-primary",
      "bg-popup-secondary",
      "shadow-2xl",
      "overflow-hidden",
      "p-0"
    );
    const statusMenu = within(panel).getByRole("menu", { name: "Status" });
    expect(statusMenu).toHaveClass("px-sm", "py-sm");
    expect(
      within(statusMenu).getByRole("menuitemcheckbox", { name: "Done" })
    ).toHaveAttribute("aria-checked", "true");
    expect(within(statusMenu).getByText("1 task")).toBeVisible();
    expect(within(statusMenu).getByText("2 tasks")).toBeVisible();
    expect(within(statusMenu).getAllByText("0 tasks")).toHaveLength(3);

    const backlogItem = within(statusMenu).getByRole("menuitemcheckbox", {
      name: "Backlog",
    });
    const inProgressItem = within(statusMenu).getByRole("menuitemcheckbox", {
      name: "In progress",
    });
    await user.hover(backlogItem);
    expect(backlogItem).toHaveFocus();

    await user.keyboard("{ArrowDown}");

    expect(inProgressItem).toHaveFocus();
    expect(backlogItem).toHaveAttribute("data-hovered", "true");
    expect(backlogItem.firstElementChild).not.toHaveClass("bg-secondary-hover");
    expect(inProgressItem.firstElementChild).toHaveClass("bg-secondary-hover");

    const searchInput = within(panel).getByRole("textbox", {
      name: "Filter…",
    });
    const searchControl = searchInput.parentElement;
    expect(searchControl).toHaveClass(
      "rounded-none",
      "border-0",
      "border-b-[length:var(--border-width-0-5)]",
      "border-primary",
      "bg-transparent",
      "shadow-none",
      "ring-0"
    );
    await user.click(searchInput);
    expect(searchInput).toHaveFocus();
    await user.hover(statusEntry);
    expect(searchInput).toHaveFocus();
    expect(searchControl).not.toHaveClass(
      "ring-2",
      "ring-border-brand",
      "shadow-focus-brand-shadow-xs"
    );

    await user.type(searchInput, "done");
    expect(
      within(panel).queryByRole("menuitemcheckbox", { name: "Backlog" })
    ).toBeNull();

    const doneItem = within(panel).getByRole("menuitemcheckbox", { name: "Done" });
    await user.click(doneItem);

    await user.unhover(doneItem);

    expect(doneItem.firstElementChild).toHaveClass("h-8");
    expect(doneItem.firstElementChild).toHaveClass(
      "scale-100",
      "transition-[scale,background-color,color]",
      "duration-[var(--motion-duration-feedback-out)]"
    );
    const doneControl = doneItem.querySelector('[data-slot="checkbox-control"]');
    expect(doneControl).toHaveClass("opacity-0");
    expect(doneControl).not.toHaveClass("transition-opacity");

    await user.hover(doneItem);
    expect(doneControl).not.toHaveClass("opacity-0");

    expect(trigger).toHaveAttribute("data-filtered", "true");
    expect(screen.getByText("Filtered tasks")).toBeInTheDocument();
    // Done is deselected, and the three remaining statuses hold no tasks, so
    // only In progress is left standing.
    expect(container.querySelectorAll('[data-slot="task-board-column"]')).toHaveLength(
      1
    );
    expect(
      Array.from(
        container.querySelectorAll('[data-slot="task-board-column-label"]')
      ).map((element) => element.textContent)
    ).not.toContain("Done");

    await user.clear(searchInput);
    await user.type(searchInput, "not-a-status");

    const emptyMessage = within(panel).getByText("No filters found");
    expect(emptyMessage).toHaveClass("py-md", "text-disabled");
    expect(emptyMessage).not.toHaveClass("py-xl", "text-tertiary");
  });

  it("keeps a submenu active across its connected panel and clears it after exit", async () => {
    const user = userEvent.setup();
    render(<TaskWorkspace tasks={[taskFixture()]} />);

    await user.click(screen.getByRole("button", { name: "Filter tasks" }));

    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    const statusEntry = within(filterMenu).getByRole("menuitem", {
      name: "Status",
    });
    const statusContent = statusEntry.firstElementChild;

    await user.hover(statusEntry);

    expect(statusContent).toHaveClass(
      "bg-secondary-hover",
      "text-sidebar-text-highlight"
    );

    const panel = await screen.findByRole("dialog", { name: "Status" });
    expect(statusEntry).toHaveAttribute("aria-expanded", "true");

    await user.hover(panel);

    expect(statusEntry).toHaveAttribute("aria-expanded", "true");
    expect(statusEntry).not.toHaveAttribute("data-hovered");
    expect(statusContent).toHaveClass(
      "bg-secondary-hover",
      "text-sidebar-text-highlight"
    );

    await user.hover(screen.getByText("All tasks"));

    await act(async () => {
      await new Promise((resolve) =>
        setTimeout(resolve, motionDuration.submenuCloseDelay)
      );
    });
    expect(statusEntry).toHaveAttribute("aria-expanded", "false");
    expect(statusContent).not.toHaveClass(
      "bg-secondary-hover",
      "text-sidebar-text-highlight"
    );
    expect(screen.queryByRole("dialog", { name: "Status" })).toBeNull();
    expect(screen.getByRole("menu", { name: "Filter tasks" })).toBeVisible();
  });

  it("switches directly between sibling submenus on pointer hover", async () => {
    const user = userEvent.setup();
    render(
      <TaskWorkspace
        tasks={[taskFixture()]}
        workerFilterOptions={["codex", "claude"]}
      />
    );

    await user.click(screen.getByRole("button", { name: "Filter tasks" }));

    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    const statusEntry = within(filterMenu).getByRole("menuitem", {
      name: "Status",
    });
    const workerEntry = within(filterMenu).getByRole("menuitem", {
      name: "Worker",
    });

    await user.hover(statusEntry);
    expect(await screen.findByRole("dialog", { name: "Status" })).toBeVisible();

    await user.hover(workerEntry);

    expect(await screen.findByRole("dialog", { name: "Worker" })).toBeVisible();
    expect(statusEntry).toHaveAttribute("aria-expanded", "false");
    expect(workerEntry).toHaveAttribute("aria-expanded", "true");
  });

  it("filters tasks by worker without hiding unassigned tasks by default", async () => {
    const user = userEvent.setup();
    render(
      <TaskWorkspace
        tasks={[
          taskFixture({ id: "task_codex", title: "Codex task", worker: "codex" }),
          taskFixture({ id: "task_claude", title: "Claude task", worker: "claude" }),
          taskFixture({
            id: "task_unassigned",
            title: "Unassigned task",
            worker: undefined,
          }),
        ]}
        workerFilterOptions={["codex", "claude"]}
      />
    );

    expect(screen.getByText("Unassigned task")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Filter tasks" }));

    const filterMenu = screen.getByRole("menu", { name: "Filter tasks" });
    await user.click(within(filterMenu).getByRole("menuitem", { name: "Worker" }));
    const workerPanel = await screen.findByRole("dialog", { name: "Worker" });
    const workerMenu = within(workerPanel).getByRole("menu", { name: "Worker" });
    expect(
      within(workerMenu).getByRole("menuitemcheckbox", { name: "Codex" })
    ).toHaveAttribute("aria-checked", "true");
    expect(
      within(workerMenu).getByRole("menuitemcheckbox", { name: "Claude" })
    ).toHaveAttribute("aria-checked", "true");
    expect(
      within(workerMenu)
        .getByRole("menuitemcheckbox", { name: "Codex" })
        .querySelector('[data-slot="menu-item-icon"] [data-comma-icon]')
    ).toBeInTheDocument();
    expect(
      within(workerMenu)
        .getByRole("menuitemcheckbox", { name: "Claude" })
        .querySelector('[data-slot="menu-item-icon"] [data-comma-icon]')
    ).toBeInTheDocument();
    await user.click(
      within(workerMenu).getByRole("menuitemcheckbox", { name: "Claude" })
    );

    expect(screen.getByText("Codex task")).toBeVisible();
    expect(screen.queryByText("Claude task")).toBeNull();
    expect(screen.queryByText("Unassigned task")).toBeNull();
    expect(screen.getByText("Filtered tasks")).toBeVisible();
  });

  it("owns task selection and detail conversation interactions", async () => {
    const onCopyLink = vi.fn();
    const onExpand = vi.fn();
    const onSendMessage = vi.fn();
    const task = taskFixture();
    render(
      <TaskWorkspace
        onCopyLink={onCopyLink}
        onExpand={onExpand}
        onSendMessage={onSendMessage}
        tasks={[task]}
      />
    );

    await userEvent.click(screen.getByRole("button", { name: task.title }));

    const taskChat = screen.getByRole("complementary", { name: "Task chat" });
    expect(taskChat).toBeVisible();
    expect(within(taskChat).getByText("I am checking it now.")).toBeVisible();
    expect(within(taskChat).queryByRole("button", { name: "Full-access" })).toBeNull();
    await userEvent.click(screen.getByRole("button", { name: "Open task chat" }));
    await userEvent.click(screen.getByRole("button", { name: "Copy task link" }));
    await userEvent.type(screen.getByLabelText("Continue task"), "Looks good");
    await userEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(onExpand).toHaveBeenCalledWith(task);
    expect(onCopyLink).toHaveBeenCalledWith(task);
    expect(onSendMessage).toHaveBeenCalledWith(task, "Looks good");
  });

  it("delegates keyboard selection when a runtime open handler is provided", async () => {
    const onOpenTask = vi.fn();
    const task = taskFixture();
    render(<TaskWorkspace initialView="list" onOpenTask={onOpenTask} tasks={[task]} />);

    const taskRow = screen.getByRole("button", { name: task.title });
    taskRow.focus();
    await userEvent.keyboard("{Enter}");

    expect(onOpenTask).toHaveBeenCalledWith(task);
    expect(screen.queryByRole("complementary", { name: "Task chat" })).toBeNull();
  });
});

/** A board card by its title. */
const card = (title: string) => screen.getByRole("button", { name: new RegExp(title) });

function taskFixture(overrides: Partial<TaskWorkspaceTask> = {}): TaskWorkspaceTask {
  return {
    activityStatus: "running",
    conversationId: "cnv_task_1",
    groupId: "grp_1",
    updatedAt: 1_700_000_000,
    freshness: "fresh",
    id: "task_1",
    lastMessage: {
      content: "I am checking it now.",
      id: "msg_1",
      role: "assistant",
      roleLabel: "Comma",
    },
    messages: [
      {
        content: "I am checking it now.",
        id: "msg_1",
        role: "assistant",
        roleLabel: "Comma",
      },
    ],
    statusBucket: "in_progress",
    title: "Review task UI",
    worker: "codex",
    workspaceId: "wsp_1",
    ...overrides,
  };
}
