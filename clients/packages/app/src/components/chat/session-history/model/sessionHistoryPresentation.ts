import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";

export type SessionItemKind =
  | "input"
  | "model"
  | "thinking"
  | "call"
  | "result"
  | "running"
  | "success"
  | "error"
  | "cancelled"
  | "context"
  | "migration"
  | "runtime"
  | "unknown";
export type SessionItemLabels = Record<
  SessionItemKind | "empty" | "source" | "sent" | "structured",
  string
> & {
  inputSource?(source: SessionHistoryRecord["input_source"]): string;
  locationRequested?: string;
  count(
    name: "messages" | "tasks" | "matches" | "files" | "items",
    count: number
  ): string;
};
type ObjectValue = Record<string, unknown>;
type ToolCall = { name: string; args: ObjectValue };
export type SessionItemPresentation = {
  kind: SessionItemKind;
  label: string;
  summary: string;
  source?: string | undefined;
  tools: string[];
  duration: number | undefined;
  operation?: string;
  action?: string;
  destination?: { id: string; name: string };
};

export function formatSessionDuration(milliseconds: number | undefined) {
  if (milliseconds === undefined || milliseconds === 0) return undefined;
  return milliseconds >= 1000 ? `${milliseconds / 1000}s` : `${milliseconds}ms`;
}

const object = (value: unknown): ObjectValue =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as ObjectValue)
    : {};
const clip = (value: string) =>
  value.length > 320 ? `${value.slice(0, 320)}…` : value;
// Only decode known structured fields, never classify user/model prose as events.
// Bound parsing and text extraction independently of oversized debug payloads.
function decode(value: unknown): unknown {
  if (typeof value !== "string" || value.length > 128_000) return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}
export const sessionDataObject = (value: unknown) => object(decode(value));
export function sessionRecordData(record: SessionHistoryRecord) {
  const content = object(record.content);
  return {
    ...content,
    ...sessionDataObject(content.content ?? record.content),
    ...object(content.event),
  };
}
function text(value: unknown): string {
  if (typeof value === "string") return clip(value.trim());
  if (Array.isArray(value))
    return clip(
      value
        .slice(0, 8)
        .map((block) => text(object(block).text))
        .filter(Boolean)
        .join("\n")
    );
  return "";
}
export function sessionToolCalls(value: unknown): (ToolCall & { id: string })[] {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => {
    const call = object(entry);
    const fn = object(call.function);
    const args = object(decode(call.args ?? call.arguments ?? fn.arguments));
    const name = text(call.name ?? fn.name);
    return {
      id: text(call.id),
      name: name === "call" ? text(args.tool) || name : name,
      args: name === "call" ? object(args.params) : args,
    };
  });
}
export function argumentSummary(args: ObjectValue): string {
  return (
    text(args.content) ||
    text(args.query) ||
    text(args.command) ||
    text(args.path) ||
    text(args.url) ||
    text(args.title)
  );
}
/** Only display known operation fields, never stringify an arbitrary debug object. */
export function sessionOperationSummary(input: ObjectValue): string {
  const args = typeof input.tool === "string" ? object(input.params) : input;
  const file = object(args.file_ref);
  return clip(
    [
      text(args.environment ?? args.environment_id ?? file.environment_id),
      text(args.path ?? file.path ?? args.working_dir),
      text(args.command ?? args.query ?? args.pattern ?? args.url ?? args.process_name),
      text(args.content ?? args.text ?? args.title),
    ]
      .filter(Boolean)
      .join(" · ")
  );
}
export function sessionOperationDestination(input: ObjectValue) {
  const args = typeof input.tool === "string" ? object(input.params) : input;
  const id = text(args.conversation_id ?? args.chat_id);
  const name = text(args.conversation_name);
  return id || name ? { destination: { id, name } } : {};
}
function resultSummary(value: unknown, labels: SessionItemLabels): string {
  const data = object(decode(value));
  if (data.sent === true) return labels.sent;
  const counts = (["messages", "tasks", "matches", "files"] as const).flatMap((name) =>
    Array.isArray(data[name]) ? [labels.count(name, data[name].length)] : []
  );
  if (counts.length) return counts.join(" · ");
  if (typeof data.count === "number") return labels.count("items", data.count);
  return (
    text(data.text) ||
    text(data.message) ||
    text(data.summary) ||
    (typeof decode(value) === "string" && !/^\s*[[{]/.test(String(value))
      ? text(value)
      : "")
  );
}

/** Items of unchanged records, keyed by record object. A tool record also reads
 * the call its assistant record proposed, so its item stays valid only while
 * the loaded window resolves the same call. Use one cache per labels object. */
export type SessionPresentationCache = WeakMap<
  SessionHistoryRecord,
  { callId: string; call: ToolCall | undefined; item: SessionItemPresentation }
>;

// Records are immutable snapshot values. Parse the calls of each assistant record once.
const assistantCalls = new WeakMap<
  SessionHistoryRecord,
  (ToolCall & { id: string })[]
>();
function assistantToolCalls(record: SessionHistoryRecord) {
  let calls = assistantCalls.get(record);
  if (!calls) {
    calls = sessionToolCalls(object(record.content).tool_calls);
    assistantCalls.set(record, calls);
  }
  return calls;
}

/** One pass over the loaded window; no requests, mutation or cross-page state. */
export function presentSessionRecords(
  records: readonly SessionHistoryRecord[],
  labels: SessionItemLabels,
  cache?: SessionPresentationCache
): SessionItemPresentation[] {
  const tools = new Map<string, ToolCall>();
  for (const record of records) {
    if (record.kind === "assistant")
      for (const call of assistantToolCalls(record)) {
        if (call.id) tools.set(call.id, call);
      }
  }
  return records.map((record) => {
    const cached = cache?.get(record);
    if (cached && tools.get(cached.callId) === cached.call) return cached.item;
    const presented = presentSessionRecord(record, labels, tools);
    cache?.set(record, { ...presented, call: tools.get(presented.callId) });
    return presented.item;
  });
}

function presentSessionRecord(
  record: SessionHistoryRecord,
  labels: SessionItemLabels,
  tools: ReadonlyMap<string, ToolCall>
): { callId: string; item: SessionItemPresentation } {
  const content = object(record.content);
  const prose = text(content.content ?? record.content);
  const toolCalls = record.kind === "assistant" ? assistantToolCalls(record) : [];
  let callId = "";
  let kind: SessionItemKind = "unknown";
  let summary = "";
  let toolNames: string[] = [];
  let duration: number | undefined;
  let operation: string | undefined;
  let action: string | undefined;
  let destination: SessionItemPresentation["destination"];
  if (record.kind === "user") {
    kind = "input";
    summary = text(record.input_text ?? content.content ?? record.content);
  } else if (record.kind === "assistant") {
    kind = "model";
    summary = prose;
    if (!summary) {
      summary = text(content.reasoning ?? content.reasoning_content);
      if (summary && !toolCalls.length) kind = "thinking";
    }
  } else if (["summary", "system", "developer"].includes(record.kind)) {
    kind = "context";
    summary = prose.startsWith("Inbound message source:") ? labels.source : prose;
  } else {
    const data = sessionRecordData(record);
    const result = object(decode(data.result));
    const payload = object(decode(result.content ?? data.content));
    const eventType = text(data.type) || record.kind;
    const status = text(data.status ?? data.state ?? result.status ?? payload.status);
    const failed = [data, result, payload].some(
      (item) =>
        item.is_error === true ||
        item.error === true ||
        !!text(item.error_message) ||
        (typeof item.error === "string" && !!item.error)
    );
    callId = text(data.tool_call_id);
    const call = tools.get(callId);
    const toolName = text(data.tool_name ?? result.name ?? data.name) || call?.name;
    if (toolName) toolNames = [toolName];
    const args = object(
      decode(data.input ?? data.arguments ?? result.input ?? call?.args)
    );
    operation = sessionOperationSummary(args) || undefined;
    destination = sessionOperationDestination(args).destination;
    if (toolName === "env.exec") action = text(args.description) || undefined;
    if (
      failed ||
      /(^|[._])(error|failed)$/.test(eventType) ||
      ["failed", "error"].includes(status)
    )
      kind = "error";
    else if (
      eventType.endsWith("cancelled") ||
      ["cancelled", "canceled"].includes(status)
    )
      kind = "cancelled";
    else if (
      /tool.*(started|progress)$/.test(eventType) ||
      eventType === "session.wait_set" ||
      ["running", "pending", "in_progress", "waiting"].includes(status)
    )
      kind = "running";
    else if (
      /tool.*completed$/.test(eventType) ||
      ["completed", "success", "succeeded"].includes(status)
    )
      kind = "success";
    else if (eventType === "thinking") kind = "thinking";
    else if (eventType === "migration_notice_delta" || eventType === "migration_notice")
      kind = "migration";
    else if (eventType === "message" && data.role === "assistant") kind = "model";
    else if (eventType === "operation") kind = "call";
    else if (record.kind === "tool") kind = "result";
    else if (
      record.kind === "runtime" ||
      record.kind === "runtime.event" ||
      record.kind.startsWith("session.")
    )
      kind = "runtime";
    if (kind === "error") {
      summary =
        text(data.error_message ?? result.error_message ?? payload.error_message) ||
        text(data.error ?? result.error ?? payload.error) ||
        text(data.message) ||
        resultSummary(result.content ?? data.content, labels);
    } else if (kind === "migration") summary = text(data.summary) || text(data.content);
    else if (kind === "cancelled")
      summary = text(data.cancel_reason) || text(data.message);
    else if (kind === "running" || kind === "call")
      summary =
        text(data.progress) ||
        argumentSummary(object(decode(data.input ?? data.arguments))) ||
        argumentSummary(call?.args ?? {}) ||
        labels[kind];
    else if (kind === "model" || kind === "thinking") summary = text(data.content);
    else
      summary = resultSummary(
        data.output ??
          result.content ??
          data.result ??
          content.content ??
          record.content,
        labels
      );
    if (!summary)
      summary = text(data.text) || text(data.message) || text(data.summary) || status;
    if (
      toolName === "location.request" &&
      !["error", "cancelled", "running"].includes(kind) &&
      [data, result, payload, object(decode(data.output))].some(
        (value) => value.status === "question_delivered"
      )
    )
      summary = labels.locationRequested ?? labels.sent;
    // The operation already contains the outgoing body. Receipts add no content;
    // failures and cancellations still retain their actionable result.
    if (
      toolName === "im_api.internal.send_message" &&
      !["error", "cancelled"].includes(kind)
    )
      summary = "";
    const milliseconds =
      object(data.execution_timing).duration_ms ??
      data.duration_ms ??
      result.duration_ms;
    if (typeof milliseconds === "number" && milliseconds >= 0) duration = milliseconds;
  }
  const measuredDuration = record.execution?.duration_ms;
  if (typeof measuredDuration === "number" && measuredDuration >= 0)
    duration = measuredDuration;
  return {
    callId,
    item: {
      kind,
      ...(record.kind === "user"
        ? { source: labels.inputSource?.(record.input_source) }
        : {}),
      label:
        record.kind === "assistant"
          ? labels.model
          : kind === "unknown"
            ? `${labels.unknown} · ${record.kind}`
            : labels[kind],
      summary: clip(
        summary ||
          (toolNames[0] === "im_api.internal.send_message"
            ? ""
            : kind === "model" || kind === "input"
              ? labels.empty
              : labels.structured)
      ),
      tools: toolNames,
      duration,
      ...(operation ? { operation } : {}),
      ...(action ? { action } : {}),
      ...(destination ? { destination } : {}),
    },
  };
}
