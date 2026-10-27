import { describe, expect, it, vi } from "vitest";
import {
  handleNotchTaskOpen,
  notchStepFeedTasks,
  toNotchTaskItems,
  withWorkerSteps,
} from "../NotchTaskSync";
import type { TaskViewModel } from "../useWorkspaceTasks";

describe("toNotchTaskItems", () => {
  it("projects only in-progress tasks into the native Notch contract", () => {
    expect(
      toNotchTaskItems(
        [
          task("running", "in_progress", 20),
          task("review", "needs_review", 10),
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
    expect(
      toNotchTaskItems([task("review", "needs_review", 10)], "In progress")
    ).toEqual([]);
  });

  it("lists at most twenty running Tasks, the most recently updated first", () => {
    const many = Array.from({ length: 25 }, (_, n) =>
      task(`t${n + 1}`, "in_progress", n + 1)
    );

    const ids = toNotchTaskItems(many, "In progress").map((item) => item.id);
    expect(ids).toHaveLength(20);
    expect(ids[0]).toBe("t25");
    expect(ids.at(-1)).toBe("t6");
  });

  it("shows a followed Worker's latest step in place of the status", () => {
    const tasks = toNotchTaskItems(
      [task("old", "in_progress", 10), task("new", "in_progress", 20)],
      "In progress"
    );
    const steps = new Map([["new", "Read SKILL.md"]]);

    expect(
      withWorkerSteps(tasks, steps).map(({ id, subtitle }) => ({ id, subtitle }))
    ).toEqual([
      { id: "new", subtitle: "Read SKILL.md" },
      { id: "old", subtitle: "In progress" },
    ]);
  });

  it("follows at most two running Tasks, the most recently updated first", () => {
    const tasks = toNotchTaskItems(
      [
        task("a", "in_progress", 10),
        task("b", "in_progress", 30),
        task("c", "in_progress", 20),
      ],
      "In progress"
    );

    expect(notchStepFeedTasks(tasks).map((item) => item.id)).toEqual(["b", "c"]);
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
