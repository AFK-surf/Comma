import { useCommaMessages } from "@comma/i18n/react";
import {
  getNativeBridge,
  type NotchHostEvent,
  type NotchTaskItem,
} from "@comma/native-bridge";
import { useNavigate } from "@tanstack/react-router";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { useChatProductLease } from "../chat/ChatProvider";
import { MAX_FOCUS_TASK_FEEDS } from "../chat/thread/activity/activityFocus";
import { useTaskParticipantFeeds } from "../chat/thread/activity/useActivityFocus";
import { useWorkerSteps } from "../chat/thread/activity/useWorkerSteps";
import { TaskStepsContext } from "./taskSteps";
import { useWorkspaceTasks, type TaskViewModel } from "./useWorkspaceTasks";

/**
 * The Notch and the Task cards follow the Workers of at most this many running
 * Tasks, the most recently updated first. Each costs one Participant feed and
 * one Session history stream, as in the chat's activity card; other Tasks say
 * "In progress".
 */
const MAX_NOTCH_STEP_FEEDS = MAX_FOCUS_TASK_FEEDS;

/**
 * The Notch lists at most this many running Tasks, the most recently updated
 * first; the native contract takes 100, and Main adds its own sends to these.
 */
export const MAX_NOTCH_TASKS = 20;

// The native contract allows 2048 characters; one truncated line shows far fewer.
const MAX_STEP_LENGTH = 200;

const NO_STEPS: ReadonlyMap<string, string> = new Map();
const noSubscription = () => () => undefined;

/**
 * Owns the desktop task-to-Notch projection for the authenticated session.
 * The Swift host receives only in-progress tasks, so an empty projection can
 * unambiguously collapse and hide the native surface. A followed Task's line
 * under its title shows its Worker's latest step, as the chat's activity card
 * does, and falls back to "In progress". The same steps reach the Home Tasks
 * rail and the Tasks board through TaskStepsContext; on the web, where no
 * Notch shows, Workers are followed only while one of those lists is shown.
 */
export function NotchTaskSync() {
  const bridge = getNativeBridge();
  const isDesktop = bridge.platform === "electron";
  const messages = useCommaMessages();
  const navigate = useNavigate();
  // This authenticated-session owner retains the same projection for Web and
  // Electron. Only the native Notch side effect remains Electron-specific.
  const { tasks } = useWorkspaceTasks({ enabled: true });
  const runningTasks = useMemo(
    () => toNotchTaskItems(tasks, messages.tasks_in_progress()),
    [messages, tasks]
  );
  // An active Loop waits between runs: the Notch never lists it, but its Worker is followed so that the Task
  // cards show a run while it executes.
  const loopTasks = useMemo(
    () => toNotchLoopTaskItems(tasks, messages.tasks_in_progress()),
    [messages, tasks]
  );
  const taskSteps = useContext(TaskStepsContext);
  const watched = useSyncExternalStore(
    taskSteps?.subscribe ?? noSubscription,
    () => taskSteps?.watched() ?? false
  );
  const followed = useMemo(
    () => (isDesktop || watched ? notchStepFeedTasks(runningTasks, loopTasks) : []),
    [isDesktop, loopTasks, runningTasks, watched]
  );
  const [steps, setSteps] = useState(NO_STEPS);
  const reportStep = useCallback((taskId: string, words: string | undefined) => {
    setSteps((current) => {
      if (current.get(taskId) === words) return current;
      const next = new Map(current);
      if (words) next.set(taskId, words);
      else next.delete(taskId);
      return next;
    });
  }, []);
  useEffect(() => taskSteps?.publish(steps), [steps, taskSteps]);
  const notchTasks = useMemo(
    () => withWorkerSteps(runningTasks, steps),
    [runningTasks, steps]
  );
  const tasksRef = useRef(notchTasks);
  tasksRef.current = notchTasks;
  // A Notch that takes no scene is said once, not at every change of the list.
  const warned = useRef(false);

  useEffect(() => {
    if (!isDesktop) return;

    void bridge.notch
      .update({
        dismissTaskLabel: messages.notch_task_dismiss(),
        hasActivity: notchTasks.length > 0,
        listSubtitle: messages.notch_tasks_subtitle(),
        listTitle: messages.notch_tasks_title(),
        openChatLabel: messages.inbox_open_chat(),
        tasks: notchTasks,
      })
      .catch((error: unknown) => {
        if (warned.current) return;
        warned.current = true;
        console.warn("The Notch did not take the Tasks.", error);
      });
  }, [bridge, isDesktop, messages, notchTasks]);

  useEffect(() => {
    if (!isDesktop) return;

    return bridge.notch.onEvent((event) => {
      handleNotchTaskOpen(event, tasksRef.current, {
        close: () => void bridge.notch.close().catch(() => undefined),
        focusMainWindow: () =>
          void bridge.windows.focus({ windowId: "win_main" }).catch(() => undefined),
        navigate: (task) => {
          void navigate({
            params: {
              conversationId: task.conversationId,
              groupId: task.groupId,
              workspaceId: task.workspaceId,
            },
            to: "/inbox/$workspaceId/$groupId/$conversationId",
          });
        },
      });
    });
  }, [bridge, isDesktop, navigate]);

  useEffect(
    () => () => {
      if (!isDesktop) return;
      void bridge.notch.hide().catch(() => undefined);
    },
    [bridge, isDesktop]
  );

  return (
    <>
      {followed.map((task) => (
        <NotchTaskStepFeed
          key={task.id}
          task={task}
          onStep={reportStep}
          whileWorking={task.loop === true}
        />
      ))}
    </>
  );
}

type ReportStep = (taskId: string, words: string | undefined) => void;

/** Follows one running Task's Worker and reports its latest step. */
function NotchTaskStepFeed({
  task,
  onStep,
  whileWorking,
}: {
  task: NotchTaskItem;
  onStep: ReportStep;
  whileWorking: boolean;
}) {
  const productLease = useChatProductLease();
  const ids = useMemo(() => [task.conversationId], [task.conversationId]);
  const worker = useTaskParticipantFeeds(task.groupId, ids).get(task.conversationId);
  if (!worker || !productLease) return null;
  return (
    <NotchWorkerStep
      taskId={task.id}
      groupId={task.groupId}
      conversationId={task.conversationId}
      participantId={worker.participantId}
      onStep={onStep}
      whileWorking={whileWorking}
    />
  );
}

function NotchWorkerStep({
  taskId,
  groupId,
  conversationId,
  participantId,
  onStep,
  whileWorking,
}: {
  taskId: string;
  groupId: string;
  conversationId: string;
  participantId: string;
  onStep: ReportStep;
  /** A Loop's last step stays in its history between runs: it counts only while the Worker works. */
  whileWorking: boolean;
}) {
  const history = useMemo(
    () => ({ groupId, conversationId, participantId }),
    [groupId, conversationId, participantId]
  );
  const view = useWorkerSteps(history);
  const words = whileWorking && !view.working ? undefined : view.shown?.words;
  useEffect(() => onStep(taskId, words), [onStep, taskId, words]);
  useEffect(() => () => onStep(taskId, undefined), [onStep, taskId]);
  return null;
}

const newestFirst = (left: NotchTaskItem, right: NotchTaskItem) =>
  right.updatedAt - left.updatedAt;

/**
 * The Tasks whose Workers the Notch follows: running Tasks first, then active
 * Loops waiting for a run, each the newest first.
 */
export function notchStepFeedTasks(
  tasks: readonly NotchTaskItem[],
  loops: readonly LoopNotchTaskItem[] = []
): LoopNotchTaskItem[] {
  return [...tasks.toSorted(newestFirst), ...loops.toSorted(newestFirst)].slice(
    0,
    MAX_NOTCH_STEP_FEEDS
  );
}

/** A Task whose Worker the Notch follows; `loop` marks an active Loop, followed only for the Task cards. */
export type LoopNotchTaskItem = NotchTaskItem & { loop?: true };

/** Puts each followed Worker's latest step under its Task's title. */
export function withWorkerSteps(
  tasks: NotchTaskItem[],
  steps: ReadonlyMap<string, string>
): NotchTaskItem[] {
  if (steps.size === 0) return tasks;
  return tasks.map((task) => {
    const words = steps.get(task.id);
    return words ? { ...task, subtitle: words.slice(0, MAX_STEP_LENGTH) } : task;
  });
}

interface NotchTaskOpenActions {
  close: () => void;
  focusMainWindow: () => void;
  navigate: (task: NotchTaskItem) => void;
}

export function handleNotchTaskOpen(
  event: NotchHostEvent,
  tasks: readonly NotchTaskItem[],
  actions: NotchTaskOpenActions
) {
  if (event.type !== "action" || event.payload?.action !== "task:open") {
    return false;
  }

  const task = tasks.find((item) => item.id === event.payload?.value);
  if (!task) return false;

  actions.close();
  actions.focusMainWindow();
  actions.navigate(task);
  return true;
}

/** The running Tasks the Notch lists: the newest MAX_NOTCH_TASKS, newest first. */
export function toNotchTaskItems(
  tasks: readonly TaskViewModel[],
  inProgressLabel: string
): NotchTaskItem[] {
  return notchItems(
    tasks.filter((task) => task.statusBucket === "in_progress"),
    inProgressLabel
  );
}

/** The active Loops (not paused and not setting up), which run from time to time: the newest MAX_NOTCH_TASKS. */
export function toNotchLoopTaskItems(
  tasks: readonly TaskViewModel[],
  inProgressLabel: string
): LoopNotchTaskItem[] {
  return notchItems(
    tasks.filter(
      (task) =>
        task.statusBucket === "loops" &&
        task.loopStop === undefined &&
        task.loop?.state === "active"
    ),
    inProgressLabel
  ).map((task) => ({ ...task, loop: true as const }));
}

function notchItems(
  tasks: readonly TaskViewModel[],
  inProgressLabel: string
): NotchTaskItem[] {
  return tasks
    .toSorted((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, MAX_NOTCH_TASKS)
    .map((task) => ({
      conversationId: task.conversationId,
      groupId: task.groupId,
      id: task.id,
      ...(task.runStartedAt === undefined ? {} : { runStartedAt: task.runStartedAt }),
      status: "in_progress",
      subtitle: inProgressLabel,
      title: task.title,
      updatedAt: task.updatedAt,
      workspaceId: task.workspaceId,
    }));
}
