import { flush } from "@comma/test-utils/fake-clock";
import { renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { expect, it } from "vitest";
import { useWorkspaceTasks } from "../useWorkspaceTasks";

const workspace = { id: "ws-a", groupId: "grp-a", name: "Workspace A" };

const item = (id: string) => ({
  archiveVersion: 1,
  conversationId: id,
  groupId: workspace.groupId,
  id: `${workspace.groupId}:${id}`,
  kind: "agent_task",
  status: "done",
  title: `Task ${id}`,
  updatedAt: 1_790_000_000_000,
  workspaceId: workspace.id,
});

function render(list: Record<string, unknown>) {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : topic.topic === "tasks"
          ? { activeWorkspaceId: workspace.id, ...list }
          : undefined,
  });
  return renderHook(() => useWorkspaceTasks(), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
}

it("says once for the list that a failed read left it as kept", async () => {
  const { result } = render({
    errorCode: "network_unavailable",
    items: [item("c1"), item("c2")],
    source: "cache",
  });
  await flush();
  expect(result.current.taskSyncError).toEqual(expect.any(String));
  expect(result.current.taskLoadError).toBeUndefined();
  expect(result.current.tasks.map((task) => task.title)).toEqual([
    "Task c1",
    "Task c2",
  ]);
});

it("says nothing while the kept list waits for its first read", async () => {
  const { result } = render({ items: [item("c1")], source: "cache" });
  await flush();
  expect(result.current.taskSyncError).toBeUndefined();
  expect(result.current.tasks.map((task) => task.title)).toEqual(["Task c1"]);
});
