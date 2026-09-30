import { renderHook } from "@comma/test-utils/render";
import type { TaskViewModel } from "../../tasks/useWorkspaceTasks";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useSidebarTasks } from "../useSidebarTasks";

const mocks = vi.hoisted(() => ({
  workspace: {
    activeGroupId: "grp1_1" as string | undefined,
    activeWorkspaceId: "wsp_1" as string | undefined,
    tasks: [] as TaskViewModel[],
  },
}));

vi.mock("../../tasks/useWorkspaceTasks", () => ({
  useWorkspaceTasks: () => mocks.workspace,
}));

describe("useSidebarTasks", () => {
  beforeEach(() => {
    mocks.workspace.tasks = [
      {
        conversationId: "cnv_older",
        groupId: "grp1_1",
        statusBucket: "done",
        title: "Older task",
        updatedAt: 10,
        workspaceId: "wsp_1",
      },
      {
        conversationId: "cnv_newer",
        groupId: "grp1_1",
        statusBucket: "in_progress",
        title: "Newer task",
        updatedAt: 20,
        workspaceId: "wsp_1",
      },
      {
        conversationId: "cnv_review",
        groupId: "grp1_1",
        statusBucket: "needs_review",
        title: "Review task",
        updatedAt: 15,
        workspaceId: "wsp_1",
      },
    ] as TaskViewModel[];
  });

  it("orders recent tasks by their latest update", () => {
    const { result } = renderHook(() => useSidebarTasks());

    expect(result.current.recent.map((task) => task.id)).toEqual([
      "cnv_newer",
      "cnv_review",
      "cnv_older",
    ]);
    expect(result.current.recent[0]).toMatchObject({
      conversationId: "cnv_newer",
      groupId: "grp1_1",
      label: "Newer task",
      workspaceId: "wsp_1",
    });
  });
});
