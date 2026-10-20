import { useTopic, type TaskConversationValue } from "@comma/core-client";
import { useRef } from "react";
import { normalizeUnixTimestampMs } from "./normalizeUnixTimestampMs";

export type TaskConversationPreviewTarget = {
  conversationId: string;
  groupId: string;
  status?: string;
  title: string;
  updatedAt?: number;
  workspaceId: string;
};

/** The task as it is now: a newer update or another status is read again. */
function taskVersion(task: TaskConversationPreviewTarget) {
  const normalizedUpdatedAt = normalizeUnixTimestampMs(task.updatedAt) ?? "unknown";
  return `${normalizedUpdatedAt}\u0000${task.status?.trim().toLowerCase() ?? ""}`;
}

/**
 * A task's conversation as the core keeps it for a preview (the last `messageLimit` messages, or all): it reads it
 * when shown and keeps it a while (`taskConversation`); each new `read` (a retry) asks again after a failure.
 */
export function useTaskConversation(
  task: TaskConversationPreviewTarget,
  messageLimit: number | undefined,
  read: number
): TaskConversationValue | undefined {
  const { value } = useTopic({
    topic: "taskConversation",
    group: task.groupId,
    conversation: task.conversationId,
    limit: messageLimit === undefined ? "" : String(messageLimit),
    version: taskVersion(task),
    status: task.status ?? "",
    read: String(read),
  });
  // A newer version or a retry is another topic: until the core answers it, the same Task's last answer stays shown.
  const last = useRef<{ key: string; value: TaskConversationValue } | undefined>(
    undefined
  );
  const key = `${task.groupId}\u0000${task.conversationId}\u0000${messageLimit ?? ""}`;
  if (value) last.current = { key, value };
  if (value) return value;
  return last.current?.key === key
    ? { ...last.current.value, status: "loading" }
    : undefined;
}
