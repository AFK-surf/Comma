import { useEffect, useRef, useState } from "react";
import { isReducedMotionEnabled, motionDuration } from "../../tokens";
import type { TaskSummaryViewModel } from "../task-workspace/TaskSummaryCard";
import type { TaskStatusBucket } from "../task-workspace/taskStatus";

export const HOME_TASKS_BUCKET_ORDER: readonly TaskStatusBucket[] = [
  "backlog",
  "in_progress",
  "needs_review",
  "done",
  "cancelled",
];

/** Cascade cap for cards arriving together; later ones share the last beat. */
export const HOME_TASKS_MAX_NEW_STAGGER = 8;

export type HomeTaskEntryState = "settled" | "new" | "leaving";

export interface HomeTaskEntry<T extends TaskSummaryViewModel = TaskSummaryViewModel> {
  state: HomeTaskEntryState;
  task: T;
}

export interface HomeTasksCurrentPanel<
  T extends TaskSummaryViewModel = TaskSummaryViewModel,
> {
  /** True when the panel was created by a switch and should slide in. */
  animate: boolean;
  bucket: TaskStatusBucket;
  entries: HomeTaskEntry<T>[];
  /** Monotonic panel identity; keys off it so a switch mounts a fresh panel. */
  stamp: number;
}

export interface HomeTasksOutgoingPanel<
  T extends TaskSummaryViewModel = TaskSummaryViewModel,
> {
  bucket: TaskStatusBucket;
  stamp: number;
  tasks: T[];
}

export interface HomeTasksDisplay<
  T extends TaskSummaryViewModel = TaskSummaryViewModel,
> {
  current: HomeTasksCurrentPanel<T>;
  direction: 1 | -1;
  outgoing: HomeTasksOutgoingPanel<T> | null;
}

function bucketTasks<T extends TaskSummaryViewModel>(
  tasks: readonly T[],
  bucket: TaskStatusBucket
): T[] {
  return tasks.filter((task) => task.statusBucket === bucket);
}

/**
 * Drives the home Tasks card stack as a strip of status pages. A switch keeps
 * BOTH panels on screen — the outgoing one slides toward the travel direction
 * while the incoming one slides in from the opposite side — so the motion
 * reads as one surface moving, never as a blink. Everything is driven by CSS
 * transitions on panel roles, so rapid indicator scrubbing retargets from the
 * panel's current position instead of replaying from zero.
 *
 * Within a stable panel, tasks appearing live pop in ("new"), and tasks whose
 * status moved on ghost out ("leaving"). A card is "new" if it has never been
 * rendered before — so a task created in another bucket still pops the first
 * time its column is shown.
 */
export function useHomeTasksDisplay<T extends TaskSummaryViewModel>(
  tasks: readonly T[],
  bucket: TaskStatusBucket,
  ready: boolean
): HomeTasksDisplay<T> {
  const [current, setCurrent] = useState<HomeTasksCurrentPanel<T>>(() => ({
    animate: false,
    bucket,
    entries: bucketTasks(tasks, bucket).map((task) => ({ state: "settled", task })),
    stamp: 0,
  }));
  const [outgoing, setOutgoing] = useState<HomeTasksOutgoingPanel<T> | null>(null);
  const [direction, setDirection] = useState<1 | -1>(1);
  const tasksRef = useRef(tasks);
  tasksRef.current = tasks;
  const filledRef = useRef(ready);
  /** Ids whose card has been rendered at least once (null until first fill). */
  const seenIdsRef = useRef<Set<string> | null>(
    ready ? new Set(tasks.map((t) => t.id)) : null
  );

  useEffect(() => {
    if (bucket === current.bucket) return;
    const from = HOME_TASKS_BUCKET_ORDER.indexOf(current.bucket);
    const to = HOME_TASKS_BUCKET_ORDER.indexOf(bucket);
    const reduced = isReducedMotionEnabled();
    setDirection(to >= from ? 1 : -1);

    const seen = seenIdsRef.current;
    const entries = bucketTasks(tasksRef.current, bucket).map((task) => {
      const isNew =
        !reduced && filledRef.current && seen !== null && !seen.has(task.id);
      if (seen) seen.add(task.id);
      return { state: isNew ? ("new" as const) : ("settled" as const), task };
    });

    setOutgoing(
      reduced
        ? null
        : {
            bucket: current.bucket,
            stamp: current.stamp,
            tasks: bucketTasks(tasksRef.current, current.bucket),
          }
    );
    setCurrent({
      animate: !reduced,
      bucket,
      entries,
      stamp: current.stamp + 1,
    });
  }, [bucket, current.bucket, current.stamp]);

  useEffect(() => {
    if (!outgoing) return undefined;
    const timer = window.setTimeout(
      () => setOutgoing(null),
      motionDuration.stateChange
    );
    return () => window.clearTimeout(timer);
  }, [outgoing]);

  useEffect(() => {
    // The data source went away (e.g. a workspace switch): what loads next is
    // a fresh default state, not a burst of live events.
    if (!ready) {
      filledRef.current = false;
      seenIdsRef.current = null;
    }
    if (bucket !== current.bucket) return;
    const next = bucketTasks(tasks, current.bucket);
    // The first fill after loading is the page's default state, not an event.
    const animateNew = filledRef.current;
    if (ready) filledRef.current = true;

    setCurrent((panel) => {
      if (panel.bucket !== bucket) return panel;
      const prevById = new Map(panel.entries.map((entry) => [entry.task.id, entry]));
      const nextIds = new Set(next.map((task) => task.id));

      const rebuilt: HomeTaskEntry<T>[] = next.map((task) => {
        const prev = prevById.get(task.id);
        if (!prev) return { state: animateNew ? "new" : "settled", task };
        return { state: prev.state === "leaving" ? "settled" : prev.state, task };
      });

      panel.entries.forEach((entry, index) => {
        if (nextIds.has(entry.task.id)) return;
        if (!animateNew) return;
        rebuilt.splice(Math.min(index, rebuilt.length), 0, {
          state: "leaving",
          task: entry.task,
        });
      });

      if (ready) {
        if (seenIdsRef.current === null) {
          seenIdsRef.current = new Set(tasks.map((task) => task.id));
        } else {
          for (const entry of rebuilt) seenIdsRef.current.add(entry.task.id);
        }
      }

      return sameEntries(panel.entries, rebuilt)
        ? panel
        : { ...panel, entries: rebuilt };
    });
  }, [tasks, bucket, current.bucket, ready]);

  useEffect(() => {
    if (!current.entries.some((entry) => entry.state === "leaving")) return undefined;
    const timer = window.setTimeout(
      () => {
        setCurrent((panel) => ({
          ...panel,
          entries: panel.entries.filter((entry) => entry.state !== "leaving"),
        }));
      },
      isReducedMotionEnabled() ? 0 : motionDuration.feedbackOut
    );
    return () => window.clearTimeout(timer);
  }, [current.entries]);

  // Once a "new" card's pop has finished, settle it so it rejoins the FLIP
  // glide for later insertions and removals. Cards arriving together cascade
  // (see home-tasks.css), so the settle waits for the last beat of the batch.
  useEffect(() => {
    const newCount = current.entries.filter((entry) => entry.state === "new").length;
    if (newCount === 0) return undefined;
    const cascade =
      Math.min(newCount - 1, HOME_TASKS_MAX_NEW_STAGGER) * motionDuration.revealStagger;
    const timer = window.setTimeout(
      () => {
        setCurrent((panel) => ({
          ...panel,
          entries: panel.entries.map((entry) =>
            entry.state === "new" ? { ...entry, state: "settled" } : entry
          ),
        }));
      },
      // Pop delay + duration + batch cascade, plus one extra beat so the
      // transition is guaranteed to have finished before its rules are removed.
      isReducedMotionEnabled()
        ? 0
        : motionDuration.iconSwap + 2 * motionDuration.submenuOpenDelay + cascade
    );
    return () => window.clearTimeout(timer);
  }, [current.entries]);

  return { current, direction, outgoing };
}

function sameEntries<T extends TaskSummaryViewModel>(
  a: readonly HomeTaskEntry<T>[],
  b: readonly HomeTaskEntry<T>[]
): boolean {
  if (a.length !== b.length) return false;
  return a.every(
    (entry, index) => entry.task === b[index]!.task && entry.state === b[index]!.state
  );
}
