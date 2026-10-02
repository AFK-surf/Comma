import type {
  BftTriageAgent,
  BftTriageContext,
  BftTriageHeatmap,
  BftTriageItem,
  BftTriageKnowledge,
  BftTriageOutcome,
  BftTriageSource,
} from "./api";
import { messages } from "./messages";

/*
 * Slack triage presentation rules, kept apart from the pages so they can be
 * tested: what a source's switch may do, how an outcome reads, how a Timeline
 * page groups into threads, the heatmap grid and the Knowledge rows.
 */

const t = messages.triage;

/** `ok` and `warn` color the status dot; anything else stays neutral. */
export type Tone = "ok" | "warn" | undefined;

// ---- Agents and Slack sources ----

export const botName = (source: BftTriageSource) => source.bot_name ?? t.botUnnamed;

/** `@username · workspace` when the username differs from the public bot name. */
export function sourceMeta(source: BftTriageSource) {
  const workspace = source.workspace_name ?? t.workspaceUnknown;
  return source.bot_name &&
    source.bot_username &&
    source.bot_name !== source.bot_username
    ? `@${source.bot_username} · ${workspace}`
    : workspace;
}

export const sourceLabel = (source: BftTriageSource) =>
  t.sourceLabel(botName(source), source.workspace_name ?? t.workspaceUnknown);

/** The picker line of an Agent; the selected source comes first. */
export function agentSummary(agent: BftTriageAgent, selected?: string) {
  if (agent.state === "unavailable") return t.sourceStatusUnavailable;
  const [first, ...rest] = [
    ...agent.sources.filter((source) => source.connect_id === selected),
    ...agent.sources.filter((source) => source.connect_id !== selected),
  ];
  if (!first) return t.notConnected;
  const label = rest.length
    ? t.andMore(sourceLabel(first), rest.length)
    : sourceLabel(first);
  return agent.state === "partial" ? t.statusIncomplete(label) : label;
}

export const agentGroup = (agent: BftTriageAgent) =>
  agent.state === "ready"
    ? t.groupConnected
    : agent.state === "empty"
      ? t.groupNotConnected
      : t.groupIncomplete;

export function switchLabel(source: BftTriageSource) {
  if (source.enabled) return t.on;
  return !source.complete || !source.authority_valid ? t.unavailable : t.off;
}

/**
 * Turning monitoring off is always safe. Turning it on needs a complete,
 * valid source with at least one configured channel.
 */
export const canSwitch = (source: BftTriageSource) =>
  source.enabled ||
  (source.complete && source.authority_valid && source.channels.length > 0);

export const channelsEditable = (source: BftTriageSource) =>
  source.complete && source.channel_scope_complete === true && source.channel_controls;

/** Why a source's controls are limited, in display order. */
export function sourceNotices(source: BftTriageSource): string[] {
  if (!source.complete)
    return [source.enabled ? t.unreadableCanDisable : t.unreadableUntilReady];
  if (source.channel_scope_complete === false) return [t.channelsIncomplete];
  if (source.channel_controls) return [];
  if (!source.authority_valid)
    return [source.enabled ? t.needsAttention : t.cannotEnableYet];
  return [
    !source.enabled && source.channels.length === 0
      ? t.upgradeBlocksEnable
      : t.upgradeLater,
  ];
}

export const monitoringActive = (source: BftTriageSource) =>
  source.enabled && source.channels.some((channel) => channel.enabled);

/** `connect/channel` to `#name` for the Agent's configured channels. */
export function channelNames(agent: BftTriageAgent | undefined) {
  const names = new Map<string, string>();
  for (const source of agent?.sources ?? []) {
    for (const channel of source.channels) {
      names.set(
        `${source.connect_id}/${channel.id}`,
        channel.name ? `#${channel.name}` : channel.id
      );
    }
  }
  return names;
}

// ---- Outcomes ----

type Communication = BftTriageOutcome["communication"];
const kindOf = (item: BftTriageOutcome) => item.communication.kind;
const pending = (state: string | null | undefined) =>
  state === "pending" || state === "claimed";

export function outcomeTone(item: BftTriageOutcome): Tone {
  if (item.state === "failed" || item.companion?.state === "failed") return "warn";
  if (pending(item.companion?.state) || pending(item.state)) return undefined;
  if (item.state === "stale") return "warn";
  if (item.communication.reason === "worker_pending") return undefined;
  return kindOf(item) === "reply" || kindOf(item) === "reaction" ? "ok" : undefined;
}

export const outcomeInProgress = (item: BftTriageOutcome) =>
  pending(item.state) || pending(item.companion?.state);

export const outcomeFailed = (item: BftTriageOutcome) =>
  item.state === "failed" || item.companion?.state === "failed";

export function outcomeLabel(item: BftTriageOutcome): string {
  const { communication: c, effect, companion } = item;
  if (item.state === "failed") return t.outcome.failed;
  if (item.state === "stale") return t.outcome.suppressed;
  if (pending(item.state)) return t.outcome.settling;
  const replyStatus =
    effect.status === "queued"
      ? t.outcome.replyQueued
      : effect.status === "delivered"
        ? t.outcome.replyDelivered
        : undefined;
  if (item.state === "applied" && c.kind === "reply" && replyStatus && companion) {
    if (pending(companion.state))
      return `${replyStatus} · ${t.outcome.reactionInProgress}`;
    if (companion.state === "failed")
      return `${replyStatus} · ${t.outcome.reactionFailed}`;
  }
  if (effect.adapter === "audit_sink") {
    if (c.kind === "reply")
      return companion?.kind === "reaction"
        ? t.outcome.wouldReplyAndReact
        : t.outcome.wouldReply;
    if (c.kind === "reaction") return t.outcome.wouldReact;
  }
  if (c.kind === "reply")
    return companion?.kind === "reaction"
      ? t.outcome.replyAndReaction
      : (replyStatus ?? t.outcome.reply);
  if (c.kind === "reaction")
    return effect.status === "added" ? t.outcome.reactionAdded : t.outcome.reaction;
  if (c.kind === "silence")
    return c.reason === "worker_pending" ? t.outcome.assigned : t.outcome.silent;
  return t.outcome.unavailable;
}

const silenceReasons: Record<string, string> = t.silenceReasons;

export function outcomeBody(item: BftTriageOutcome): string {
  const c: Communication = item.communication;
  if (item.state === "stale" && c.text) return t.outcome.suppressedDraft(c.text);
  if (c.kind === "reply" && c.text) return c.text;
  if (c.kind === "reaction" && c.emoji) return `:${c.emoji}:`;
  if (c.kind === "silence") {
    if (c.explanation) return c.explanation;
    if (c.reason === "worker_pending") return t.outcome.assignedBody;
    return t.outcome.silenceBody(silenceReasons[c.reason ?? ""] ?? t.reasonUnavailable);
  }
  if (item.state === "failed") return t.outcome.failedBody;
  return t.outcome.unavailableBody;
}

const delegationStatuses = [
  "created",
  "routed",
  "proposed",
  "retry_scheduled",
  "suppressed_stale",
  "unavailable",
] as const;
type DelegationStatus = (typeof delegationStatuses)[number];

export const delegationStatus = (delegation: {
  status: string | null;
}): DelegationStatus =>
  (delegationStatuses as readonly string[]).includes(delegation.status ?? "")
    ? (delegation.status as DelegationStatus)
    : "unavailable";

export const delegationLabel = (delegation: { status: string | null; task: string }) =>
  t.delegation[delegationStatus(delegation)](delegation.task);

/** The effects line under a decision: context, worker tasks, reactions. */
export function effectSummary(item: BftTriageOutcome) {
  const effects: string[] = [];
  const candidates = item.context.candidates ?? 0;
  if (candidates > 0) effects.push(t.effects.context(candidates));
  for (const status of delegationStatuses) {
    const count = item.delegations.filter((d) => delegationStatus(d) === status).length;
    if (count > 0) effects.push(t.effects.delegations[status](count));
  }
  if (kindOf(item) === "reaction" && item.effect.external_writes === 1)
    effects.push(t.effects.slackReaction);
  if (item.companion?.kind === "reaction") {
    if (item.companion.external_writes === 1) effects.push(t.effects.slackReaction);
    if (pending(item.companion.state)) effects.push(t.outcome.reactionInProgress);
  }
  return effects.join(" · ");
}

export function companionLabel(item: BftTriageOutcome) {
  const companion = item.companion;
  if (companion?.kind !== "reaction" || !companion.emoji) return undefined;
  const status =
    companion.state === "applied"
      ? t.companion.added
      : companion.state === "stale"
        ? t.companion.suppressed
        : companion.state === "failed"
          ? t.companion.failed
          : t.companion.inProgress;
  return t.companion.label(companion.emoji, status);
}

export const outcomeSettled = (item: BftTriageOutcome) =>
  ["applied", "stale", "failed"].includes(item.state ?? "") &&
  (!item.companion ||
    ["applied", "stale", "failed"].includes(item.companion.state ?? ""));

export function durationText(ms: number) {
  return ms < 1000
    ? t.milliseconds(ms)
    : t.seconds(ms % 1000 === 0 ? String(ms / 1000) : (ms / 1000).toFixed(1));
}

// ---- Received messages (processing) ----

export function processingTone(item: {
  state: string | null;
  terminal_status: string | null;
}): Tone {
  const terminal = item.state === "terminal" || item.state === "settled";
  if (terminal && item.terminal_status === "evaluated") return "ok";
  if (terminal && ["failed", "skipped_timeout"].includes(item.terminal_status ?? ""))
    return "warn";
  return item.state === "unavailable" ? "warn" : undefined;
}

export function processingLabel(item: {
  state: string | null;
  terminal_status: string | null;
}): string {
  const p = t.processing;
  if (item.state === "settled" && item.terminal_status === "evaluated")
    return p.finished;
  if (item.state === "terminal" || item.state === "settled") {
    return (
      (p.terminal as Record<string, string>)[item.terminal_status ?? ""] ??
      p.processingFinished
    );
  }
  return (p.states as Record<string, string>)[item.state ?? ""] ?? t.statusUnavailable;
}

export function processingDescription(item: {
  state: string | null;
  terminal_status: string | null;
  suggested_action: string | null;
}): string {
  const p = t.processing;
  if (item.state === "settled") return p.settledBody;
  if (item.state === "terminal") {
    if (item.terminal_status === "evaluated") {
      const action = (p.actions as Record<string, string>)[item.suggested_action ?? ""];
      return item.suggested_action
        ? p.suggestion(action ?? p.actions.review)
        : p.evaluatedBody;
    }
    return (
      (p.terminalBodies as Record<string, string>)[item.terminal_status ?? ""] ??
      p.terminalBody
    );
  }
  return (p.bodies as Record<string, string>)[item.state ?? ""] ?? p.unknownBody;
}

// ---- Retained context and follow-ups ----

export function contextTone(entry: BftTriageContext): Tone {
  return entry.state === "proposed"
    ? "warn"
    : entry.kind === "follow_up"
      ? undefined
      : "ok";
}

export const contextKindLabel = (entry: { kind: string | null }) =>
  (t.contextKinds as Record<string, string>)[entry.kind ?? ""] ??
  t.contextKinds.context;

export function contextStateLabel(entry: BftTriageContext) {
  if (entry.state === "resolved" && entry.resolved_reason === "reminder_delivered")
    return t.contextStates.reminderDelivered;
  return (
    (t.contextStates as Record<string, string>)[entry.state ?? ""] ??
    t.contextStates.unknown
  );
}

export function evidenceText(entry: {
  confidence: string | null;
  source_count: number | null;
}) {
  const confidence =
    (t.confidence as Record<string, string>)[entry.confidence ?? ""] ??
    t.confidence.unknown;
  return `${confidence} · ${t.citedSources(entry.source_count ?? 0)}`;
}

// ---- Timeline threads ----

/** Slack `1700000000.000100` to unix milliseconds. */
export function slackMs(ts: string | null | undefined) {
  if (!ts) return null;
  const [seconds, fraction = "0"] = ts.split(".");
  const ms = Number(seconds) * 1000 + Number(fraction.slice(0, 3).padEnd(3, "0"));
  return Number.isFinite(ms) ? ms : null;
}

export interface Thread {
  key: string;
  rows: BftTriageItem[];
  at: number;
  tone: Tone;
  channel: string;
  startedAt: number | null;
  url: string | null;
}

const rowTone = (item: BftTriageItem) =>
  item.kind === "outcome" ? outcomeTone(item) : processingTone(item);

const byTime = (a: BftTriageItem, b: BftTriageItem) =>
  (a.at ?? 0) - (b.at ?? 0) || a.id.localeCompare(b.id);

/**
 * Groups one bounded page by exact Slack thread (connect, channel, thread);
 * a row without the full identity stays on its own. Newest thread first.
 */
export function threadGroups(
  items: readonly BftTriageItem[],
  names: Map<string, string>
) {
  const groups = new Map<string, BftTriageItem[]>();
  for (const item of items) {
    const { connect_id, channel_id, thread_ts } = item.source;
    const key =
      connect_id && channel_id && thread_ts
        ? JSON.stringify([connect_id, channel_id, thread_ts])
        : `row:${item.id}`;
    groups.set(key, [...(groups.get(key) ?? []), item]);
  }
  return [...groups.entries()]
    .map(([key, entries]): Thread => {
      const rows = entries.toSorted(byTime);
      const latest = rows[rows.length - 1] as BftTriageItem;
      const source = latest.source;
      return {
        key,
        rows,
        at: latest.at ?? 0,
        tone: rowTone(latest),
        channel:
          names.get(`${source.connect_id}/${source.channel_id}`) ??
          t.channelUnavailable,
        startedAt: slackMs(source.thread_ts),
        url: rows.map((row) => row.source.url).find(Boolean) ?? null,
      };
    })
    .toSorted(
      (a, b) => b.at - a.at || (b.rows[0]?.id ?? "").localeCompare(a.rows[0]?.id ?? "")
    );
}

export function activityCounts(items: readonly BftTriageItem[]) {
  const outcomes = items.filter(
    (item): item is BftTriageOutcome => item.kind === "outcome"
  );
  return {
    total: outcomes.length,
    reply: outcomes.filter((item) => kindOf(item) === "reply").length,
    reaction: outcomes.filter((item) => kindOf(item) === "reaction").length,
    silence: outcomes.filter(
      (item) =>
        kindOf(item) === "silence" && item.communication.reason !== "worker_pending"
    ).length,
    inProgress: outcomes.filter(outcomeInProgress).length,
    failed: outcomes.filter(outcomeFailed).length,
  };
}

// ---- Heatmap ----

const hourMs = 3_600_000;
export const heatmapRanges = { "24h": [24, 1], "7d": [28, 6] } as const;
export type HeatmapRange = keyof typeof heatmapRanges;
const visibleRows = 5;

export interface HeatmapCell {
  start: number;
  end: number;
  reply: number;
  reaction: number;
  silence: number;
  total: number;
  level: 0 | 1 | 2 | 3;
  acted: boolean;
}

const sum = (counts: number[][], i: number) =>
  counts.reduce((total, cell) => total + (cell[i] ?? 0), 0);

/**
 * Salix sends 7 days of hourly cells. "24h" shows the last 24, one per
 * column; "7d" groups them into 6-hour columns. Without a choice the view
 * opens on 24h when that day has activity. Darker is busier; a cell with a
 * reply or reaction is marked as acted.
 */
export function heatmapView(
  heatmap: BftTriageHeatmap,
  names: Map<string, string>,
  range: HeatmapRange | null,
  expanded: boolean
) {
  const { since_ms: since, cells } = heatmap;
  if (cells.length === 0) return null;
  const chosen: HeatmapRange =
    range ?? (cells.some((cell) => cell.at_ms >= since + 144 * hourMs) ? "24h" : "7d");
  const [columns, hours] = heatmapRanges[chosen];
  const bucket = hours * hourMs;
  const start = since + 168 * hourMs - columns * bucket;
  const filterable = new Set([...names.keys()].map((key) => key.split("/")[1]));

  const channels = new Map<
    string,
    { connect: string | null; id: string; counts: number[][] }
  >();
  for (const cell of cells) {
    if (cell.at_ms < start) continue;
    const key = `${cell.connect_id}/${cell.channel_id}`;
    const row = channels.get(key) ?? {
      connect: cell.connect_id,
      id: cell.channel_id,
      counts: Array.from({ length: columns }, () => [0, 0, 0, 0]),
    };
    const index = Math.min(Math.floor((cell.at_ms - start) / bucket), columns - 1);
    const counts = row.counts[index] as number[];
    [cell.reply, cell.reaction, cell.silence, cell.total].forEach((value, i) => {
      counts[i] = (counts[i] ?? 0) + value;
    });
    channels.set(key, row);
  }

  const all = [...channels.entries()]
    .map(([key, row]) => {
      const total = sum(row.counts, 3);
      return {
        channel: row.id,
        label: names.get(key) ?? row.id,
        filterable: filterable.has(row.id),
        total,
        replied: sum(row.counts, 0) + sum(row.counts, 1),
        silentPercent: Math.round((100 * sum(row.counts, 2)) / Math.max(total, 1)),
        counts: row.counts,
      };
    })
    .toSorted((a, b) => b.total - a.total || a.label.localeCompare(b.label));
  const shown = expanded ? all : all.slice(0, visibleRows);
  const peak = Math.max(
    1,
    ...shown.flatMap((row) => row.counts.map((cell) => cell[3] ?? 0))
  );
  const ticks = chosen === "24h" ? 6 : 4;

  return {
    range: chosen,
    columns,
    hidden: all.length - shown.length,
    canCollapse: expanded && all.length > visibleRows,
    rows: shown.map(({ counts, ...row }) => ({
      ...row,
      cells: counts.map(
        ([reply = 0, reaction = 0, silence = 0, total = 0], index): HeatmapCell => ({
          start: start + index * bucket,
          end: start + (index + 1) * bucket,
          reply,
          reaction,
          silence,
          total,
          level:
            total === 0
              ? 0
              : (Math.max(1, Math.min(3, Math.ceil((3 * total) / peak))) as 1 | 2 | 3),
          acted: reply + reaction > 0,
        })
      ),
    })),
    ticks: Array.from(
      { length: columns / ticks },
      (_, i) => start + i * ticks * bucket
    ),
  };
}

// ---- Knowledge ----

export type KnowledgeKind = "person" | "project" | "decision" | "context";
type Assertion = BftTriageKnowledge["assertions"][number];

export interface KnowledgeRow {
  id: string;
  kind: KnowledgeKind;
  name: string;
  summary: string;
  role: string | null;
  sourceRef: string | null;
  assertions: Assertion[];
  uses: Assertion["uses"];
}

const kindRank: Record<KnowledgeKind, number> = {
  person: 0,
  project: 1,
  decision: 2,
  context: 3,
};

/** People and projects named by sourced assertions or membership, then decisions. */
export function knowledgeRows(knowledge: BftTriageKnowledge): KnowledgeRow[] {
  const rows = new Map<string, KnowledgeRow>();
  for (const member of knowledge.members) {
    rows.set(`person:${member.id}`, {
      id: `person-${member.id}`,
      kind: "person",
      name: member.name,
      summary: t.projectMember,
      role: member.role,
      sourceRef: member.source_ref,
      assertions: [],
      uses: [],
    });
  }
  for (const assertion of knowledge.assertions) {
    for (const subject of assertion.subjects) {
      const key = `${subject.kind}:${subject.id}`;
      const row = rows.get(key) ?? {
        id: `${subject.kind}-${subject.id}`,
        kind: subject.kind,
        name: subject.name,
        summary: "",
        role: null,
        sourceRef: null,
        assertions: [],
        uses: [],
      };
      if (!row.assertions.some((other) => other.id === assertion.id))
        row.assertions.push(assertion);
      rows.set(key, row);
    }
  }
  const entities = [...rows.values()].map((row) => {
    const uses = row.assertions.flatMap((assertion) => assertion.uses);
    return {
      ...row,
      summary: row.assertions.length
        ? t.sourcedAssertions(row.assertions.length)
        : row.summary,
      uses: uses.filter(
        (use, index) => uses.findIndex((other) => other.id === use.id) === index
      ),
    };
  });
  const decisions = knowledge.assertions
    .filter((assertion) => assertion.kind === "decision")
    .map(
      (assertion): KnowledgeRow => ({
        id: `decision-${assertion.id}`,
        kind: "decision",
        name: assertion.content,
        summary: assertion.subjects.map((subject) => subject.name).join(" · "),
        role: null,
        sourceRef: null,
        assertions: [assertion],
        uses: assertion.uses,
      })
    );
  return [...entities, ...decisions].toSorted(
    (a, b) => kindRank[a.kind] - kindRank[b.kind] || a.name.localeCompare(b.name)
  );
}

export function knowledgeCounts(
  knowledge: BftTriageKnowledge
): Record<KnowledgeKind, number> {
  const subjects = (kind: string) =>
    knowledge.assertions.flatMap((a) =>
      a.subjects.filter((s) => s.kind === kind).map((s) => s.id)
    );
  const imported = (kind: KnowledgeKind) =>
    knowledge.imported.items.filter((item) => item.kind === kind).length;
  return {
    person:
      new Set([...knowledge.members.map((m) => m.id), ...subjects("person")]).size +
      imported("person"),
    project: new Set(subjects("project")).size + imported("project"),
    decision:
      knowledge.assertions.filter((a) => a.kind === "decision").length +
      knowledge.retained.filter((r) => r.kind === "decision").length +
      imported("decision"),
    context:
      knowledge.retained.filter((r) => r.kind === "context").length +
      imported("context"),
  };
}

/** Case-insensitive match of `query` against any of `texts`. */
export const matches = (query: string, ...texts: (string | null | undefined)[]) =>
  query.trim() === "" ||
  texts.some((text) => text?.toLowerCase().includes(query.trim().toLowerCase()));
