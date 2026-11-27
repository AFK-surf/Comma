import { taskStatusBucket } from "@comma/i18n";
import { useMemo } from "react";
import { useTopic } from "@comma/core-client";
import { useTaskSummariesState } from "../../../tasks/useTaskArchive";
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
const NO_MESSAGES: readonly ChatMessage[] = [];
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
  // A view that follows no Task (a Task view, a retained Home not shown) reads
  // no Task rows, so their changes do not render it.
  const createdTasks = useChatCreatedTasks({
    groupId,
    messages: enabled ? messages : NO_MESSAGES,
  });
  const currentTurnKey = useMemo(() => focusTurnKey(messages), [messages]);
  // Tasks the Router follows are often outside this chat's own references.
  // Their status is read before the target, so a Task that ended is never
  // followed and never takes one of the feeds.
  const followingIds = useMemo(() => {
    const ids =
      enabled &&
      participantStatus?.state === "active" &&
      participantStatus.loopWake !== true
        ? participantStatus.workingConversationIds
        : undefined;
    if (!ids?.length) return NO_IDS;
    const named = new Set(
      createdTasks.filter((task) => task.title).map((task) => task.conversationId)
    );
    return ids.filter((id) => !named.has(id));
  }, [createdTasks, enabled, participantStatus]);
  const { titles, settled } = useTaskTitles(groupId, followingIds);
  const target = useMemo(
    () =>
      enabled
        ? selectActivityFocusTarget({
            createdTasks,
            currentTurnKey,
            participantStatus,
            resolvedTasks: titles,
          })
        : undefined,
    [createdTasks, currentTurnKey, enabled, participantStatus, titles]
  );
  // Until the core says how the followed Tasks stand, follow only the feeds of
  // Tasks known to run: a Task that ended never takes one.
  const feedIds = focusFeedIds(
    target && !settled
      ? { ...target, tasks: target.tasks.filter((task) => task.statusBucket) }
      : target
  );
  const workers = useTaskParticipantFeeds(groupId, feedIds);
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
 * knows them: the list's facts, else the account's summary lane. `settled`:
 * the core answered for every id.
 */
function useTaskTitles(
  groupId: string,
  ids: readonly string[]
): {
  titles: ReadonlyMap<
    string,
    Omit<ActivityFocusTaskRef, "conversationId" | "requestTurnKey">
  >;
  settled: boolean;
} {
  const { summaries, settled } = useTaskSummariesState(groupId, ids);
  const titles = useMemo(() => {
    const known = new Map<
      string,
      Omit<ActivityFocusTaskRef, "conversationId" | "requestTurnKey">
    >();
    for (const id of ids) {
      const summary = summaries.get(id);
      // A Task without a title still says whether it ended.
      if (summary)
        known.set(id, {
          statusBucket: taskStatusBucket(summary.status, {
            loopState: summary.loop?.state,
          }),
          ...(summary.title ? { title: summary.title } : {}),
        });
    }
    return known;
  }, [ids, summaries]);
  return { titles, settled };
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
