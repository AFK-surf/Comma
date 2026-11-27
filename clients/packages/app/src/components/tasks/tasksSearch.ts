import { readTaskLoopRuleKey } from "@comma/core/task-loop-filter";
import { visibleTaskStatusBuckets } from "@comma/i18n";
import type { TaskView } from "@comma/ui/components/task-board";
import { isTaskLoopFilterKey, type TaskLoopFilterKey } from "./taskLoopLabels";

/** The query fields that a link to Tasks can carry. */
export interface TasksSearch {
  label?: string;
  platform?: string;
  status?: string;
  clientPlatform?: string;
  /** `loop`, from links made before the Loop types, selects every Loop type. */
  schedule?: TaskLoopFilterKey | "loop";
  loopRule?: string;
  /** A person whose request Tasks came from (`requestPersonKey`). */
  request?: string;
  /** Initial Tasks surface view (`feed`, `list`, or `board`). */
  view?: TaskView;
}

const VIEWS: readonly TaskView[] = ["feed", "list", "board"];
const taskViewStorageKey = "comma.tasks.view";

/** The view that the user last chose on this device. */
export function readStoredTaskView(): TaskView | undefined {
  try {
    const stored = globalThis.localStorage?.getItem(taskViewStorageKey);
    return VIEWS.find((view) => view === stored);
  } catch {
    return undefined;
  }
}

export function storeTaskView(view: TaskView) {
  try {
    globalThis.localStorage?.setItem(taskViewStorageKey, view);
  } catch {
    // Browser storage is best effort; the open page keeps its view.
  }
}
const STATUSES: readonly string[] = visibleTaskStatusBuckets;
const CLIENT_PLATFORMS = [
  "macos",
  "windows",
  "linux",
  "ios",
  "android",
  "web",
  "unknown",
];

/**
 * Task properties and chips link to a label, origin, status, client platform,
 * Loop trigger type (`schedule`), Loop trigger rule (`loopRule`) or the person
 * a request came from (`request`). Drop unsupported query fields and unknown
 * values. A rule link takes the key form of the loaded Tasks, so another
 * spelling of the same cron matches.
 */
export function validateTasksSearch(search: Record<string, unknown>): TasksSearch {
  const {
    label,
    platform,
    status,
    clientPlatform,
    schedule,
    loopRule: rule,
    request,
    view,
  } = search;
  const loopRule = readTaskLoopRuleKey(rule);
  return {
    ...(typeof label === "string" && label ? { label } : {}),
    ...(typeof platform === "string" && platform ? { platform } : {}),
    ...(typeof status === "string" && STATUSES.includes(status) ? { status } : {}),
    ...(typeof clientPlatform === "string" && CLIENT_PLATFORMS.includes(clientPlatform)
      ? { clientPlatform }
      : {}),
    ...(isTaskLoopFilterKey(schedule) || schedule === "loop" ? { schedule } : {}),
    ...(loopRule ? { loopRule } : {}),
    ...(typeof request === "string" && request.startsWith("from:") ? { request } : {}),
    ...(typeof view === "string" && VIEWS.includes(view as TaskView)
      ? { view: view as TaskView }
      : {}),
  };
}
