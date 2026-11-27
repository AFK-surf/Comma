// How the Comma API writes a coding Session's pull request and token use: in the answers of the coding calls
// (coding.ts), and in what a coding Task's run keeps of them (`facts`, comma/api-schemas.ts).
import { lazySchema } from "@comma/chat-contract";
import { z } from "zod";
import type { CodingPullRequest, CodingUsage } from "./contract.ts";

/** The branch's pull request as Comma reads it from GitHub. */
export const pullRequestSchema = lazySchema(() =>
  z.object({
    url: z.string(),
    number: z.number().nullish(),
    title: z.string().nullish(),
    body: z.string().nullish(),
    head_sha: z.string().nullish(),
    state: z.enum(["open", "draft", "merged", "closed"]),
    mergeable: z.enum(["mergeable", "conflicting", "unknown"]).nullish(),
    checks: z
      .object({
        passed: z.number(),
        failed: z.number().optional(),
        skipped: z.number().optional(),
        total: z.number(),
      })
      .nullish(),
    new_commits: z.boolean().nullish(),
  })
);

export const toPullRequest = (
  pr: z.output<typeof pullRequestSchema>
): CodingPullRequest => ({
  url: pr.url,
  number: pr.number ?? null,
  title: pr.title ?? null,
  body: pr.body ?? null,
  headSha: pr.head_sha ?? null,
  state: pr.state,
  mergeable: pr.mergeable ?? "unknown",
  checks: pr.checks
    ? {
        passed: pr.checks.passed,
        failed: pr.checks.failed ?? 0,
        skipped: pr.checks.skipped ?? 0,
        total: pr.checks.total,
      }
    : null,
  newCommits: pr.new_commits ?? false,
});

const leafUsageSchema = lazySchema(() =>
  z
    .object({
      modelCalls: z.number(),
      inputTokens: z.number(),
      cachedTokens: z.number(),
      outputTokens: z.number(),
      model: z.string().nullable(),
    })
    .strip()
);

const modelUsageCountsSchema = lazySchema(() =>
  z
    .object({
      modelCalls: z.number().optional(),
      inputTokens: z.number().optional(),
      cachedTokens: z.number().optional(),
      outputTokens: z.number().optional(),
    })
    .strip()
);

const slotUsageSchema = lazySchema(() =>
  z
    .object({
      slot: z.string().optional(),
      is_primary: z.boolean().optional(),
      unreadable: z.boolean().optional(),
      partial: z.boolean().optional(),
      usage: leafUsageSchema.nullable().optional(),
      modelCalls: z.number().optional(),
      inputTokens: z.number().optional(),
      cachedTokens: z.number().optional(),
      outputTokens: z.number().optional(),
      model: z.string().nullable().optional(),
    })
    .strip()
);

/** The tokens a Session's model calls used, as its station counts them (explicit public whitelist). */
export const usageSchema = lazySchema(() =>
  z
    .object({
      modelCalls: z.number(),
      inputTokens: z.number(),
      cachedTokens: z.number(),
      outputTokens: z.number(),
      model: z.string().nullable(),
      models: z
        .union([
          z.array(z.string()),
          z.record(z.string(), z.union([z.number(), modelUsageCountsSchema])),
        ])
        .optional(),
      partial: z.boolean().optional(),
      by_slot: z.record(z.string(), slotUsageSchema).optional(),
    })
    .strip()
);

export const toCodingUsage = (
  wire: z.output<typeof usageSchema> | null | undefined
): CodingUsage | null => {
  if (!wire) return null;
  const models = Array.isArray(wire.models)
    ? wire.models.filter((m) => m.length > 0)
    : wire.models && typeof wire.models === "object"
      ? Object.keys(wire.models).filter((m) => m.length > 0)
      : undefined;
  return {
    modelCalls: wire.modelCalls,
    inputTokens: wire.inputTokens,
    cachedTokens: wire.cachedTokens,
    outputTokens: wire.outputTokens,
    model: wire.model,
    ...(models && models.length > 0 ? { models } : {}),
    ...(wire.partial === true ? { partial: true } : {}),
    ...(wire.by_slot
      ? {
          bySlot: Object.fromEntries(
            Object.entries(wire.by_slot).map(([slot, entry]) => [
              slot,
              {
                slot: entry.slot ?? slot,
                ...(entry.is_primary !== undefined
                  ? { isPrimary: entry.is_primary }
                  : {}),
                ...(entry.unreadable === true ? { unreadable: true } : {}),
                ...(entry.partial === true ? { partial: true } : {}),
                ...(entry.usage !== undefined ? { usage: entry.usage } : {}),
                ...(entry.usage
                  ? {
                      modelCalls: entry.usage.modelCalls,
                      inputTokens: entry.usage.inputTokens,
                      cachedTokens: entry.usage.cachedTokens,
                      outputTokens: entry.usage.outputTokens,
                      model: entry.usage.model,
                    }
                  : {
                      ...(entry.modelCalls !== undefined
                        ? { modelCalls: entry.modelCalls }
                        : {}),
                      ...(entry.inputTokens !== undefined
                        ? { inputTokens: entry.inputTokens }
                        : {}),
                      ...(entry.cachedTokens !== undefined
                        ? { cachedTokens: entry.cachedTokens }
                        : {}),
                      ...(entry.outputTokens !== undefined
                        ? { outputTokens: entry.outputTokens }
                        : {}),
                      ...(entry.model !== undefined ? { model: entry.model } : {}),
                    }),
              },
            ])
          ),
        }
      : {}),
  };
};
