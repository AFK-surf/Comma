import type { ChatMessage, ChatTaskRun } from "@comma/core/chat";

/** A sandbox in one of these states runs nothing until someone restarts it. */
const SANDBOX_DOWN = new Set(["stopped", "lost", "failed", "ended"]);

/**
 * Whether a Task reads as started although nobody in it reports work yet: the
 * client's own word for the gap between the Task's brief and its Worker's
 * first report, so a new Task does not look idle. It holds while the Task is
 * in progress and its newest message is still an instruction for the Worker
 * to start from (its brief, or a request the Router brought into the Task
 * from elsewhere, such as Home), or while its sandbox is starting. The
 * Worker's own status, its first message, a person's message and a sandbox
 * that is down each end it.
 */
export function workerStarting({
  inProgress,
  messages,
  place,
}: {
  /** The Task is in progress and no Loop paces its work. */
  inProgress: boolean;
  messages: readonly Pick<ChatMessage, "brief" | "routerRequest">[];
  place: ChatTaskRun["place"] | undefined;
}): boolean {
  if (!inProgress) return false;
  if (place?.kind === "sandbox") {
    if (place.state === "starting") return true;
    if (SANDBOX_DOWN.has(place.state)) return false;
  }
  const newest = messages.at(-1);
  return newest?.brief === true || newest?.routerRequest === true;
}
