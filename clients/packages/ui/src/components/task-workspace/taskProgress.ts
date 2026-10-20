import { createContext, useContext, useSyncExternalStore } from "react";

/**
 * What running Tasks do now, by Task id, such as each followed Worker's
 * latest step. The app owns the source; a Task card reads only its own entry,
 * so a new step re-renders only the card it belongs to.
 */
export interface TaskProgressSource {
  subscribe(listener: () => void): () => void;
  progressOf(taskId: string): string | undefined;
}

export const TaskProgressContext = createContext<TaskProgressSource | undefined>(
  undefined
);

const noSubscription = () => () => undefined;

/** The Task's live progress words, if the app follows its Worker. */
export function useTaskProgress(taskId: string): string | undefined {
  const source = useContext(TaskProgressContext);
  return useSyncExternalStore(source?.subscribe ?? noSubscription, () =>
    source?.progressOf(taskId)
  );
}
