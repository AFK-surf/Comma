/** Where opening a Task goes: its station's page for a Task a station hosts (`station:<station>:<thread>`), else its conversation. */
export function openTaskTarget(task: {
  conversationId: string;
  groupId: string;
  workspaceId: string;
}) {
  const hosted = /^station:([^:]+):(.+)$/.exec(task.conversationId);
  if (hosted)
    return {
      params: {
        station: hosted[1]!,
        thread: hosted[2]!,
        workspaceId: task.workspaceId,
      },
      to: "/tasks/$workspaceId/station/$station/$thread",
    } as const;
  return {
    params: {
      conversationId: task.conversationId,
      groupId: task.groupId,
      workspaceId: task.workspaceId,
    },
    to: "/tasks/$workspaceId/$groupId/$conversationId",
  } as const;
}
