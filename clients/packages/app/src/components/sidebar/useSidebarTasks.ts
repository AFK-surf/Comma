import { useMemo } from "react";
import { useWorkspaceTasks, type TaskViewModel } from "../tasks/useWorkspaceTasks";

export interface SidebarTaskModel {
  conversationId: string;
  groupId: string;
  id: string;
  label: string;
  statusBucket: TaskViewModel["statusBucket"];
  updatedAt: number;
  workspaceId: string;
}

/** The workspace's tasks, most recently updated first, for the window bar's recent-tasks menu. */
export function useSidebarTasks() {
  const { tasks } = useWorkspaceTasks();
  const recent = useMemo(
    () =>
      tasks
        .toSorted((left, right) => right.updatedAt - left.updatedAt)
        .map(fromWorkspaceTask),
    [tasks]
  );

  return { recent };
}

function fromWorkspaceTask(task: TaskViewModel): SidebarTaskModel {
  return {
    conversationId: task.conversationId,
    groupId: task.groupId,
    id: task.conversationId,
    label: task.title,
    statusBucket: task.statusBucket,
    updatedAt: task.updatedAt,
    workspaceId: task.workspaceId,
  };
}
