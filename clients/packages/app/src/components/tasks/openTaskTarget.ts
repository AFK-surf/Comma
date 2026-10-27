/** Where opening a Task goes: its conversation, wherever it runs (the core opens one a station hosts on its station). */
export function openTaskTarget(task: {
  conversationId: string;
  groupId: string;
  workspaceId: string;
}) {
  return {
    params: {
      conversationId: task.conversationId,
      groupId: task.groupId,
      workspaceId: task.workspaceId,
    },
    to: "/tasks/$workspaceId/$groupId/$conversationId",
  } as const;
}
