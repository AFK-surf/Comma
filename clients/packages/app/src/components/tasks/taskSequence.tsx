import { useNavigate, useRouterState } from "@tanstack/react-router";
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { openTaskTarget } from "./openTaskTarget";

/** One stop in a Task sequence: the conversation a detail page shows. */
export interface TaskSequenceEntry {
  conversationId: string;
  groupId: string;
  workspaceId: string;
}

/** The list a Task page steps through with its up and down buttons. */
export interface TaskSequence {
  entries: readonly TaskSequenceEntry[];
  open: (index: number) => void;
}

declare module "@tanstack/history" {
  interface HistoryState {
    /**
     * The Tasks page's cards as the reader saw them when they opened this
     * Task, in reading order. Kept in the history entry, so Back and Forward
     * return to a Task with the same neighbours.
     */
    taskSequence?: readonly TaskSequenceEntry[];
  }
}

export function taskSequenceEntry(task: TaskSequenceEntry): TaskSequenceEntry {
  return {
    conversationId: task.conversationId,
    groupId: task.groupId,
    workspaceId: task.workspaceId,
  };
}

/**
 * A list shown beside the detail page (the Inbox rail) publishes its live
 * order here. A store, not context state, so a reorder re-renders only the
 * navigator and never the conversation under it.
 */
class TaskSequenceSource {
  private sequence: TaskSequence | undefined;
  private readonly listeners = new Set<() => void>();

  get = () => this.sequence;

  set(sequence: TaskSequence | undefined) {
    this.sequence = sequence;
    for (const listener of this.listeners) listener();
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
}

const TaskSequenceSourceContext = createContext<TaskSequenceSource | undefined>(
  undefined
);

export function TaskSequenceSourceProvider({ children }: { children: ReactNode }) {
  const [source] = useState(() => new TaskSequenceSource());
  return (
    <TaskSequenceSourceContext.Provider value={source}>
      {children}
    </TaskSequenceSourceContext.Provider>
  );
}

export function usePublishTaskSequence(sequence: TaskSequence | undefined) {
  const source = useContext(TaskSequenceSourceContext);
  useEffect(() => {
    if (!source) return undefined;
    source.set(sequence);
    return () => source.set(undefined);
  }, [sequence, source]);
}

const noSource = new TaskSequenceSource();

/**
 * The sequence the current Task page belongs to: the live list beside it, or
 * else the Tasks page order it was opened from. `undefined` for a Task opened
 * anywhere else.
 */
export function useTaskSequence(): TaskSequence | undefined {
  const source = useContext(TaskSequenceSourceContext) ?? noSource;
  const live = useSyncExternalStore(source.subscribe, source.get);
  const opened = useRouterState({
    select: (state) => state.location.state.taskSequence,
  });
  const navigate = useNavigate();
  return useMemo(
    () =>
      live ??
      (opened
        ? {
            entries: opened,
            open: (index: number) => {
              const entry = opened[index];
              if (!entry) return;
              void navigate({
                ...openTaskTarget(entry),
                replace: true,
                state: { taskSequence: opened },
              });
            },
          }
        : undefined),
    [live, navigate, opened]
  );
}
