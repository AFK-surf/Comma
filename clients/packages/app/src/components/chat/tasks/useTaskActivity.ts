import type { ChatTaskActivity } from "@comma/chat-contract";
import { useMemo } from "react";

/**
 * The Task's Activity as one object while its steps hold. Each snapshot from
 * the core carries a new copy; the details panel renders only when a step
 * changes, not on every message.
 */
export function useTaskActivity(activity: ChatTaskActivity | undefined) {
  // eslint-disable-next-line react-hooks/exhaustive-deps -- `key` is the activity's value.
  return useMemo(() => activity, [activity?.key]);
}
