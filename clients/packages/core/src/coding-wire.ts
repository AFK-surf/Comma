// How the Comma API writes a coding Session's pull request and token use: in the answers of the coding calls
// (coding.ts), and in what a coding Task's run keeps of them (`facts`, comma/api-schemas.ts).
import { z } from "zod";
import type { CodingPullRequest } from "./contract.ts";

/** The branch's pull request as Comma reads it from GitHub. */
export const pullRequestSchema = z.object({
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
});

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

/** The tokens a Session's model calls used, as its station counts them. */
export const usageSchema = z.object({
  modelCalls: z.number(),
  inputTokens: z.number(),
  cachedTokens: z.number(),
  outputTokens: z.number(),
  model: z.string().nullable(),
});
