import type { SidebarTaskModel } from "./useSidebarTasks";

export function sidebarTaskNavigationTarget(task: SidebarTaskModel) {
  return {
    params: {
      conversationId: task.conversationId,
      groupId: task.groupId,
      workspaceId: task.workspaceId,
    },
    to: "/tasks/$workspaceId/$groupId/$conversationId" as const,
  };
}

export function sidebarTaskConversationId(pathname: string) {
  return pathname.match(/^\/tasks\/[^/]+\/[^/]+\/([^/]+)$/)?.[1];
}
