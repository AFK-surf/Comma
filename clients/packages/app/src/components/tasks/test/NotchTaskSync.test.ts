import { describe, expect, it, vi } from "vitest";
import { handleNotchTaskOpen, toNotchTaskItems } from "../NotchTaskSync";
import type { TaskViewModel } from "../useWorkspaceTasks";

describe("toNotchTaskItems", () => {
  it("projects only in-progress tasks into the native Notch contract", () => {
    expect(
      toNotchTaskItems(
        [
          task("running", "in_progress", 20),
          task("queued", "backlog", 10),
          task("done", "done", 5),
        ],
        "In progress"
      )
    ).toEqual([
      {
        conversationId: "conversation-running",
        groupId: "group-1",
        id: "running",
        status: "in_progress",
        subtitle: "In progress",
        title: "Task running",
        updatedAt: 20,
        workspaceId: "workspace-1",
      },
    ]);
  });

  it("returns an empty projection when no task is in progress", () => {
    expect(toNotchTaskItems([task("queued", "backlog", 10)], "In progress")).toEqual(
      []
    );
  });

  it("closes the Notch, focuses Comma, and opens the selected task chat", () => {
    const close = vi.fn();
    const focusMainWindow = vi.fn();
    const navigate = vi.fn();
    const tasks = toNotchTaskItems([task("running", "in_progress", 20)], "In progress");

    expect(
      handleNotchTaskOpen(
        {
          payload: { action: "task:open", value: "running" },
          type: "action",
        },
        tasks,
        { close, focusMainWindow, navigate }
      )
    ).toBe(true);
    expect(close).toHaveBeenCalledOnce();
    expect(focusMainWindow).toHaveBeenCalledOnce();
    expect(navigate).toHaveBeenCalledWith(tasks[0]);
  });

  it("ignores task actions that do not identify a current Notch task", () => {
    const actions = {
      close: vi.fn(),
      focusMainWindow: vi.fn(),
      navigate: vi.fn(),
    };

    expect(
      handleNotchTaskOpen(
        {
          payload: { action: "task:open", value: "stale-task" },
          type: "action",
        },
        [],
        actions
      )
    ).toBe(false);
    expect(actions.close).not.toHaveBeenCalled();
    expect(actions.focusMainWindow).not.toHaveBeenCalled();
    expect(actions.navigate).not.toHaveBeenCalled();
  });
});

function task(
  id: string,
  statusBucket: TaskViewModel["statusBucket"],
  updatedAt: number
): TaskViewModel {
  return {
    activityStatus: id,
    conversationId: `conversation-${id}`,
    freshness: "fresh",
    groupId: "group-1",
    id,
    messages: [],
    origin: undefined,
    statusBucket,
    title: `Task ${id}`,
    updatedAt,
    workspaceId: "workspace-1",
  };
}
