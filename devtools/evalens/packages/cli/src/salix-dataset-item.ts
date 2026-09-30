import { z } from "zod";

import { DatasetItem, ItemId } from "@evalens/core";

const ToolCall = z
  .object({
    id: z.string(),
    name: z.string(),
    args: z.record(z.string(), z.json()).optional(),
  })
  .strict();

const HistoryEntry = z
  .object({
    role: z.enum(["user", "assistant", "runtime", "summary", "tool"]),
    content: z.string(),
    toolCalls: z.array(ToolCall).optional(),
    toolCallId: z.string().optional(),
    toolName: z.string().optional(),
    status: z.string().optional(),
    output: z.json().optional(),
    errorClass: z.string().optional(),
    errorMessage: z.string().optional(),
  })
  .strict();

const Finding = z
  .object({
    metric: z.string(),
    verdict: z.literal("confirmed"),
    score: z.number().min(0).max(1),
    reason: z.string().optional(),
  })
  .loose();

const RawRecord = z.record(z.string(), z.json());

export const SalixTrajectoryResult = z
  .object({
    source: z
      .object({
        agent_id: z.string().min(1),
        session_id: z.string().min(1),
      })
      .loose(),
    target: z
      .object({
        agent_role: z.enum(["router", "worker"]),
        runtime_kind: z.literal("internal"),
      })
      .strict()
      .optional(),
    window: z
      .object({
        from_message_id: z.number().int().nonnegative(),
        to_message_id: z.number().int().nonnegative(),
        message_count: z.number().int().positive(),
      })
      .loose(),
    evaluation: z
      .object({
        evaluator: z.literal("judge"),
        evaluator_version: z.string().nullish(),
        evaluated_at: z.string(),
        findings: z.array(Finding).min(1),
      })
      .loose(),
    session_records_status: z.enum(["available", "snapshot_unavailable"]),
    session_records: z.array(RawRecord).optional(),
  })
  .strict();

export const SalixTrajectoryPage = z
  .object({
    items: z.array(SalixTrajectoryResult),
    next_cursor: z.string().min(1),
    has_more: z.boolean(),
  })
  .loose();

export const SalixDatasetItem = DatasetItem.extend({
  schemaVersion: z.literal(1),
  kind: z.literal("salix.session_regression_dataset_item"),
  input: z
    .object({
      targetRole: z.enum(["router", "worker"]),
      history: z.array(HistoryEntry),
      probe: z.object({ message: z.string() }).strict(),
    })
    .strict(),
  expected: z
    .object({
      trajectoryRegression: z
        .object({
          mustReply: z.literal(true),
          confirmedFindings: z.array(
            z
              .object({
                metric: z.string(),
                sourceSeverity: z.number().min(0).max(1),
                reason: z.string().optional(),
              })
              .strict()
          ),
          maxIdenticalToolRepeats: z.literal(3),
          maxConsecutiveToolErrors: z.literal(2),
        })
        .strict(),
    })
    .strict(),
  provenance: z
    .object({
      source: z.literal("salix-l2"),
      sourceFingerprint: z.string().regex(/^[a-f0-9]{64}$/u),
      sourceEvaluatorVersion: z.string(),
      sourceEvaluatedAt: z.string(),
      redactionPolicyVersion: z.literal("evalens-1"),
    })
    .strict(),
});

export type SalixTrajectoryResult = z.infer<typeof SalixTrajectoryResult>;
export type SalixTrajectoryPage = z.infer<typeof SalixTrajectoryPage>;
export type SalixDatasetItem = z.infer<typeof SalixDatasetItem>;

type Replay = {
  history: Array<z.infer<typeof HistoryEntry>>;
  probe: string;
};

const historyLimit = 100;
const sensitiveKey =
  /(?:authorization|cookie|secret|password|private[_-]?key|access[_-]?token|refresh[_-]?token|bot[_-]?token|api[_-]?key)/iu;
const secretValue =
  /(?:Bearer\s+[A-Za-z0-9._~+/-]+=*|xox[baprs]-[A-Za-z0-9-]+|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/gu;

export function toDatasetItem(
  result: SalixTrajectoryResult
): SalixDatasetItem | undefined {
  const replay = buildReplay(result);
  if (!replay || !result.target) return undefined;

  const sourceFingerprint = sha256(
    JSON.stringify({
      agentId: result.source.agent_id,
      sessionId: result.source.session_id,
      windowToMessageId: result.window.to_message_id,
    })
  );

  return SalixDatasetItem.parse({
    id: ItemId.parse(`salix-l2-${sourceFingerprint}`),
    schemaVersion: 1,
    kind: "salix.session_regression_dataset_item",
    input: {
      targetRole: result.target.agent_role,
      history: replay.history,
      probe: { message: replay.probe },
    },
    expected: {
      trajectoryRegression: {
        mustReply: true,
        confirmedFindings: result.evaluation.findings.map((finding) => ({
          metric: finding.metric,
          sourceSeverity: finding.score,
          ...(finding.reason ? { reason: redactText(finding.reason) } : {}),
        })),
        maxIdenticalToolRepeats: 3,
        maxConsecutiveToolErrors: 2,
      },
    },
    provenance: {
      source: "salix-l2",
      sourceFingerprint,
      sourceEvaluatorVersion: result.evaluation.evaluator_version ?? "unknown",
      sourceEvaluatedAt: result.evaluation.evaluated_at,
      redactionPolicyVersion: "evalens-1",
    },
  });
}

export function redact(value: unknown): z.JSONType {
  if (value === null || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redact);
  if (isObject(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [
        key,
        sensitiveKey.test(key) ? "<redacted:secret>" : redact(nested),
      ])
    );
  }
  return null;
}

function buildReplay(result: SalixTrajectoryResult): Replay | undefined {
  if (
    result.session_records_status !== "available" ||
    !result.session_records ||
    !result.target
  ) {
    return undefined;
  }

  try {
    const records = result.session_records;
    const from = records.findIndex(
      (record) => messageId(record.id) === result.window.from_message_id
    );
    const to = records.findIndex(
      (record) => messageId(record.id) === result.window.to_message_id
    );
    if (from < 0 || to < from || to - from + 1 !== result.window.message_count) {
      return undefined;
    }

    const trigger = records.findLastIndex(
      (record, index) => index < from && recordRole(record) === "user"
    );
    if (trigger < 0) return undefined;

    const probe = normalizeRecord(records[trigger]!);
    if (probe.role !== "user") return undefined;
    return {
      history: records
        .slice(Math.max(0, trigger - historyLimit), trigger)
        .map(normalizeRecord),
      probe: probe.content,
    };
  } catch {
    return undefined;
  }
}

function normalizeRecord(record: z.infer<typeof RawRecord>) {
  const role = recordRole(record);
  const entry: Record<string, z.JSONType> = {
    role,
    content: text(record.content),
  };

  optional(entry, "toolCalls", normalizeToolCalls(record.tool_calls));
  optional(entry, "toolCallId", optionalText(record.tool_call_id));
  optional(entry, "toolName", optionalText(record.tool_name));
  optional(entry, "status", optionalText(record.status));
  optional(entry, "output", optionalJson(record.output));
  optional(entry, "errorClass", optionalText(record.error_class));
  optional(entry, "errorMessage", optionalText(record.error_message));
  return HistoryEntry.parse(entry);
}

function normalizeToolCalls(value: z.JSONType | undefined) {
  if (!Array.isArray(value)) return undefined;
  return value.flatMap((call) => {
    if (!isObject(call)) return [];
    const args = toolArgs(call.args ?? call.arguments);
    return [
      {
        id: optionalText(call.id ?? call.call_id) ?? "call",
        name: optionalText(call.name) ?? "unknown",
        ...(args ? { args } : {}),
      },
    ];
  });
}

function toolArgs(value: z.JSONType | undefined) {
  if (isObject(value)) return redact(value) as Record<string, z.JSONType>;
  if (typeof value !== "string") return undefined;
  try {
    const parsed: unknown = JSON.parse(value);
    return isObject(parsed)
      ? (redact(parsed) as Record<string, z.JSONType>)
      : undefined;
  } catch {
    return undefined;
  }
}

function recordRole(record: z.infer<typeof RawRecord>): string {
  const role = record.role === "event" ? "runtime" : record.role;
  if (
    typeof role !== "string" ||
    !["user", "assistant", "runtime", "summary", "tool"].includes(role)
  ) {
    throw new Error("unsupported Salix session record role");
  }
  return role;
}

function messageId(value: z.JSONType | undefined): number {
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^\d+$/u.test(value)) return Number(value);
  return -1;
}

function text(value: z.JSONType | undefined): string {
  if (typeof value === "string") return redactText(value);
  return value == null ? "" : JSON.stringify(redact(value));
}

function optionalText(value: z.JSONType | undefined): string | undefined {
  return value == null ? undefined : text(value);
}

function optionalJson(value: z.JSONType | undefined): z.JSONType | undefined {
  return value == null ? undefined : redact(value);
}

function optional(
  target: Record<string, z.JSONType>,
  key: string,
  value: z.JSONType | undefined
) {
  if (value !== undefined) target[key] = value;
}

function redactText(value: string): string {
  return value.replace(secretValue, "<redacted:secret>");
}

function isObject(value: unknown): value is Record<string, z.JSONType> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function sha256(value: string): string {
  return new Bun.CryptoHasher("sha256").update(value).digest("hex");
}
