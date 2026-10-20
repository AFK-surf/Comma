import type { TaskLoop } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  CalendarIcon,
  CircleCheckIcon,
  CircleDashedIcon,
  CircleXIcon,
  EyeIcon,
  InfinityIcon,
  PauseIcon,
} from "@comma/ui/components/icons";
import {
  taskLoopLabel,
  taskLoopPausedLabel,
  taskLoopTriggerText,
} from "./taskLoopLabels";

/** One row of a Loop's details, the same in Properties and in the card preview. */
export interface TaskLoopDetail {
  key: "cadence" | "active" | "pending" | "paused" | "ended";
  Icon: typeof CalendarIcon;
  text: string;
  /** The hover text, when it says more than `text`. */
  title?: string | undefined;
  /** An ended Loop reads muted. A paused Loop shows its pause glyph in the warning colour. */
  tone?: "muted" | "warning" | undefined;
}

/**
 * Properties and card previews show the trigger type, then the trigger and
 * any inactive state. There is always at least one row. An ended Loop keeps
 * its type and shows only Ended.
 */
export function useTaskLoopDetails(loop: TaskLoop): {
  label: string;
  details: TaskLoopDetail[];
} {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const label = taskLoopLabel(loop, messages);
  if (loop.state === "ended")
    return {
      label,
      details: [
        {
          key: "ended",
          Icon:
            loop.reason === "cancelled" || loop.reason === "failed"
              ? CircleXIcon
              : CircleCheckIcon,
          text: messages.task_loop_ended(),
          tone: "muted",
        },
      ],
    };
  const { cadence } = loop;
  const details: TaskLoopDetail[] = [];
  if (cadence)
    details.push({
      key: "cadence",
      Icon: cadence.events === undefined ? CalendarIcon : EyeIcon,
      ...taskLoopTriggerText(cadence, messages, locale),
    });
  if (loop.state === "pending")
    details.push({
      key: "pending",
      Icon: CircleDashedIcon,
      text: messages.task_loop_pending(),
    });
  else if (loop.state === "paused")
    details.push({
      key: "paused",
      Icon: PauseIcon,
      text: taskLoopPausedLabel(loop, messages) ?? messages.task_loop_paused(),
      tone: "warning",
    });
  // An active Loop whose rule this client cannot read still says that it runs.
  else if (!cadence)
    details.push({
      key: "active",
      Icon: InfinityIcon,
      text: messages.task_loop_active(),
    });
  return { label, details };
}
