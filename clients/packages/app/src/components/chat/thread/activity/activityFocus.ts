import type { TaskStatusBucket } from "@comma/i18n";
import {
  asksRouter,
  conversationMessageTurnKey,
  type ChatMessage,
  type ChatParticipantStatus,
} from "@comma/core/chat";

/**
 * A chat surface follows at most this many Task Participant feeds. Each feed is
 * one long-poll request, so a Router with many Tasks costs two requests, not
 * one per Task.
 */
export const MAX_FOCUS_TASK_FEEDS = 2;

/**
 * - `following`: the Router answers input from these Tasks, such as Worker reports.
 * - `waiting`: the Router waits, and the current turn delegated these Tasks.
 * - `working`: the Router is idle, and Workers run Tasks that this chat created.
 */
export type ActivityFocusMode = "following" | "waiting" | "working";

export type ActivityFocusTaskRef = {
  conversationId: string;
  statusBucket?: TaskStatusBucket | undefined;
  title?: string | undefined;
  /**
   * The turn of the person's last request to the Router before this chat
   * announced the Task, when there was one. A Quick Chat's own Task has the
   * Quick Chat's turn: the Quick Chat is the request it answers.
   */
  requestTurnKey?: string | undefined;
  updatedAt?: number | undefined;
};

export type ActivityFocusTarget = {
  mode: ActivityFocusMode;
  /** Every Task the state names, in display order. */
  tasks: readonly ActivityFocusTaskRef[];
};

export type ActivityFocusWorker = {
  /** Stable avatar identity: the public actor ID, else the Participant ID. */
  avatarId: string;
  name: string;
  participantId: string;
  /** Working now. A waiting or stopped Worker is not active. */
  active: boolean;
  /** Stopped with an error: the Router still waits, but nobody works on the Task. */
  failed?: boolean | undefined;
  /** The maker of the model it runs (`comma` for Comma's own), whose mark stands for it. */
  vendor?: string | undefined;
};

export type ActivityFocusTask = ActivityFocusTaskRef & {
  /** `null`: the Task's feed answered and has no Worker. Absent: not known yet. */
  worker?: ActivityFocusWorker | null | undefined;
};

export type ActivityFocus = {
  groupId: string;
  mode: ActivityFocusMode;
  tasks: readonly ActivityFocusTask[];
};

/** The turn the Router answers: the person's last message to it, a Quick Chat included. */
export function focusTurnKey(messages: readonly ChatMessage[]): string | undefined {
  const request = messages.findLast(asksRouter);
  return request && conversationMessageTurnKey(request);
}

/**
 * What the chat's reply slot can say about Task work, from facts the surface
 * already has: the Router's canonical status and the Tasks this chat created.
 * It never infers a Task from timing.
 */
export function selectActivityFocusTarget({
  createdTasks,
  currentTurnKey,
  participantStatus,
}: {
  createdTasks: readonly ActivityFocusTaskRef[];
  currentTurnKey: string | undefined;
  participantStatus: ChatParticipantStatus | undefined;
}): ActivityFocusTarget | undefined {
  if (participantStatus?.state === "active" && participantStatus.loopWake !== true) {
    const ids = participantStatus.workingConversationIds;
    if (ids?.length) {
      const known = new Map(createdTasks.map((task) => [task.conversationId, task]));
      return {
        mode: "following",
        tasks: ids.map((id) => known.get(id) ?? { conversationId: id }),
      };
    }
    if (participantStatus.waiting) {
      return {
        mode: "waiting",
        tasks:
          currentTurnKey === undefined
            ? []
            : createdTasks.filter(
                (task) =>
                  task.statusBucket === "in_progress" &&
                  task.requestTurnKey === currentTurnKey
              ),
      };
    }
    return undefined;
  }
  // An error notice owns the slot; a Loop wake is the Router's own background
  // work. Otherwise an idle Router leaves the slot to its running Tasks.
  if (participantStatus?.state === "error") return undefined;
  const running = createdTasks.filter((task) => task.statusBucket === "in_progress");
  return running.length
    ? { mode: "working", tasks: running.slice(-MAX_FOCUS_TASK_FEEDS) }
    : undefined;
}

/** The Tasks whose Participant feeds the surface follows. */
export function focusFeedIds(target: ActivityFocusTarget | undefined): string[] {
  return (target?.tasks ?? [])
    .slice(0, MAX_FOCUS_TASK_FEEDS)
    .map((task) => task.conversationId);
}

/**
 * Join a target with resolved titles and followed Workers. A `working` state
 * shows only Tasks whose Worker works now: an idle Router with a waiting or
 * stopped Worker leaves the slot empty.
 */
export function resolveActivityFocus(
  target: ActivityFocusTarget | undefined,
  facts: {
    groupId: string;
    titles: ReadonlyMap<
      string,
      Omit<ActivityFocusTaskRef, "conversationId" | "requestTurnKey">
    >;
    workers: ReadonlyMap<string, ActivityFocusWorker | null>;
  }
): ActivityFocus | undefined {
  if (!target) return undefined;
  const tasks = target.tasks.map((task): ActivityFocusTask => {
    const known = facts.titles.get(task.conversationId);
    return {
      ...task,
      statusBucket: task.statusBucket ?? known?.statusBucket,
      title: task.title || known?.title || undefined,
      updatedAt: task.updatedAt ?? known?.updatedAt,
      worker: facts.workers.get(task.conversationId),
    };
  });
  if (target.mode !== "working")
    return { groupId: facts.groupId, mode: target.mode, tasks };
  const working = tasks.filter((task) => task.worker?.active === true);
  return working.length
    ? { groupId: facts.groupId, mode: "working", tasks: working }
    : undefined;
}
