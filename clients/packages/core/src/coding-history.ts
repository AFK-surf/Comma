// A coding Session's execution history as the page shows it (`coding.history`): its transcript entries, as its station
// reads them (`TimelineEntry`: user, assistant, thinking, tool_call, tool_result), made into items. What a person or the
// Task said and what the agent wrote are items of their own; the tool calls and thinking between them are one group,
// each call paired with its result by `callId` (else the latest call still open) and described by what it does.
import type { CodingHistoryItem, CodingStep, CodingStepBody } from "./contract.ts";

/** A transcript entry as the station sends it. */
export interface HistoryEntry {
  at: string | null;
  kind: string;
  text: string;
  tool?: string | undefined;
  ok?: boolean | undefined;
  callId?: string | undefined;
  subagent?: boolean | undefined;
}

type ToolStep = Extract<CodingStep, { kind: "tool" }>;
type Group = {
  id: string;
  steps: CodingStep[];
  open: Map<string, ToolStep>;
  at: Map<ToolStep, number>;
};

/** The entries from index `start` as items; ids are the entries' indexes, so pages join without clashes. */
export function historyItems(
  entries: readonly HistoryEntry[],
  start = 0
): CodingHistoryItem[] {
  const items: CodingHistoryItem[] = [];
  let group: Group | null = null;
  const close = () => {
    if (group === null) return;
    const tools = group.steps.filter((s): s is ToolStep => s.kind === "tool");
    items.push({
      kind: "group",
      id: group.id,
      steps: group.steps,
      failures: tools.filter((s) => s.failed).length,
      pending: tools.filter((s) => s.pending).length,
    });
    group = null;
  };
  const open = (id: string): Group =>
    (group ??= { id, steps: [], open: new Map(), at: new Map() });

  entries.forEach((entry, index) => {
    const id = `h${start + index}`;
    switch (entry.kind) {
      case "user":
        close();
        items.push({ kind: "received", id, text: entry.text, at: entry.at });
        return;
      case "assistant":
        close();
        if (entry.text.trim() !== "")
          items.push({ kind: "text", id, text: entry.text, at: entry.at });
        return;
      case "thinking":
        if (entry.text.trim() !== "")
          open(id).steps.push({ kind: "thinking", id, text: entry.text });
        return;
      case "tool_call": {
        const g = open(id);
        const tool = entry.tool ?? "tool";
        const { hint, body } = describe(tool, entry.text);
        const step: ToolStep = {
          kind: "tool",
          id,
          tool,
          hint,
          body,
          result: null,
          pending: true,
          failed: false,
          durationMs: null,
        };
        g.steps.push(step);
        g.open.set(entry.callId ?? id, step);
        g.at.set(step, time(entry.at));
        return;
      }
      case "tool_result": {
        if (group === null) return;
        const g: Group = group;
        const key = entry.callId ?? [...g.open.keys()].at(-1);
        const step = key === undefined ? undefined : g.open.get(key);
        if (!step) return;
        g.open.delete(key!);
        step.result = entry.text;
        step.pending = false;
        step.failed = entry.ok === false;
        const began = g.at.get(step) ?? Number.NaN;
        const ended = time(entry.at);
        step.durationMs =
          Number.isFinite(began) && Number.isFinite(ended) && ended >= began
            ? ended - began
            : null;
        return;
      }
      default:
        return;
    }
  });
  close();
  return items;
}

const time = (at: string | null) => (at === null ? Number.NaN : Date.parse(at));

/** A tool call's arguments (pretty JSON, else free text): its hint and how it is shown. */
export function describe(
  tool: string,
  text: string
): { hint: string; body: CodingStepBody } {
  if (text.trimStart().startsWith("*** Begin Patch"))
    return { hint: patchPaths(text), body: { kind: "patch", diff: patchDiff(text) } };
  let args: Record<string, unknown> | null = null;
  try {
    const parsed: unknown = JSON.parse(text);
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed))
      args = parsed as Record<string, unknown>;
  } catch {
    args = null;
  }
  if (args === null) return { hint: firstLine(text), body: { kind: "args", text } };
  const str = (key: string) =>
    typeof args![key] === "string" ? (args![key] as string) : undefined;

  const command =
    str("command") ??
    str("cmd") ??
    (Array.isArray(args.command) ? args.command.join(" ") : undefined);
  if (command !== undefined) {
    const shown = command.replace(/^(?:bash|sh|zsh)\s+-l?c\s+/, "");
    return { hint: firstLine(shown), body: { kind: "command", command: shown } };
  }
  const path = str("file_path") ?? str("path") ?? str("notebook_path");
  const patch = str("patch") ?? str("input");
  if (patch !== undefined && patch.trimStart().startsWith("*** Begin Patch"))
    return { hint: patchPaths(patch), body: { kind: "patch", diff: patchDiff(patch) } };
  if (
    path !== undefined &&
    (str("old_string") !== undefined || str("new_string") !== undefined)
  )
    return {
      hint: path,
      body: {
        kind: "edit",
        path,
        diff: lineDiff(str("old_string") ?? "", str("new_string") ?? ""),
      },
    };
  if (path !== undefined && Array.isArray(args.edits)) {
    const diff = args.edits
      .map((e) =>
        e && typeof e === "object"
          ? lineDiff(
              String((e as Record<string, unknown>).old_string ?? ""),
              String((e as Record<string, unknown>).new_string ?? "")
            )
          : ""
      )
      .join("\n");
    return { hint: path, body: { kind: "edit", path, diff } };
  }
  if (path !== undefined && str("content") !== undefined)
    return {
      hint: path,
      body: { kind: "edit", path, diff: lineDiff("", str("content")!) },
    };
  if (path !== undefined && /^(read|view|open)/i.test(tool)) {
    const offset = typeof args.offset === "number" ? args.offset : null;
    const limit = typeof args.limit === "number" ? args.limit : null;
    const lines =
      offset !== null && limit !== null
        ? `${offset}–${offset + limit}`
        : offset !== null
          ? `${offset}–`
          : null;
    return { hint: path, body: { kind: "read", path, lines } };
  }
  const lead =
    path ??
    str("pattern") ??
    str("query") ??
    str("url") ??
    str("description") ??
    str("prompt");
  const first =
    lead ?? Object.values(args).find((v): v is string => typeof v === "string");
  return {
    hint: first === undefined ? "" : firstLine(first),
    body: { kind: "args", text },
  };
}

const firstLine = (text: string) => {
  const line = text.trim().split("\n", 1)[0] ?? "";
  return line.length > 120 ? `${line.slice(0, 119)}…` : line;
};

/** An edit as a unified diff of its lines: what both share at their start and end is context. */
function lineDiff(before: string, after: string): string {
  const a = before === "" ? [] : before.split("\n");
  const b = after === "" ? [] : after.split("\n");
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tail = 0;
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  )
    tail++;
  return [
    ...a.slice(0, head).map((l) => ` ${l}`),
    ...a.slice(head, a.length - tail).map((l) => `-${l}`),
    ...b.slice(head, b.length - tail).map((l) => `+${l}`),
    ...a.slice(a.length - tail).map((l) => ` ${l}`),
  ].join("\n");
}

/** apply_patch's text as a diff: its file headers kept, its hunks as they are. */
function patchDiff(text: string): string {
  return text
    .split("\n")
    .filter((l) => !/^\*\*\* (Begin|End) Patch/.test(l))
    .map((l) => l.replace(/^\*\*\* (Add|Update|Delete) File: (.*)$/, "--- $2 ($1)"))
    .join("\n");
}

/** The files an apply_patch touches. */
function patchPaths(text: string): string {
  const paths = [...text.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.*)$/gm)].map(
    (m) => m[1]!
  );
  return paths.length <= 2
    ? paths.join(", ")
    : `${paths.slice(0, 2).join(", ")} +${paths.length - 2}`;
}
