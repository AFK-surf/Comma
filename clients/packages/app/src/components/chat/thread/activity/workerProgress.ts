import {
  sessionRecordStartTime,
  type SessionHistoryEntry,
} from "../../session-history/model/sessionHistoryEntries";
import {
  sessionDataObject,
  sessionRecordData,
  sessionToolCalls,
} from "../../session-history/model/sessionHistoryPresentation";

/** Finished steps that a Worker's log lists before the step in progress. */
export const MAX_WORKER_STEPS = 8;

/** What a step did, in the reader's terms rather than the tool's name. */
export type WorkerStepKind =
  | "thinking"
  | "command"
  | "read"
  | "write"
  | "edit"
  | "delete"
  | "browse"
  | "organize"
  | "search"
  | "update"
  | "other";

export type WorkerStep = {
  id: string;
  /** When the step started, if the record says. */
  at: number | undefined;
  kind: WorkerStepKind;
  /** The words the Worker wrote for people, or a file name or a query. */
  detail?: string | undefined;
  failed?: boolean | undefined;
};

export type WorkerProgress = {
  /** At most MAX_WORKER_STEPS finished steps, oldest first. */
  steps: readonly WorkerStep[];
  current: WorkerStep | undefined;
};

const TOOL_KINDS: Readonly<Record<string, WorkerStepKind>> = {
  "env.exec": "command",
  bash: "command",
  exec_command: "command",
  read: "read",
  read_file: "read",
  "fs.read_file": "read",
  write: "write",
  write_file: "write",
  "fs.write_file": "write",
  edit: "edit",
  apply_patch: "edit",
  "fs.edit_file": "edit",
  "fs.delete_file": "delete",
  "fs.list_files": "browse",
  "fs.copy_file": "organize",
  "env.copy": "organize",
  "fs.move_file": "organize",
  "fs.grep": "search",
  "fs.glob": "search",
  "memory.search": "search",
  "im_api.internal.send_message": "update",
};

/**
 * A Worker's recent steps in reader terms: what it did and what it does now.
 * Model requests, tokens, timing, raw arguments and tool names are debug data
 * and stay in the Session history panel. A tool without reader words is not
 * listed; while it runs, the card only says the Worker is working.
 *
 * Only the owner's live overlay says that work runs now. A durable running
 * receipt or a request without a result may outlive an interruption, so its
 * outcome stays unknown: it is neither a finished step nor the current one.
 */
export function workerProgress(
  entries: readonly SessionHistoryEntry[]
): WorkerProgress {
  const steps: WorkerStep[] = [];
  let current: WorkerStep | undefined;
  for (const entry of entries) {
    const at = sessionRecordStartTime(entry.record) ?? undefined;
    const execution = entry.record.execution;
    const live = execution?.live === true && execution.completed_at_ms == null;
    if (entry.tool) {
      const tool = entry.item.tools[0];
      if (!tool) continue;
      const kind = TOOL_KINDS[tool] ?? "other";
      const step: WorkerStep = {
        id: entry.id,
        at,
        kind,
        detail: stepDetail(kind, entryArguments(entry)),
        failed: entry.item.kind === "error",
      };
      if (live) current = step;
      else if (
        kind !== "other" &&
        entry.item.kind !== "running" &&
        entry.item.kind !== "call"
      )
        steps.push(step);
      continue;
    }
    if (live && execution.lane === "model")
      current = { id: entry.id, at, kind: "thinking" };
  }
  return { steps: steps.slice(-MAX_WORKER_STEPS), current };
}

/**
 * The one step a Task row shows: a step in progress that the Worker described,
 * else the last finished step, else whatever runs now.
 */
export function latestWorkerStep(progress: WorkerProgress): WorkerStep | undefined {
  const { current, steps } = progress;
  if (current?.kind === "command" && current.detail) return current;
  return steps.at(-1) ?? current;
}

// The call's arguments, with the result's echo filling what the call lacks.
export function entryArguments(entry: SessionHistoryEntry): Record<string, unknown> {
  const callId = entry.id.startsWith("tool:") ? entry.id.slice("tool:".length) : "";
  let echoed: Record<string, unknown> = {};
  let called: Record<string, unknown> = {};
  for (const record of entry.debugRecords) {
    if (record.kind === "assistant") {
      const call = sessionToolCalls(sessionDataObject(record.content).tool_calls).find(
        (candidate) => candidate.id === callId
      );
      if (call) called = call.args;
      continue;
    }
    const data = sessionRecordData(record);
    const input = sessionDataObject(
      data.input ?? data.arguments ?? sessionDataObject(data.result).input
    );
    if (Object.keys(input).length) echoed = input;
  }
  return { ...echoed, ...called };
}

// A string, or the text of content blocks, on one line.
function words(value: unknown): string {
  const text = Array.isArray(value)
    ? value
        .map((block) => sessionDataObject(block).text)
        .filter((part): part is string => typeof part === "string")
        .join(" ")
    : value;
  return typeof text === "string" ? text.replace(/\s+/g, " ").trim() : "";
}

// Only words written for people: a command's description, a message body, a
// search query, or a file name. Never a raw command or a full path.
function stepDetail(
  kind: WorkerStepKind,
  args: Record<string, unknown>
): string | undefined {
  switch (kind) {
    case "command":
      return words(args.description) || undefined;
    case "update":
      return words(args.content ?? args.text ?? args.message) || undefined;
    case "search":
      return words(args.query ?? args.pattern) || undefined;
    case "read":
    case "write":
    case "edit":
    case "delete":
      return (
        words(args.path ?? sessionDataObject(args.file_ref).path)
          .split("/")
          .filter(Boolean)
          .at(-1) || undefined
      );
    default:
      return undefined;
  }
}
