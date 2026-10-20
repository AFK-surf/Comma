import {
  TaskProgressContext,
  type TaskProgressSource,
} from "@comma/ui/components/task-workspace";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

const NO_STEPS: ReadonlyMap<string, string> = new Map();

/**
 * The latest Worker step of each running Task that NotchTaskSync follows, by
 * Task id. The Notch, the Home Tasks rail, and the Tasks board read the same
 * steps, so a Task card costs no feed of its own. The owner follows Workers
 * while a surface watches: the Notch on desktop, or a card list on screen.
 */
export class TaskSteps implements TaskProgressSource {
  private steps = NO_STEPS;
  private watchers = 0;
  private listeners = new Set<() => void>();

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  progressOf = (taskId: string) => this.steps.get(taskId);

  watched = () => this.watchers > 0;

  /** Marks a card list on screen until the returned release runs. */
  watch = () => {
    this.watchers += 1;
    if (this.watchers === 1) this.notify();
    return () => {
      this.watchers -= 1;
      if (this.watchers === 0) this.notify();
    };
  };

  publish(steps: ReadonlyMap<string, string>) {
    if (steps === this.steps) return;
    this.steps = steps;
    this.notify();
  }

  private notify() {
    for (const listener of this.listeners) listener();
  }
}

export const TaskStepsContext = createContext<TaskSteps | undefined>(undefined);

/** One authenticated session's Task steps, for its owner and its card lists. */
export function TaskStepsProvider({ children }: { children: ReactNode }) {
  const [steps] = useState(() => new TaskSteps());
  return (
    <TaskStepsContext.Provider value={steps}>{children}</TaskStepsContext.Provider>
  );
}

/**
 * A card list that shows its running Tasks' Worker steps: the Home Tasks rail
 * or the Tasks board. While `active`, it keeps the Workers followed and gives
 * its cards the steps. Task cards elsewhere, such as in a chat, read none.
 */
export function TaskStepCards({
  active,
  children,
}: {
  active: boolean;
  children: ReactNode;
}) {
  const steps = useContext(TaskStepsContext);
  useEffect(() => (active && steps ? steps.watch() : undefined), [active, steps]);
  return (
    <TaskProgressContext.Provider value={active ? steps : undefined}>
      {children}
    </TaskProgressContext.Provider>
  );
}
