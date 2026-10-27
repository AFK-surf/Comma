import type { ChatTaskRunChoice } from "@comma/chat-contract";
import type { ChatTaskRun } from "@comma/core/chat";
import { createContext } from "react";

/**
 * A Task chat whose viewer may run the Task on another model: where it runs now, which `task_run_blocked` message is
 * the one that stands (`taskRunBlocked`), and the switch. Absent outside such a chat; the transcript then draws a
 * blocked message as its words.
 */
export type TaskRunSwitch = {
  blockedMessageId: string | undefined;
  run: ChatTaskRun | undefined;
  switchRun: (run: ChatTaskRunChoice) => Promise<unknown>;
  workspaceId: string;
};

export const TaskRunSwitchContext = createContext<TaskRunSwitch | undefined>(undefined);

/** The message a Task's computer writes when its model cannot start (`SalixWeb.StationTasks`). */
export const TASK_RUN_BLOCKED = "task_run_blocked";
