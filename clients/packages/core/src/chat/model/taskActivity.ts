import type {
  ChatMessage,
  ChatMessageMilestones,
  ChatTaskActivity,
  ChatTaskActivityEntry,
  ChatTaskActivityGroup,
} from "@comma/chat-contract";

const MILESTONE = "milestone";

/** An Agent message's milestones, as the server normalized its `milestone` blocks. */
export function milestonesOfBlocks(
  blocks: readonly unknown[]
): ChatMessageMilestones | undefined {
  const titles = blocks.flatMap((block) =>
    isObject(block) &&
    block.type === MILESTONE &&
    typeof block.title === "string" &&
    block.title.trim() !== ""
      ? [block.title]
      : []
  );
  if (titles.length === 0) return undefined;
  return {
    titles,
    standalone: blocks.every((block) => isObject(block) && block.type === MILESTONE),
  };
}

/**
 * What a Task's Activity reads of a message: a Salix Task's `ChatMessage`, or a station-hosted Task's entry read as one
 * (`stations/chat.ts`).
 */
export type TaskActivityMessage = Pick<
  ChatMessage,
  | "actorId"
  | "actorType"
  | "brief"
  | "createdAt"
  | "display"
  | "messageId"
  | "milestones"
  | "role"
  | "routerRequest"
  | "seq"
  | "source"
  | "text"
>;

/** Whether a transcript shows the message: one that only records milestones is shown nowhere but the Activity. */
export function shownInTranscript(message: Pick<ChatMessage, "milestones">): boolean {
  return message.milestones?.standalone !== true;
}

const transcripts = new WeakMap<readonly ChatMessage[], ChatMessage[]>();

/** The messages a transcript shows; the same list while it holds no milestone-only message, and the same answer per list. */
export function transcriptMessages(messages: ChatMessage[]): ChatMessage[] {
  if (messages.every(shownInTranscript)) return messages;
  let shown = transcripts.get(messages);
  if (!shown) {
    shown = messages.filter(shownInTranscript);
    transcripts.set(messages, shown);
  }
  return shown;
}

const merged = new WeakMap<
  readonly ChatMessage[],
  { history: readonly ChatMessage[]; messages: readonly ChatMessage[] }
>();

/**
 * The messages a Task's Activity reads: the history read for it before the transcript (`activityHistory`), then the
 * transcript. A message the transcript holds too is read from the transcript. The same list per pair.
 */
export function withActivityHistory(
  history: readonly ChatMessage[] | undefined,
  messages: readonly ChatMessage[]
): readonly ChatMessage[] {
  if (!history || history.length === 0) return messages;
  const held = merged.get(messages);
  if (held?.history === history) return held.messages;
  const first = messages.find((message) => message.seq !== undefined)?.seq;
  const older =
    first === undefined
      ? history
      : history.filter((message) => message.seq !== undefined && message.seq < first);
  const all = older.length === 0 ? messages : [...older, ...messages];
  merged.set(messages, { history, messages: all });
  return all;
}

/** A Loop Task's run: the seq and time of the wake that began it. */
export type TaskLoopRun = { seq: number; at?: number | undefined };

const NO_RUNS: readonly TaskLoopRun[] = [];

/** The Loop runs a page of raw messages proves, added to those held: ordered by seq, the same list while the page adds none. */
export function withLoopRuns(
  held: readonly TaskLoopRun[],
  raw: readonly { [key: string]: unknown }[]
): readonly TaskLoopRun[] {
  let runs: TaskLoopRun[] | undefined;
  let seen: Set<number> | undefined;
  for (const message of raw) {
    if (!loopWake(message)) continue;
    const seq = message.seq;
    if (typeof seq !== "number" || !Number.isSafeInteger(seq)) continue;
    seen ??= new Set(held.map((run) => run.seq));
    if (seen.has(seq)) continue;
    seen.add(seq);
    runs ??= [...held];
    runs.push({
      seq,
      ...(typeof message.created_at === "number" ? { at: message.created_at } : {}),
    });
  }
  return runs ? runs.toSorted((left, right) => left.seq - right.seq) : held;
}

/**
 * A Loop's wake: the system Message that hands the Worker a run, its input from the Loop
 * (`agent_input.trusted_origin.provider` is `loop`).
 */
function loopWake(message: { [key: string]: unknown }) {
  if (message.actor_type !== "system" || !isObject(message.agent_input)) return false;
  const origin = message.agent_input.trusted_origin;
  return isObject(origin) && origin.provider === "loop";
}

const activities = new WeakMap<
  readonly TaskActivityMessage[],
  { runs: readonly TaskLoopRun[]; activity: ChatTaskActivity | undefined }
>();

/**
 * A Task's Activity: its milestones in order, grouped under what each followed: the brief, a person's later message,
 * a request the Router handed in, or a Loop run. A milestone opens the result its Agent showed next, before the next group, else the last message
 * shown before it. A group with no milestone is left out, except the brief. Undefined while the Task has no
 * milestone. Read once per message and run list.
 */
export function taskActivity(
  messages: readonly TaskActivityMessage[],
  runs: readonly TaskLoopRun[] = NO_RUNS
): ChatTaskActivity | undefined {
  const held = activities.get(messages);
  if (held?.runs === runs) return held.activity;
  const activity = readActivity(messages, runs);
  activities.set(messages, { runs, activity });
  return activity;
}

/**
 * The Activity with where reading the Task's earlier history stands (`ChatTaskActivity.earlier`): what is not read yet
 * shows even before any milestone is.
 */
export function withEarlier(
  activity: ChatTaskActivity | undefined,
  earlier: ChatTaskActivity["earlier"]
): ChatTaskActivity | undefined {
  if (!earlier) return activity;
  return {
    key: `${earlier}:${activity?.key ?? ""}`,
    groups: activity?.groups ?? [],
    earlier,
  };
}

type Awaiting = { entry: ChatTaskActivityEntry; author: string | undefined };

function readActivity(
  messages: readonly TaskActivityMessage[],
  runs: readonly TaskLoopRun[]
): ChatTaskActivity | undefined {
  const groups: ChatTaskActivityGroup[] = [];
  let current: ChatTaskActivityGroup | undefined;
  let lastShown: string | undefined;
  // Milestones whose Agent has not shown their result yet.
  let awaiting: Awaiting[] = [];
  let nextRun = 0;
  let any = false;
  for (const message of messages) {
    const shown = shownInTranscript(message);
    // The latest wake before this message began the run it belongs to.
    let run: TaskLoopRun | undefined;
    while (
      message.seq !== undefined &&
      nextRun < runs.length &&
      runs[nextRun]!.seq < message.seq
    ) {
      run = runs[nextRun++];
    }
    const request =
      requestOf(message) ??
      (run ? { kind: "run" as const, text: "", ...atOf(run.at) } : undefined);
    if (request) {
      current = { request, entries: [] };
      groups.push(current);
      awaiting = [];
    }
    if (shown) {
      awaiting = awaiting.filter(({ entry, author }) => {
        if (message.actorType !== "agent" || message.actorId !== author) return true;
        entry.messageId = message.messageId;
        return false;
      });
      lastShown = message.messageId;
    }
    if (!message.milestones) continue;
    if (!current) {
      current = { entries: [] };
      groups.push(current);
    }
    for (const title of message.milestones.titles) {
      const entry: ChatTaskActivityEntry = {
        title,
        ...atOf(message.createdAt),
        ...(lastShown === undefined ? {} : { messageId: lastShown }),
      };
      current.entries.push(entry);
      if (!shown) awaiting.push({ entry, author: message.actorId });
      any = true;
    }
  }
  if (!any) return undefined;
  const kept = groups.filter(
    (group) => group.entries.length > 0 || group.request?.kind === "brief"
  );
  return { key: JSON.stringify(kept), groups: kept };
}

function requestOf(message: TaskActivityMessage): ChatTaskActivityGroup["request"] {
  if (message.brief)
    return {
      messageId: message.messageId,
      kind: "brief",
      text: "",
      ...atOf(message.createdAt),
    };
  if (
    !message.routerRequest &&
    (message.role !== "user" || message.source !== "server")
  )
    return undefined;
  const words = message.display?.body ?? message.text;
  const text = words
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line !== "");
  return {
    messageId: message.messageId,
    kind: "follow_up",
    text: text ?? "",
    ...atOf(message.createdAt),
  };
}

function atOf(at: number | undefined) {
  return at === undefined ? {} : { at };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
