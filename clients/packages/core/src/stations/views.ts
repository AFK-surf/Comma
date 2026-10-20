// What the Stations area shows of each station's chats and jobs, worked out from what the stations answered: a chat's
// row (the state of its agents, the question waiting, whether it is done), the days the chats fall on, the cards and
// questions waiting for the viewer, and the jobs that have run long. Nothing here reads the network or the clock: the
// time and the viewer are given.
import { DateTime } from "effect";
import type {
  StationAgentState,
  StationCardShown,
  StationChatDay,
  StationChatItem,
  StationDecision,
  StationDecisionMessage,
  StationLongJob,
} from "../contract.ts";
import type {
  StationAgent,
  StationCard,
  StationChatRow,
  StationJob,
  StationMessage,
} from "./station-api.ts";

/** A station as these views name it, and whether it is reached now. */
export interface StationNamed {
  id: string;
  name: string;
  online: boolean;
}

/** Who looks: their email (as stations know them). */
export interface Viewer {
  email: string;
}

const LONG_JOB_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

type Mark = "run" | "block" | "failed" | null;

/** An agent's state from its station's summary. */
export function agentState(agent: StationAgent): StationAgentState {
  const turn = agent.lastTurn;
  const ending = turn?.ending ?? endingOf(turn?.declared ?? null);
  const watching = agent.watch !== undefined && agent.watch !== null;
  if (agent.process === "running") return { status: "running" };
  if (agent.pending > 0) return { status: "queued" };
  if (!turn) return { status: "idle" };
  if (turn.endedAt === null && !turn.outcome) return { status: "running" };
  if (ending === "all_done")
    return turn.need ? { status: "done", detail: turn.need } : { status: "done" };
  if (ending === "need_help" || ending === "need_decision")
    return turn.need
      ? { status: "needs_you", detail: turn.need }
      : { status: "needs_you" };
  if (ending === "waiting") {
    if (watching) return { status: "watching" };
    return turn.waitFor
      ? { status: "waiting", detail: turn.waitFor }
      : { status: "waiting" };
  }
  if (turn.outcome === "failed")
    return { status: "failed", failure: failureOf(turn.detail) };
  if (turn.outcome === "aborted") return { status: "stopped" };
  return { status: "stopped_unexpectedly" };
}

/** The words agents used before endings had names. */
function endingOf(declared: string | null): string | undefined {
  if (declared === "final") return "all_done";
  if (declared === "block") return "need_help";
  if (declared === "waiting") return "waiting";
  return undefined;
}

function failureOf(detail: string | null): NonNullable<StationAgentState["failure"]> {
  const d = detail ?? "";
  if (d.startsWith("rate_limit")) return "rate_limit";
  if (d.startsWith("auth")) return "auth";
  if (d.startsWith("model")) return "model";
  if (d.startsWith("exited")) return "exited";
  return "other";
}

function markOf(state: StationAgentState): Mark {
  switch (state.status) {
    case "running":
    case "queued":
      return "run";
    case "needs_you":
      return "block";
    case "failed":
    case "stopped_unexpectedly":
      return "failed";
    default:
      return null;
  }
}

/** The card or question a row has waiting, if any (a card first). */
function askedOf(row: StationChatRow): {
  seq: number;
  message: StationMessage;
  before: StationMessage[];
  dismissed: boolean;
  card: StationCard;
} | null {
  if (row.card)
    return { ...row.card, dismissed: row.card.dismissed === true, card: row.card.card };
  if (row.decision)
    return {
      ...row.decision,
      dismissed: row.decision.dismissed === true,
      card: { type: "options", options: row.decision.options ?? [] },
    };
  return null;
}

/** A message's first line, as a list shows it: no markup at its start, no emphasis marks. */
export function firstLine(text: string | null): string {
  const line =
    (text ?? "")
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l !== "") ?? "";
  return line
    .replace(/\*\*|__|`/g, "")
    .replace(/^[#>\-*\s]+/, "")
    .trim();
}

/** A message on one line: Slack mentions dropped, spaces collapsed. */
function oneLine(text: string | null): string {
  return (text ?? "")
    .replace(/<@[A-Z0-9]+>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** One chat's row. */
export function chatItem(row: StationChatRow, station: StationNamed): StationChatItem {
  const states = row.agents.map(agentState);
  const marks = states.map(markOf);
  const mark: Mark = marks.includes("block")
    ? "block"
    : marks.includes("run")
      ? "run"
      : marks.includes("failed")
        ? "failed"
        : null;
  const asked = askedOf(row);
  const cardWaiting = asked !== null && !asked.dismissed;
  const tone =
    mark === "failed"
      ? "alert"
      : cardWaiting || mark === "block"
        ? "wait"
        : mark === "run"
          ? "busy"
          : row.unread
            ? "done"
            : null;
  const allDone =
    states.length > 0 && states.every((s) => s.status === "done") && !cardWaiting;
  const settled = allDone && !row.unread;
  return {
    id: row.id,
    station: station.id,
    stationName: station.name,
    stationOnline: station.online,
    thread: row.thread,
    title: row.title,
    unread: row.unread,
    settled,
    tone,
    line: lineOf(states, asked && cardWaiting ? asked : null, settled),
    preview: row.last ? oneLine(row.last.text) : null,
  };
}

/** What the row says under its title, in order: an agent stuck, a card waiting, an agent at work or waiting. */
function lineOf(
  states: StationAgentState[],
  asked: { message: StationMessage } | null,
  settled: boolean
): StationChatItem["line"] {
  const atWork = states.some((s) => s.status === "running" || s.status === "queued");
  const decision = asked
    ? ({ kind: "decision", text: firstLine(asked.message.text) } as const)
    : null;
  if (!atWork) {
    const blocked = states.find((s) => s.status === "needs_you");
    if (blocked)
      return decision && !blocked.detail ? decision : { kind: "agent", state: blocked };
    const broken = states.find(
      (s) =>
        s.status === "failed" ||
        s.status === "stopped_unexpectedly" ||
        s.status === "stopped"
    );
    if (broken) return { kind: "agent", state: broken };
  }
  if (decision) return decision;
  if (atWork) return null;
  const waiting = states.find((s) => s.status === "waiting" || s.status === "watching");
  if (waiting) return { kind: "agent", state: waiting };
  if (!settled) return null;
  const said = states.find((s) => s.status === "done" && s.detail);
  return said ? { kind: "agent", state: said } : { kind: "done" };
}

/** Calendar parts of `ms` in `zone` (this device's time zone). */
function calendar(ms: number, zone: DateTime.TimeZone) {
  const date = DateTime.toParts(DateTime.makeZonedUnsafe(ms, { timeZone: zone }));
  return {
    key: Date.UTC(date.year, date.month - 1, date.day),
    weekday: date.weekDay,
    month: date.month,
    day: date.day,
  };
}

/** Chats by the day of their last activity, newest day first; pinned ones in a group before them. */
export function chatDays(
  rows: { row: StationChatRow; item: StationChatItem }[],
  now: number
): StationChatDay[] {
  const zone = DateTime.zoneMakeLocal();
  const today = calendar(now, zone).key;
  const pinned = rows
    .filter(({ row }) => typeof row.pinned === "number")
    .toSorted(
      (a, b) =>
        (b.row.pinned ?? 0) - (a.row.pinned ?? 0) ||
        b.row.lastActiveAt - a.row.lastActiveAt
    );
  const days: StationChatDay[] = [];
  if (pinned.length > 0) {
    const at = calendar(now, zone);
    days.push({
      daysAgo: -1,
      weekday: at.weekday,
      month: at.month,
      day: at.day,
      pinned: true,
      items: pinned.map(({ item }) => item),
    });
  }
  const byDay = new Map<number, { row: StationChatRow; item: StationChatItem }[]>();
  for (const entry of rows) {
    if (typeof entry.row.pinned === "number") continue;
    const key = calendar(entry.row.lastActiveAt, zone).key;
    let list = byDay.get(key);
    if (!list) byDay.set(key, (list = []));
    list.push(entry);
  }
  for (const [key, list] of [...byDay].toSorted(([a], [b]) => b - a)) {
    const at = calendar(list[0]!.row.lastActiveAt, zone);
    days.push({
      daysAgo: Math.round((today - key) / DAY_MS),
      weekday: at.weekday,
      month: at.month,
      day: at.day,
      pinned: false,
      items: list
        .toSorted(
          (a, b) =>
            Number(a.item.settled) - Number(b.item.settled) ||
            b.row.lastActiveAt - a.row.lastActiveAt
        )
        .map(({ item }) => item),
    });
  }
  return days;
}

function authorOf(message: StationMessage): string {
  return message.authorName || message.author || "";
}

function shownMessage(message: StationMessage): StationDecisionMessage {
  return { seq: message.seq, author: authorOf(message), text: message.text ?? "" };
}

/** A card as shown: labelled options, recommended ones last; who decides. */
export function cardShown(
  card: StationCard,
  row: StationChatRow,
  viewer: Viewer
): StationCardShown {
  const options = (card.options ?? [])
    .filter((o) => o.label.trim() !== "")
    .map((o) => ({
      label: o.label.trim(),
      ...(o.detail?.trim() ? { detail: o.detail.trim() } : {}),
      ...(o.recommended ? { recommended: true } : {}),
    }));
  const decider = card.assignee ?? row.creator?.email ?? row.creator?.id ?? null;
  return {
    type: card.type,
    ...(card.type === "options"
      ? {
          options: [
            ...options.filter((o) => !o.recommended),
            ...options.filter((o) => o.recommended),
          ],
        }
      : {}),
    ...(card.placeholder?.trim() ? { placeholder: card.placeholder.trim() } : {}),
    decider:
      decider === null
        ? { kind: "none" }
        : sameEmail(decider, viewer.email)
          ? { kind: "you" }
          : {
              kind: "other",
              name: !card.assignee && row.creator?.name ? row.creator.name : decider,
            },
  };
}

const sameEmail = (a: string, b: string) =>
  a.trim().toLowerCase() === b.trim().toLowerCase();

/** The card or question a row has waiting for `viewer`, as the Needs-you list shows it; null when none is. */
export function decisionOf(
  row: StationChatRow,
  station: StationNamed,
  viewer: Viewer,
  deferred: boolean
): StationDecision | null {
  if (row.thread === null) return null;
  const asked =
    askedOf(row) ??
    (row.need
      ? {
          ...row.need,
          dismissed: row.need.dismissed === true,
          card: { type: "text" } as StationCard,
        }
      : null);
  if (!asked || asked.dismissed) return null;
  const card = cardShown(asked.card, row, viewer);
  if (card.decider.kind !== "you") return null;
  return {
    station: station.id,
    stationName: station.name,
    session: row.id,
    thread: row.thread,
    seq: asked.seq,
    title: row.title,
    deferred,
    message: shownMessage(asked.message),
    before: asked.before.map(shownMessage),
    card,
  };
}

/** The message that answers a card quotes it: the station takes that as the answer to it. */
export function quoteOf(row: StationChatRow, seq: number) {
  const asked = askedOf(row) ?? (row.need ? { ...row.need } : null);
  if (!asked || asked.seq !== seq) return null;
  return {
    author: asked.message.authorName || "agent",
    text: asked.message.text ?? "",
    comment: "",
    role: "agent",
    ...(asked.message.ts ? { ts: asked.message.ts } : {}),
  };
}

/** The option of the card waiting at `seq`, when it has one so labelled. */
export function optionOf(row: StationChatRow, seq: number, label: string) {
  const asked = askedOf(row);
  if (!asked || asked.seq !== seq) return null;
  return asked.card.options?.find((o) => o.label.trim() === label) ?? null;
}

/** How long something has run, in its largest whole unit. */
function ageOf(ms: number): StationLongJob["age"] {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return { unit: "seconds", n: seconds };
  if (seconds < 3_600) return { unit: "minutes", n: Math.floor(seconds / 60) };
  if (seconds < 86_400) return { unit: "hours", n: Math.floor(seconds / 3_600) };
  return { unit: "days", n: Math.floor(seconds / 86_400) };
}

/** Jobs that have run an hour or more and are not watched by an agent: services first, then jobs, oldest first. */
export function longJobs(
  stations: { station: StationNamed; jobs: StationJob[] }[],
  now: number
): { kind: "services" | "jobs"; jobs: StationLongJob[] }[] {
  const named = stations.length > 1;
  const all = stations.flatMap(({ station, jobs }) =>
    jobs
      .filter((job) => !job.watch && now - job.startedAt >= LONG_JOB_MS)
      .map((job) => ({ job, station }))
  );
  all.sort((a, b) => a.job.startedAt - b.job.startedAt);
  const shown = (entry: {
    job: StationJob;
    station: StationNamed;
  }): StationLongJob => ({
    id: entry.job.id,
    name: entry.job.name,
    state: entry.job.state,
    station: entry.station.id,
    stationName: named ? entry.station.name : null,
    chat: entry.job.chat
      ? {
          title: entry.job.chat.title,
          archived: Boolean(entry.job.chat.archived),
        }
      : null,
    age: ageOf(now - entry.job.startedAt),
  });
  const services = all.filter(({ job }) => job.port !== null).map(shown);
  const jobs = all.filter(({ job }) => job.port === null).map(shown);
  return [
    ...(services.length > 0 ? [{ kind: "services" as const, jobs: services }] : []),
    ...(jobs.length > 0 ? [{ kind: "jobs" as const, jobs }] : []),
  ];
}
