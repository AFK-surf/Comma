import { taskStatusBucket } from "@comma/i18n";
import { useMemo } from "react";
import { useTopic } from "@comma/core-client";
import { useTaskSummaries } from "../../../tasks/useTaskArchive";
import type { ChatMessage, ChatParticipantStatus } from "@comma/core/chat";
import { useChatCreatedTasks } from "../../tasks/useChatCreatedTasks";
import {
  focusFeedIds,
  focusTurnKey,
  MAX_FOCUS_TASK_FEEDS,
  resolveActivityFocus,
  selectActivityFocusTarget,
  type ActivityFocus,
  type ActivityFocusTaskRef,
  type ActivityFocusWorker,
} from "./activityFocus";

const NO_IDS: readonly string[] = [];
const NO_WORKERS: ReadonlyMap<string, ActivityFocusWorker | null> = new Map();

/**
 * What the reply slot can say about Task work in a chat (Home).
 * Task conversations show their own Participants instead, so they pass
 * `enabled: false` and open no feeds.
 */
export function useActivityFocus({
  enabled,
  groupId,
  messages,
  participantStatus,
}: {
  enabled: boolean;
  groupId: string;
  messages: readonly ChatMessage[];
  participantStatus: ChatParticipantStatus | undefined;
}): ActivityFocus | undefined {
  const createdTasks = useChatCreatedTasks({ groupId, messages });
  const currentTurnKey = useMemo(() => focusTurnKey(messages), [messages]);
  const target = useMemo(
    () =>
      enabled
        ? selectActivityFocusTarget({ createdTasks, currentTurnKey, participantStatus })
        : undefined,
    [createdTasks, currentTurnKey, enabled, participantStatus]
  );
  // Tasks the Router follows are often outside this chat's own references.
  const unnamed = useMemo(
    () =>
      target?.tasks.filter((task) => !task.title).map((task) => task.conversationId) ??
      NO_IDS,
    [target]
  );
  const titles = useTaskTitles(groupId, unnamed);
  const workers = useTaskParticipantFeeds(groupId, focusFeedIds(target));
  const focus = useMemo(
    () => resolveActivityFocus(target, { groupId, titles, workers }),
    [groupId, target, titles, workers]
  );
  // Status events arrive often. Keep one object while the focus is the same.
  const signature = JSON.stringify(focus ?? null);
  return (
    useMemo(() => JSON.parse(signature) as ActivityFocus | null, [signature]) ??
    undefined
  );
}

/**
 * Titles and status for Tasks that this chat did not reference, as the core
 * knows them: the list's facts, else the account's summary lane.
 */
function useTaskTitles(
  groupId: string,
  ids: readonly string[]
): ReadonlyMap<
  string,
  Omit<ActivityFocusTaskRef, "conversationId" | "requestTurnKey">
> {
  const summaries = useTaskSummaries(groupId, ids);
  return useMemo(() => {
    const titles = new Map<
      string,
      Omit<ActivityFocusTaskRef, "conversationId" | "requestTurnKey">
    >();
    for (const id of ids) {
      const summary = summaries.get(id);
      if (summary?.title)
        titles.set(id, {
          title: summary.title,
          statusBucket: taskStatusBucket(summary.status),
        });
    }
    return titles;
  }, [ids, summaries]);
}

/**
 * The bound Worker of at most MAX_FOCUS_TASK_FEEDS Tasks, from the same Task
 * Participant feed that a Task view uses, as the core follows it. The core
 * keeps the last snapshot through reconnects; a Task that leaves the focus
 * closes its feed.
 */
export function useTaskParticipantFeeds(
  groupId: string,
  ids: readonly string[]
): ReadonlyMap<string, ActivityFocusWorker | null> {
  const key = ids.slice(0, MAX_FOCUS_TASK_FEEDS).join(",");
  const { value } = useTopic(
    groupId && key ? { topic: "taskWorkers", group: groupId, ids: key } : null,
    { lingerMs: 0 }
  );
  return useMemo(() => (value ? new Map(Object.entries(value)) : NO_WORKERS), [value]);
}
