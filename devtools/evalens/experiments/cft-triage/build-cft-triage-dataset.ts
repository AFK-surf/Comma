import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

import {
  CftTriageEvalItemSchema,
  extractCftDiversityKeys,
  type CftTriageEvalItem,
} from "./dataset";

const RawWorkerMessageSchema = z
  .object({
    message_ts: z.string().min(1),
    actor_kind: z.string().min(1),
    actor_id: z.string().nullable().optional(),
    display_name: z.string().nullable().optional(),
    text: z.string().nullable().optional(),
    subtype: z.string().nullable().optional(),
    source_ref: z.string().min(1),
  })
  .loose();

const RawWorkerItemSchema = z
  .object({
    id: z.string().min(1),
    run_id: z.string().min(1),
    bucket: z.string().min(1),
    inserted_at: z.string().datetime({ offset: true }),
    channel_id: z.string().nullable().optional(),
    thread_ts: z.string().nullable().optional(),
    is_ordinary_worker: z.boolean().default(true),
    is_recheck: z.boolean().default(false),
    recheck_context_refs: z.array(z.string()).default([]),
    expression_context: z
      .object({
        allowed_emojis: z.array(z.string()).optional(),
        guidance: z.string().nullable().optional(),
      })
      .loose()
      .nullable()
      .optional(),
    source_messages: z.array(RawWorkerMessageSchema).min(1),
    context_sources: z
      .array(
        z
          .object({
            source_ref: z.string().min(1),
            kind: z.string().min(1),
            subject: z.string().nullable().optional(),
            value: z.string().nullable().optional(),
            state: z.string().nullable().optional(),
            confidence: z.string().nullable().optional(),
            follow_up_basis: z.string().nullable().optional(),
            recheck_after_hours: z.number().int().positive().nullable().optional(),
          })
          .loose()
      )
      .default([]),
    worker_notes: z
      .array(
        z
          .object({
            actor_type: z.string().nullable().optional(),
            seq: z.number().int().optional(),
            content: z.string().nullable().optional(),
          })
          .loose()
      )
      .default([]),
  })
  .loose();

const RawNativeItemSchema = z
  .object({
    id: z.string().min(1),
    run_id: z.string().min(1),
    bucket: z.string().min(1),
    inserted_at: z.string().datetime({ offset: true }),
    source_mode: z.enum([
      "clickhouse_etl",
      "periodic_patrol",
      "scheduled_recheck",
      "callback",
    ]),
    target_route: z.enum(["none", "self", "other", "mixed"]).nullable().optional(),
    model_input: z.record(z.string(), z.json()),
  })
  .loose();

const RawCftStagingSnapshotSchema = z
  .object({
    exported_at: z.string().datetime({ offset: true }),
    worker_items: z.array(RawWorkerItemSchema).default([]),
    native_items: z.array(RawNativeItemSchema).default([]),
  })
  .loose();

const EMAIL_RE = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/gu;
const SLACK_USER_RE = /<@[UW][A-Z0-9]{6,}>/gu;
const TOKEN_RE =
  /\b(?:xox[baprs]-[A-Za-z0-9-]+|gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{16,})\b/gu;

export function redactCftText(value: string): string {
  return value
    .replaceAll(TOKEN_RE, "[redacted-token]")
    .replaceAll(EMAIL_RE, "[redacted-email]")
    .replaceAll(SLACK_USER_RE, "<@U_REDACTED>");
}

function maybeRedact(value: string, redact: boolean): string {
  return redact ? redactCftText(value) : value;
}

function normalizeActorKind(raw: string): "human" | "agent" | "bot" | "system" {
  if (raw === "human" || raw === "agent" || raw === "bot" || raw === "system") {
    return raw;
  }
  if (raw === "user") return "human";
  if (raw === "app") return "bot";
  return "system";
}

function extractNativePreview(
  modelInput: Record<string, unknown>,
  redact: boolean
): { targetSummary: string; threadPreview: string[]; channelId?: string } {
  const snapshot =
    typeof modelInput.snapshot === "object" && modelInput.snapshot !== null
      ? (modelInput.snapshot as Record<string, unknown>)
      : {};
  const slack =
    typeof snapshot.slack_context === "object" && snapshot.slack_context !== null
      ? (snapshot.slack_context as Record<string, unknown>)
      : {};
  const target =
    typeof slack.decision_target === "object" && slack.decision_target !== null
      ? (slack.decision_target as Record<string, unknown>)
      : {};
  const messages = Array.isArray(slack.messages) ? slack.messages : [];

  const targetRef =
    typeof target.message_ref === "string" ? target.message_ref : undefined;
  const targetSourceRef =
    typeof target.source_ref === "string" ? target.source_ref : undefined;
  const matchedTarget = messages.find((entry) => {
    if (typeof entry !== "object" || entry === null) return false;
    const row = entry as Record<string, unknown>;
    return (
      (targetRef !== undefined && row.message_ref === targetRef) ||
      (targetSourceRef !== undefined && row.source_ref === targetSourceRef)
    );
  }) as Record<string, unknown> | undefined;

  const targetText =
    typeof target.text === "string" && target.text.length > 0
      ? target.text
      : typeof matchedTarget?.text === "string"
        ? matchedTarget.text
        : "";
  const threadPreview = messages.slice(-8).map((entry) => {
    if (typeof entry !== "object" || entry === null) return "";
    const row = entry as Record<string, unknown>;
    const actor = typeof row.actor_kind === "string" ? row.actor_kind : "msg";
    const text = typeof row.text === "string" ? row.text : "";
    return `[${actor}] ${maybeRedact(text.slice(0, 400), redact)}`;
  });

  const channelId =
    typeof slack.channel_id === "string" && slack.channel_id.length > 0
      ? slack.channel_id
      : undefined;

  const fallbackSummary = threadPreview[threadPreview.length - 1] ?? "(no target text)";

  return {
    targetSummary:
      targetText.length > 0
        ? maybeRedact(targetText.slice(0, 600), redact)
        : fallbackSummary,
    threadPreview: threadPreview.filter((line) => line.length > 0),
    ...(channelId ? { channelId } : {}),
  };
}

export function diversifyCftDatasetItems(
  items: readonly CftTriageEvalItem[],
  options: {
    maxPerThread?: number;
    maxPerRunId?: number;
    maxPerTemplate?: number;
    maxPerChannel?: number;
  } = {}
): CftTriageEvalItem[] {
  const maxPerThread = options.maxPerThread ?? 1;
  const maxPerRunId = options.maxPerRunId ?? 1;
  const maxPerTemplate = options.maxPerTemplate ?? 1;
  const maxPerChannel = options.maxPerChannel ?? 3;

  const runCounts = new Map<string, number>();
  const threadCounts = new Map<string, number>();
  const templateCounts = new Map<string, number>();
  const channelCounts = new Map<string, number>();
  const kept: CftTriageEvalItem[] = [];

  for (const item of items) {
    const payload =
      item.input.kind === "counterfactual_pair" ? item.input.base : item.input.payload;
    const keys = extractCftDiversityKeys(payload);
    if ((runCounts.get(keys.runKey) ?? 0) >= maxPerRunId) continue;
    if (keys.threadKey && (threadCounts.get(keys.threadKey) ?? 0) >= maxPerThread) {
      continue;
    }
    if ((templateCounts.get(keys.templateKey) ?? 0) >= maxPerTemplate) continue;
    if (keys.channelKey && (channelCounts.get(keys.channelKey) ?? 0) >= maxPerChannel) {
      continue;
    }

    kept.push(item);
    runCounts.set(keys.runKey, (runCounts.get(keys.runKey) ?? 0) + 1);
    if (keys.threadKey) {
      threadCounts.set(keys.threadKey, (threadCounts.get(keys.threadKey) ?? 0) + 1);
    }
    templateCounts.set(
      keys.templateKey,
      (templateCounts.get(keys.templateKey) ?? 0) + 1
    );
    if (keys.channelKey) {
      channelCounts.set(keys.channelKey, (channelCounts.get(keys.channelKey) ?? 0) + 1);
    }
  }
  return kept;
}

export function buildCftTriageDatasetFromSnapshot(
  rawSnapshot: unknown,
  options: {
    name: string;
    description?: string;
    redact?: boolean;
    includeWorker?: boolean;
    includeNative?: boolean;
    diversify?: boolean;
    maxPerThread?: number;
    maxPerTemplate?: number;
    maxPerChannel?: number;
  }
): { name: string; description: string; items: CftTriageEvalItem[] } {
  const snapshot = RawCftStagingSnapshotSchema.parse(rawSnapshot);
  const redact = options.redact === true;
  const includeWorker = options.includeWorker !== false;
  const includeNative = options.includeNative !== false;

  const items: CftTriageEvalItem[] = [];

  if (includeWorker) {
    for (const row of snapshot.worker_items) {
      const safeId = row.id
        .toLowerCase()
        .replaceAll(/[^a-z0-9._-]/gu, "_")
        .replace(/^\.+/u, "")
        .slice(0, 64);
      const taskCommand = row.worker_notes
        .filter(
          (n) => n.seq === 1 && typeof n.content === "string" && n.content.length > 0
        )
        .map((n) => maybeRedact(n.content ?? "", redact))[0];

      const workspaceFindings = row.worker_notes
        .filter(
          (n) =>
            (n.seq ?? 0) > 1 &&
            typeof n.content === "string" &&
            n.content.trim().length > 0
        )
        .slice(0, 4)
        .map((n) => ({
          source: `task_note_seq_${n.seq ?? 0}`,
          summary: maybeRedact((n.content ?? "").slice(0, 800), redact),
        }));

      items.push(
        CftTriageEvalItemSchema.parse({
          id: safeId,
          input: {
            kind: "shadow_diff",
            tags: ["worker", row.bucket, row.is_recheck ? "recheck" : "ambient"],
            payload: {
              layer: "worker_participation",
              worker: {
                itemId: row.id,
                ...(row.channel_id
                  ? { channelId: redact ? "C_REDACTED" : row.channel_id }
                  : {}),
                ...(row.thread_ts ? { threadTs: row.thread_ts } : {}),
                targetRoute: "none",
                isRecheck: row.is_recheck,
                recheckContextRefs: row.recheck_context_refs,
                messages: row.source_messages.map((m) => ({
                  messageTs: m.message_ts,
                  actorKind: normalizeActorKind(m.actor_kind),
                  ...(m.actor_id
                    ? { actorId: redact ? "U_REDACTED" : m.actor_id }
                    : {}),
                  ...(m.display_name
                    ? { displayName: maybeRedact(m.display_name, redact) }
                    : {}),
                  text: maybeRedact(m.text ?? "", redact),
                  sourceRef: m.source_ref,
                  ...(m.subtype ? { subtype: m.subtype } : {}),
                })),
                contextSources: row.context_sources.map((cs) => ({
                  sourceRef: cs.source_ref,
                  kind: cs.kind,
                  subject: maybeRedact(cs.subject ?? "", redact),
                  value: maybeRedact(cs.value ?? "", redact),
                  ...(cs.state ? { state: cs.state } : {}),
                  ...(cs.confidence ? { confidence: cs.confidence } : {}),
                  ...(cs.follow_up_basis ? { followUpBasis: cs.follow_up_basis } : {}),
                  ...(cs.recheck_after_hours
                    ? { recheckAfterHours: cs.recheck_after_hours }
                    : {}),
                })),
                workspaceFindings,
                ...(row.expression_context
                  ? {
                      expressionContext: {
                        allowedEmojis: row.expression_context.allowed_emojis ?? [],
                        ...(row.expression_context.guidance
                          ? { guidance: row.expression_context.guidance }
                          : {}),
                      },
                    }
                  : {}),
                ...(taskCommand ? { taskCommand } : {}),
                capturedAt: row.inserted_at,
              },
            },
          },
          expected: {},
        })
      );
    }
  }

  if (includeNative) {
    for (const row of snapshot.native_items) {
      const safeId = row.id
        .toLowerCase()
        .replaceAll(/[^a-z0-9._-]/gu, "_")
        .replace(/^\.+/u, "")
        .slice(0, 64);
      const route = row.target_route ?? "none";
      const lane =
        route === "other" || route === "self" || route === "mixed"
          ? "context_extraction"
          : row.source_mode === "scheduled_recheck"
            ? "scheduled_recheck"
            : "general";
      const preview = extractNativePreview(row.model_input, redact);

      items.push(
        CftTriageEvalItemSchema.parse({
          id: safeId,
          input: {
            kind: "shadow_diff",
            tags: ["native", lane, row.bucket],
            payload: {
              layer: "native_evaluator",
              native: {
                itemId: row.id,
                lane,
                sourceMode: row.source_mode,
                targetRoute: route,
                ...(preview.channelId
                  ? { channelId: redact ? "C_REDACTED" : preview.channelId }
                  : {}),
                targetSummary: preview.targetSummary,
                threadPreview: preview.threadPreview,
                modelInput: redact ? {} : row.model_input,
                capturedAt: row.inserted_at,
              },
            },
          },
          expected: {},
        })
      );
    }
  }

  const finalItems = options.diversify
    ? diversifyCftDatasetItems(items, {
        ...(options.maxPerThread !== undefined
          ? { maxPerThread: options.maxPerThread }
          : {}),
        ...(options.maxPerTemplate !== undefined
          ? { maxPerTemplate: options.maxPerTemplate }
          : {}),
        ...(options.maxPerChannel !== undefined
          ? { maxPerChannel: options.maxPerChannel }
          : {}),
      })
    : items;

  return {
    name: options.name,
    description:
      options.description ??
      `CFT group-chat Triage shadow dataset exported at ${snapshot.exported_at} (${finalItems.length} items).`,
    items: finalItems,
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const getArg = (flag: string): string | undefined => {
    const idx = args.indexOf(flag);
    return idx >= 0 ? args[idx + 1] : undefined;
  };
  const snapshotPath = getArg("--snapshot");
  const outDir = getArg("--out-dir");
  const name = getArg("--name") ?? "cft-triage-shadow-v1";
  const redact = args.includes("--redact");
  const diversify = args.includes("--diversify");
  const workerOnly = args.includes("--worker-only");
  const nativeOnly = args.includes("--native-only");

  if (!snapshotPath || !outDir) {
    throw new Error(
      "Usage: bun run experiments/cft-triage/build-cft-triage-dataset.ts --snapshot <path> --out-dir <dir> [--name <slug>] [--redact] [--diversify] [--worker-only|--native-only]"
    );
  }

  const rawSnapshot: unknown = JSON.parse(await readFile(snapshotPath, "utf8"));
  const dataset = buildCftTriageDatasetFromSnapshot(rawSnapshot, {
    name,
    redact,
    diversify,
    includeWorker: !nativeOnly,
    includeNative: !workerOnly,
  });
  await mkdir(outDir, { recursive: true });
  const target = path.join(outDir, "dataset.json");
  await writeFile(target, JSON.stringify(dataset, null, 2), "utf8");
  console.log(`wrote ${dataset.items.length} items to ${target} (redact=${redact})`);
}
