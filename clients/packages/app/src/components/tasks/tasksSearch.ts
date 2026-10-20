import { readTaskLoopRuleKey } from "@comma/core/task-loop-filter";
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
}

const STATUSES = ["in_progress", "needs_review", "done", "cancelled"];
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
 * Loop trigger type (`schedule`) or Loop trigger rule (`loopRule`). Drop
 * unsupported query fields and unknown values. A rule link takes the key form
 * of the loaded Tasks, so another spelling of the same cron matches.
 */
export function validateTasksSearch(search: Record<string, unknown>): TasksSearch {
  const { label, platform, status, clientPlatform, schedule, loopRule: rule } = search;
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
  };
}
