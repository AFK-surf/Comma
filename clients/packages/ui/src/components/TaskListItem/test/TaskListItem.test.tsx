import { act } from "react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { getMenuPointerOffsets, MenuItem } from "../../menu";
import { TaskListItem } from "../TaskListItem";
import {
  contentTaskIconStates,
  resolveTaskListItemStoryIcon,
  sidebarRunIconStates,
} from "../taskListItemStoryIcons";

const Icon = ({ name }: { name: string }) => <span data-testid={name} />;

describe("TaskListItem", () => {
  it("renders an actionable content row as a native button", async () => {
    const onClick = vi.fn();
    render(
      <TaskListItem
        as="button"
        icon={<Icon name="task-icon" />}
        onClick={onClick}
        title="Open task"
      />
    );

    const row = screen.getByRole("button", { name: "Open task" });
    expect(row.tagName).toBe("BUTTON");
    expect(row).toHaveClass("focus-visible:shadow-focus-gray");

    row.focus();
    await userEvent.keyboard("{Enter}");
    await userEvent.keyboard(" ");

    expect(onClick).toHaveBeenCalledTimes(2);
  });

  it("renders icon, dot, title, and tail slots", () => {
    const { container } = render(
      <TaskListItem
        dot
        icon={<Icon name="task-icon" />}
        layout="sidebar"
        title="Summarizing recent OpenAI's update"
        tail="Create May 9"
      />
    );

    expect(screen.getByText("Summarizing recent OpenAI's update")).toBeInTheDocument();
    expect(screen.getByText("Create May 9")).toBeInTheDocument();
    expect(container.querySelector('[data-slot="task-list-item-icon"]')).toBeTruthy();
    expect(container.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "visible"
    );
    expect(container.querySelector('[data-slot="task-list-item-tail"]')).toHaveClass(
      "font-medium",
      "text-quaternary"
    );
  });

  it("renders content tail typography", () => {
    const { container } = render(
      <TaskListItem
        icon={<Icon name="task-icon" />}
        layout="content"
        tail="Create May 9"
        title="Untitled"
      />
    );

    expect(screen.getByText("Create May 9")).toHaveClass(
      "font-normal",
      "text-quaternary",
      "shrink-0"
    );
    expect(container.querySelector('[data-slot="task-list-item-tail"]')).toHaveClass(
      "contents"
    );
  });

  it("uses medium tail typography for the sidebar layout", () => {
    const { container } = render(
      <TaskListItem
        icon={<Icon name="task-icon" />}
        layout="sidebar"
        tail="30m"
        title="Summarizing recent OpenAI's update"
      />
    );

    expect(container.querySelector('[data-slot="task-list-item-tail"]')).toHaveClass(
      "font-medium",
      "text-quaternary"
    );
    expect(container.querySelector('[data-slot="task-list-item-title"]')).toHaveClass(
      "font-normal"
    );
    expect(container.firstElementChild).toHaveClass("px-lg", "py-md");
    expect(container.firstElementChild).not.toHaveClass("p-lg");
  });

  it("indents the content row icon under the group header with a hidden handle", () => {
    const { container } = render(
      <div className="w-[360px]">
        <TaskListItem
          icon={<Icon name="task-icon" />}
          layout="content"
          tail="Create May 9"
          title="Summarizing recent OpenAI's update and create a HTML"
        />
      </div>
    );

    const main = container.querySelector('[data-slot="task-list-item-main"]');
    const root = main?.parentElement;
    const handle = container.querySelector('[data-slot="task-list-item-handle"]');

    expect(container.querySelector('[data-slot="task-list-item-dot"]')).toBeNull();
    expect(screen.getByText("Create May 9")).toBeInTheDocument();
    expect(root).toHaveClass("items-center", "p-lg");
    expect(root?.children[0]).toHaveAttribute("data-slot", "task-list-item-main");
    expect(root?.children[1]).toHaveAttribute("data-slot", "task-list-item-tail");

    expect(main).toHaveClass("min-w-0", "flex-1", "gap-md");
    expect(main?.children[0]).toHaveAttribute("data-slot", "task-list-item-handle");
    expect(main?.children[1]).toHaveAttribute("data-slot", "task-list-item-icon");
    expect(main?.children[2]).toHaveAttribute("data-slot", "task-list-item-title");
    expect(handle).toHaveClass("size-[18px]", "shrink-0", "opacity-0");
    expect(container.querySelector('[data-slot="task-list-item-icon"]')).toHaveClass(
      "size-[18px]"
    );
    expect(container.querySelector('[data-slot="task-list-item-title"]')).toHaveClass(
      "min-w-0",
      "flex-1",
      "truncate"
    );
  });

  it("renders schedule tag and date in the content tail group", () => {
    const { container } = render(
      <div className="w-[360px]">
        <TaskListItem
          icon={<Icon name="task-icon" />}
          layout="content"
          tail={
            <>
              <span data-testid="schedule-tag">Schedules</span>
              <span>Create May 9</span>
            </>
          }
          title="Summarizing recent OpenAI's update and create a HTML"
        />
      </div>
    );

    const root = container.querySelector(
      '[data-slot="task-list-item-main"]'
    )?.parentElement;
    const tail = container.querySelector('[data-slot="task-list-item-tail"]');

    expect(root?.children).toHaveLength(2);
    expect(root?.children[0]).toHaveAttribute("data-slot", "task-list-item-main");
    expect(root?.children[1]).toHaveAttribute("data-slot", "task-list-item-tail");
    expect(tail).toHaveClass("contents");
    expect(tail?.children).toHaveLength(2);
    expect(screen.getByTestId("schedule-tag")).toBeInTheDocument();
    expect(screen.getByText("Create May 9")).toBeInTheDocument();
  });

  it("does not reserve an extra flex gap when the dot is hidden", () => {
    const { container, rerender } = render(
      <TaskListItem
        icon={<Icon name="idle-icon" />}
        layout="sidebar"
        title="Untitled"
        tail="Create May 9"
      />
    );

    const main = container.querySelector('[data-slot="task-list-item-main"]');
    const dot = container.querySelector('[data-slot="task-list-item-dot"]');

    expect(main?.className).not.toMatch(/\bgap-/);
    expect(dot).toHaveClass("task-list-item-dot-track");
    expect(dot).toHaveAttribute("data-state", "hidden");

    rerender(
      <TaskListItem
        dot
        icon={<Icon name="idle-icon" />}
        layout="sidebar"
        title="Untitled"
        tail="Create May 9"
      />
    );

    expect(container.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "visible"
    );
  });

  it("uses the sidebar item background for hover unless disabled", () => {
    const { container, rerender } = render(
      <TaskListItem icon={<Icon name="idle-icon" />} title="Untitled" />
    );

    expect(container.firstElementChild).toHaveClass("hover:bg-sidebar-bg-item");

    rerender(
      <TaskListItem disabled icon={<Icon name="idle-icon" />} title="Untitled" />
    );

    expect(container.firstElementChild).not.toHaveClass("hover:bg-sidebar-bg-item");
    expect(container.firstElementChild).toHaveClass("cursor-not-allowed", "opacity-60");
  });

  it("opens its context menu at the pointer and closes after an action", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();
    const onContextMenu = vi.fn();
    const onContextMenuOpenChange = vi.fn();
    const { container } = render(
      <TaskListItem
        contextMenu={{
          "aria-label": "Task actions",
          onAction,
          children: <MenuItem id="rename">Rename</MenuItem>,
        }}
        icon={<Icon name="task-icon" />}
        onContextMenu={onContextMenu}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Context menu task"
      />
    );

    const row = container.querySelector<HTMLElement>('[data-slot="task-list-item"]');
    if (!row) throw new Error("Expected task list item");

    vi.spyOn(row, "getBoundingClientRect").mockReturnValue({
      x: 100,
      y: 200,
      top: 200,
      right: 500,
      bottom: 244,
      left: 100,
      width: 400,
      height: 44,
      toJSON: () => ({}),
    });

    fireEvent.pointerDown(row, {
      button: 2,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
    });
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 220,
      clientY: 218,
    });
    fireEvent(row, contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(true);
    expect(onContextMenu).toHaveBeenCalledTimes(1);
    expect(onContextMenuOpenChange).toHaveBeenCalledWith(true);
    expect(row).toHaveAttribute("data-context-menu-open", "true");
    expect(row).toHaveClass("bg-sidebar-bg-item");
    expect(screen.getByRole("menuitem", { name: "Rename" })).toBeInTheDocument();
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-placement", "right");
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
    expect(getMenuPointerOffsets(row, 220, 218)).toEqual({
      crossOffset: 18,
      offset: -276,
    });

    await user.click(screen.getByRole("menuitem", { name: "Rename" }));

    expect(onAction).toHaveBeenCalledWith("rename");
    expect(onContextMenuOpenChange).toHaveBeenLastCalledWith(false);
    expect(row).toHaveAttribute("data-context-menu-open", "false");
    expect(row).not.toHaveClass("bg-sidebar-bg-item");
  });

  it("opens its context menu from the keyboard and restores focus on Escape", async () => {
    const user = userEvent.setup();
    const onContextMenuOpenChange = vi.fn();
    const { container } = render(
      <TaskListItem
        contextMenu={{
          "aria-label": "Task actions",
          children: (
            <>
              <MenuItem id="rename">Rename</MenuItem>
              <MenuItem id="delete">Delete</MenuItem>
            </>
          ),
        }}
        icon={<Icon name="task-icon" />}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Keyboard context menu task"
      />
    );

    const row = container.querySelector<HTMLElement>('[data-slot="task-list-item"]');
    if (!row) throw new Error("Expected task list item");

    await user.tab();
    expect(row).toHaveFocus();
    expect(row).toHaveAttribute("aria-haspopup", "menu");

    await user.keyboard("{Shift>}{F10}{/Shift}");

    expect(screen.getByRole("menuitem", { name: "Rename" })).toHaveFocus();
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
    expect(onContextMenuOpenChange).toHaveBeenCalledTimes(1);
    expect(onContextMenuOpenChange).toHaveBeenLastCalledWith(true);

    await user.keyboard("{Escape}");

    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    expect(row).toHaveFocus();
    expect(row).toHaveAttribute("data-context-menu-open", "false");
    expect(onContextMenuOpenChange).toHaveBeenCalledTimes(2);
    expect(onContextMenuOpenChange).toHaveBeenLastCalledWith(false);
  });

  it("closes an open context menu when the item becomes disabled", async () => {
    const contextMenu = {
      "aria-label": "Task actions",
      children: <MenuItem id="rename">Rename</MenuItem>,
    };
    const onContextMenuOpenChange = vi.fn();
    const { container, rerender } = render(
      <TaskListItem
        contextMenu={contextMenu}
        icon={<Icon name="task-icon" />}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Task becoming disabled"
      />
    );

    const row = container.querySelector<HTMLElement>('[data-slot="task-list-item"]');
    if (!row) throw new Error("Expected task list item");

    fireEvent.contextMenu(row);
    expect(screen.getByRole("menu")).toBeInTheDocument();

    rerender(
      <TaskListItem
        contextMenu={contextMenu}
        disabled
        icon={<Icon name="task-icon" />}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Task becoming disabled"
      />
    );

    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    expect(row).toHaveAttribute("data-context-menu-open", "false");
    expect(row).not.toHaveClass("bg-sidebar-bg-item");
    expect(onContextMenuOpenChange.mock.calls).toEqual([[true], [false]]);
  });

  it("clears open state and restores row focus when its context menu is removed", async () => {
    const onContextMenuOpenChange = vi.fn();
    const { container, rerender } = render(
      <TaskListItem
        contextMenu={{
          "aria-label": "Task actions",
          children: <MenuItem id="rename">Rename</MenuItem>,
        }}
        icon={<Icon name="task-icon" />}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Task losing its menu"
      />
    );

    const row = container.querySelector<HTMLElement>('[data-slot="task-list-item"]');
    if (!row) throw new Error("Expected task list item");

    row.focus();
    fireEvent.contextMenu(row);
    expect(screen.getByRole("menuitem", { name: "Rename" })).toHaveFocus();

    rerender(
      <TaskListItem
        icon={<Icon name="task-icon" />}
        onContextMenuOpenChange={onContextMenuOpenChange}
        title="Task losing its menu"
      />
    );

    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
    expect(row).toHaveFocus();
    expect(row).toHaveAttribute("data-context-menu-open", "false");
    expect(row).not.toHaveClass("bg-sidebar-bg-item");
    expect(onContextMenuOpenChange.mock.calls).toEqual([[true], [false]]);
  });

  it("does not override disabled or consumer-owned context menu behavior", () => {
    const contextMenu = {
      "aria-label": "Task actions",
      children: <MenuItem id="rename">Rename</MenuItem>,
    };
    const { container, rerender } = render(
      <TaskListItem
        contextMenu={contextMenu}
        disabled
        icon={<Icon name="task-icon" />}
        title="Disabled task"
      />
    );

    const disabledRow = container.querySelector<HTMLElement>(
      '[data-slot="task-list-item"]'
    );
    if (!disabledRow) throw new Error("Expected disabled task list item");

    const disabledContextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
    });
    fireEvent(disabledRow, disabledContextMenuEvent);

    expect(disabledContextMenuEvent.defaultPrevented).toBe(false);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();

    rerender(
      <TaskListItem
        contextMenu={contextMenu}
        icon={<Icon name="task-icon" />}
        onContextMenu={(event) => event.preventDefault()}
        title="Consumer-owned task"
      />
    );

    const consumerOwnedRow = container.querySelector<HTMLElement>(
      '[data-slot="task-list-item"]'
    );
    if (!consumerOwnedRow) throw new Error("Expected consumer-owned task list item");

    fireEvent.contextMenu(consumerOwnedRow);

    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(consumerOwnedRow).toHaveAttribute("data-context-menu-open", "false");
  });

  it("keeps exiting and entering icons mounted during the switch animation", () => {
    vi.useFakeTimers();

    const { container, rerender } = render(
      <TaskListItem
        icon={<Icon name="loading-icon" />}
        iconKey="loading"
        title="Run task"
      />
    );

    rerender(
      <TaskListItem icon={<Icon name="done-icon" />} iconKey="done" title="Run task" />
    );

    expect(
      container.querySelector('[data-motion="exit"] [data-testid="loading-icon"]')
    ).toBeTruthy();
    expect(
      container.querySelector('[data-motion="enter"] [data-testid="done-icon"]')
    ).toBeTruthy();

    act(() => {
      vi.advanceTimersByTime(220);
    });

    expect(container.querySelector('[data-motion="exit"]')).toBeNull();
    expect(
      container.querySelector('[data-motion="idle"] [data-testid="done-icon"]')
    ).toBeTruthy();

    vi.useRealTimers();
  });

  it("falls back to default icons when playground params are incomplete", () => {
    const iconState = resolveTaskListItemStoryIcon("content", undefined, undefined);

    expect(iconState.icon).toBeTruthy();
    expect(iconState.label).toBe("Backlog");
  });

  it("renders distinct icons for each content task state", () => {
    const signatures = Object.entries(contentTaskIconStates).map(
      ([key, { renderIcon }]) => {
        const { container } = render(
          <TaskListItem icon={renderIcon()} iconKey={key} title="Task" />
        );
        const svg = container.querySelector('[data-slot="task-list-item-icon"] svg');
        const path = svg?.querySelector("path")?.getAttribute("d") ?? "";
        return `${path}:${svg?.className ?? ""}`;
      }
    );

    expect(new Set(signatures).size).toBe(signatures.length);
  });

  it("renders distinct icons for each sidebar run state", () => {
    const signatures = Object.entries(sidebarRunIconStates).map(
      ([key, { renderIcon }]) => {
        const { container } = render(
          <TaskListItem
            icon={renderIcon()}
            iconKey={key}
            layout="sidebar"
            title="Task"
          />
        );
        const svg = container.querySelector('[data-slot="task-list-item-icon"] svg');
        return svg?.outerHTML ?? "";
      }
    );

    expect(new Set(signatures).size).toBe(signatures.length);
  });

  it("updates the visible icon when playground state changes", () => {
    vi.useFakeTimers();

    const { container, rerender } = render(
      <TaskListItem
        icon={contentTaskIconStates.backlog.renderIcon()}
        iconKey="backlog"
        title="Task"
      />
    );

    const readCurrentSvg = () =>
      container.querySelector(
        '[data-slot="task-list-item-icon"] [data-motion="idle"] svg, [data-slot="task-list-item-icon"] [data-motion="enter"] svg'
      )?.outerHTML ??
      container.querySelector('[data-slot="task-list-item-icon"] svg')?.outerHTML ??
      "";

    const backlogSvg = readCurrentSvg();

    rerender(
      <TaskListItem
        icon={contentTaskIconStates.done.renderIcon()}
        iconKey="done"
        title="Task"
      />
    );

    act(() => {
      vi.advanceTimersByTime(220);
    });

    const doneSvg = readCurrentSvg();
    expect(backlogSvg).not.toBe(doneSvg);

    vi.useRealTimers();
  });
});
