import { HomeTasks, type TaskStatusBucket } from "@comma/ui";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { memo, useCallback, useEffect, useRef, useState } from "react";
import { useChatApi } from "../chat/ChatProvider";
import { useOpenTasksFilter } from "../tasks/taskChips";
import { useTaskBadges } from "../tasks/useTaskBadges";
import { useTaskOrder } from "../tasks/useTaskOrder";
import { useWorkspaceTasks, type TaskViewModel } from "../tasks/useWorkspaceTasks";

/** Ignore auto-follow for a beat after the user picks a status themselves. */
const MANUAL_SELECTION_HOLD_MS = 8_000;
/**
 * Which bucket the rail falls back to when the one it is showing empties.
 * Work in flight outranks an archive: the freshest Task is often the one that
 * just finished, and opening Home on "done" hides the ones still running.
 */
const FOLLOW_PRIORITY: readonly TaskStatusBucket[] = [
  "in_progress",
  "needs_review",
  "backlog",
  "done",
  "cancelled",
];
const EMPTY_TASKS: readonly TaskViewModel[] = [];

/**
 * Keeps the Home Tasks surface stable before Workspace Chat has resolved,
 * without starting the product-inbox projection against a session that may
 * still be mounting or tearing down.
 */
export function HomeTasksRailLoading() {
  return (
    <HomeTasks<TaskViewModel>
      onOpenTask={() => undefined}
      onStatusChange={() => undefined}
      ready={false}
      status="backlog"
      tasks={EMPTY_TASKS}
    />
  );
}

/**
 * Comma home Tasks rail: the componentized task stack bound to the
 * status-indicator switcher. Follows the same product-inbox projection as the
 * Tasks panel, so tasks created through the Comma Router agent appear here too;
 * when one arrives live, the rail switches to its status bucket so the new
 * card's entrance is visible.
 */
// Memoized: the Home screen that mounts this rail re-renders on every chat
// emit — each composer keystroke included — and re-creates the rail's element.
// The rail's own subscriptions decide when it renders; a keystroke is not one.
export const HomeTasksRail = memo(function HomeTasksRail({
  enabled = true,
}: {
  enabled?: boolean;
} = {}) {
  const navigate = useNavigate();
  const search = useSearch({ strict: false }) as {
    meetingTask?: string;
    meetingGroup?: string;
  };
  const api = useChatApi();
  const { activeGroupId, activeWorkspaceId, loading, result, taskLoadError, tasks } =
    useWorkspaceTasks({
      enabled,
      includeTask:
        search.meetingTask && search.meetingGroup
          ? { conversationId: search.meetingTask, groupId: search.meetingGroup }
          : undefined,
    });
  const { orders, setBucketOrder } = useTaskOrder(api, activeGroupId, tasks);
  // The Tasks board's label and platform chips, so a card reads the same here.
  const openTasksFilter = useOpenTasksFilter();
  const { renderTaskBadges } = useTaskBadges(
    api,
    activeGroupId,
    tasks,
    openTasksFilter
  );
  const [status, setStatus] = useState<TaskStatusBucket>("backlog");
  const manualAtRef = useRef(0);
  /** True while the visible status is the user's own pick, not the rail's. */
  const manualStatusRef = useRef(false);
  const knownIdsRef = useRef<Set<string> | null>(null);
  const knownWorkspaceRef = useRef(activeWorkspaceId);
  const requestedMeetingRef = useRef<string | undefined>(undefined);

  const handleStatusChange = useCallback((bucket: TaskStatusBucket) => {
    manualAtRef.current = Date.now();
    manualStatusRef.current = true;
    setStatus(bucket);
  }, []);

  useEffect(() => {
    // Auto-follow reacts to tasks that arrive live, never to a list that was
    // merely (re)loaded — so rebaseline whenever the source resets: loading
    // gaps, workspace switches, and error results whose recovery would
    // otherwise replay the whole list as "new arrivals". The workspace key
    // comes from the result snapshot so it stays consistent with `tasks` even
    // when the projection swaps workspaces before local state catches up.
    const workspaceKey = result?.activeWorkspaceId ?? activeWorkspaceId;
    if (workspaceKey !== knownWorkspaceRef.current) {
      knownWorkspaceRef.current = workspaceKey;
      knownIdsRef.current = null;
      manualStatusRef.current = false;
    }
    if (loading) {
      knownIdsRef.current = null;
      return;
    }
    if (result?.source === "error" || result?.source === "unavailable") {
      knownIdsRef.current = null;
      return;
    }

    const ids = new Set(tasks.map((task) => task.id));
    const known = knownIdsRef.current;
    knownIdsRef.current = ids;

    let arrived: TaskViewModel | undefined;
    if (known !== null) {
      for (const task of tasks) {
        if (known.has(task.id)) continue;
        if (!arrived || task.updatedAt > arrived.updatedAt) arrived = task;
      }
    }
    const requestedMeeting = `${search.meetingGroup ?? ""}:${search.meetingTask ?? ""}`;
    if (requestedMeetingRef.current !== requestedMeeting) {
      requestedMeetingRef.current = requestedMeeting;
      manualStatusRef.current = false;
    }
    const selectedMeeting = tasks.find(
      (task) =>
        task.conversationId === search.meetingTask &&
        task.groupId === search.meetingGroup
    );
    if (selectedMeeting && !manualStatusRef.current) {
      setStatus(selectedMeeting.statusBucket);
      return;
    }
    if (arrived) {
      if (Date.now() - manualAtRef.current < MANUAL_SELECTION_HOLD_MS) return;
      manualStatusRef.current = false;
      setStatus(arrived.statusBucket);
      return;
    }

    // Nothing arrived, so the rail is showing a status nobody asked for. A
    // Task leaves its bucket the moment its status moves on — a created Task
    // is `active` and turns into `ready_for_review` minutes later — and the
    // first list a rail ever receives is adopted as a baseline without a
    // follow. Either way the rail would sit on an empty bucket claiming "No
    // tasks" while Tasks exist. Follow the Tasks that are still moving; a
    // status the user picked themselves is theirs to keep.
    if (manualStatusRef.current || tasks.length === 0) return;
    if (tasks.some((task) => task.statusBucket === status)) return;

    let target = tasks[0]!;
    for (const task of tasks) {
      const rank = FOLLOW_PRIORITY.indexOf(task.statusBucket);
      const best = FOLLOW_PRIORITY.indexOf(target.statusBucket);
      if (rank < best || (rank === best && task.updatedAt > target.updatedAt)) {
        target = task;
      }
    }
    setStatus(target.statusBucket);
  }, [
    activeWorkspaceId,
    loading,
    result,
    status,
    tasks,
    search.meetingTask,
    search.meetingGroup,
  ]);

  const openTask = useCallback(
    (task: TaskViewModel) => {
      void navigate({
        params: {
          conversationId: task.conversationId,
          groupId: task.groupId,
          workspaceId: task.workspaceId,
        },
        to: "/tasks/$workspaceId/$groupId/$conversationId",
      });
    },
    [navigate]
  );

  return (
    <HomeTasks
      onOpenTask={openTask}
      onStatusChange={handleStatusChange}
      onTaskOrderChange={setBucketOrder}
      ready={!loading && taskLoadError === undefined}
      renderTaskBadges={renderTaskBadges}
      status={status}
      taskOrder={
        search.meetingTask &&
        tasks.some(
          (task) =>
            task.conversationId === search.meetingTask &&
            task.groupId === search.meetingGroup
        )
          ? {
              ...orders,
              [status]: [
                ...tasks
                  .filter(
                    (task) =>
                      task.conversationId === search.meetingTask &&
                      task.groupId === search.meetingGroup
                  )
                  .map((task) => task.id),
                ...(orders[status] ?? []).filter(
                  (id) =>
                    !tasks.some(
                      (task) =>
                        task.id === id &&
                        task.conversationId === search.meetingTask &&
                        task.groupId === search.meetingGroup
                    )
                ),
              ],
            }
          : orders
      }
      tasks={tasks}
    />
  );
});
