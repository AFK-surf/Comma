import { type EvalensLogger, type Trajectory } from "@evalens/core";
import { z } from "zod";

import { AgentLongBenchTier, type RouterSingleSessionItem } from "./dataset";
import type { CodexHistoryWindowStats } from "./history";

export const ROUTER_SINGLE_SESSION_PHASES = [
  "fresh",
  "accumulated",
  "compacted",
] as const;

type RouterSingleSessionTopology = "router_worker" | "codex";
export type RouterSingleSessionPhase = (typeof ROUTER_SINGLE_SESSION_PHASES)[number];

export type RouterSingleSessionBranchResult = {
  phase: RouterSingleSessionPhase;
  isolationId: string;
  answer: string;
  answerSource: "router_conversation" | "salix_session" | "codex_app_server" | "none";
  deliveredMessageId: string | null;
  replyMessageId: string | null;
  timedOut: boolean;
  replyFailureReason: "timeout" | "undelivered_session_reply" | "model_error" | null;
  branchError: string | null;
  delegated: boolean;
  workerCreated: boolean;
  workerCount: number;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  seededMessageCount: number;
  finalMessageCount: number;
  compactedThrough: number | null;
  compactionStatus: string | null;
  compactionReason: string | null;
  compactionApplied: boolean;
  seedHash: string;
  historyWindow?: CodexHistoryWindowStats;
  durationMs: number;
};

export type RouterSingleSessionResult = {
  itemId: string;
  sourceDataset: "agentlongbench" | "longmemeval-v2";
  target: "salix_router" | "codex";
  topology: RouterSingleSessionTopology;
  branches: Record<RouterSingleSessionPhase, RouterSingleSessionBranchResult>;
  audit: {
    isolated: boolean;
    isolationCount: number;
    accumulatedSeedMatchesCompacted: boolean;
    onlyCompactedBranchCompacted: boolean;
    routerIsEvaluationTarget: boolean;
  };
};

export type BranchExecution = {
  result: RouterSingleSessionBranchResult;
  trajectories: Trajectory[];
};

export type TripleBranchRun = {
  result: RouterSingleSessionResult;
  trajectories: Trajectory[];
};

export const SalixTripleBranchRunParams = z
  .object({
    dataRoot: z.string().min(1).default("/tmp/comma-longmemeval-v2"),
    timeoutMs: z.number().int().positive().default(900_000),
  })
  .strict();

export const CodexTripleBranchRunParams = z
  .object({
    dataRoot: z.string().min(1).default("/tmp/comma-longmemeval-v2"),
    model: z.string().min(1).default("gpt-5.5"),
    reasoningEffort: z.enum(["low", "medium", "high", "xhigh"]).default("medium"),
    timeoutMs: z.number().int().positive().default(900_000),
  })
  .strict();

export const SalixAgentLongBenchRunParams = SalixTripleBranchRunParams.extend({
  tier: AgentLongBenchTier.default("32k"),
});

export const CodexAgentLongBenchRunParams = CodexTripleBranchRunParams.extend({
  tier: AgentLongBenchTier.default("32k"),
});

export async function executeTripleBranch(input: {
  item: RouterSingleSessionItem;
  target: RouterSingleSessionResult["target"];
  topology: RouterSingleSessionTopology;
  runBranch: (phase: RouterSingleSessionPhase) => Promise<BranchExecution>;
}): Promise<TripleBranchRun> {
  const runs = await runParallelBranches(
    ROUTER_SINGLE_SESSION_PHASES.map((phase) => () => input.runBranch(phase))
  );
  const branches = Object.fromEntries(
    runs.map(({ result }) => [result.phase, result])
  ) as RouterSingleSessionResult["branches"];
  const result = buildTripleBranchResult({
    item: input.item,
    target: input.target,
    topology: input.topology,
    branches,
  });
  assertTripleBranchIsolation(result);
  return {
    result,
    trajectories: runs.flatMap((run) => run.trajectories),
  };
}

export async function runParallelBranches<T>(
  branches: readonly (() => Promise<T>)[]
): Promise<T[]> {
  const settled = await Promise.allSettled(branches.map((runBranch) => runBranch()));
  const errors = settled.flatMap((result) =>
    result.status === "rejected" ? [result.reason] : []
  );
  if (errors.length > 0) {
    const details = errors
      .map((error) => (error instanceof Error ? error.message : String(error)))
      .join("; ");
    throw new AggregateError(
      errors,
      `${errors.length} parallel single-session branch(es) failed: ${details}`
    );
  }
  return settled.map((result) => {
    if (result.status !== "fulfilled") {
      throw new Error("parallel branch settlement invariant failed");
    }
    return result.value;
  });
}

export function transcriptSourcePrefix(
  itemId: string,
  phase: RouterSingleSessionPhase
): string {
  const historyVariant = phase === "fresh" ? "current" : "prior-plus-current";
  return `evalens:${itemId}:${historyVariant}`;
}

function assertTripleBranchIsolation(result: RouterSingleSessionResult): void {
  if (!result.audit.isolated) {
    throw new Error("Fresh, accumulated, and compacted branches are not isolated");
  }
  if (!result.audit.accumulatedSeedMatchesCompacted) {
    throw new Error("Accumulated and compacted branches received different history");
  }
  if (!result.audit.onlyCompactedBranchCompacted) {
    throw new Error("Exactly the compacted branch must receive explicit compaction");
  }
}

export function logRunDiagnostics(
  logger: EvalensLogger,
  result: RouterSingleSessionResult
): void {
  logger.info(
    {
      event: "router_single_session_branches_completed",
      target: result.target,
      topology: result.topology,
      audit: result.audit,
      branches: Object.fromEntries(
        Object.entries(result.branches).map(([phase, branch]) => [
          phase,
          branchDiagnostics(branch),
        ])
      ),
    },
    "single-session branch diagnostics"
  );
}

function branchDiagnostics(branch: RouterSingleSessionBranchResult) {
  return {
    answerSource: branch.answerSource,
    timedOut: branch.timedOut,
    replyFailureReason: branch.replyFailureReason,
    branchError: branch.branchError,
    delegated: branch.delegated,
    workerCreated: branch.workerCreated,
    workerCount: branch.workerCount,
    promptTokens: branch.promptTokens,
    completionTokens: branch.completionTokens,
    totalTokens: branch.totalTokens,
    seededMessageCount: branch.seededMessageCount,
    finalMessageCount: branch.finalMessageCount,
    compactedThrough: branch.compactedThrough,
    compactionStatus: branch.compactionStatus,
    compactionReason: branch.compactionReason,
    historyWindow: branch.historyWindow,
    durationMs: branch.durationMs,
  };
}

function buildTripleBranchResult(input: {
  item: RouterSingleSessionItem;
  target: RouterSingleSessionResult["target"];
  topology: RouterSingleSessionTopology;
  branches: RouterSingleSessionResult["branches"];
}): RouterSingleSessionResult {
  const isolationIds = ROUTER_SINGLE_SESSION_PHASES.map(
    (phase) => input.branches[phase].isolationId
  );
  return {
    itemId: input.item.id,
    sourceDataset: input.item.source.dataset,
    target: input.target,
    topology: input.topology,
    branches: input.branches,
    audit: {
      isolated: new Set(isolationIds).size === ROUTER_SINGLE_SESSION_PHASES.length,
      isolationCount: new Set(isolationIds).size,
      accumulatedSeedMatchesCompacted:
        input.branches.accumulated.seedHash === input.branches.compacted.seedHash,
      onlyCompactedBranchCompacted:
        !input.branches.fresh.compactionApplied &&
        !input.branches.accumulated.compactionApplied &&
        input.branches.compacted.compactionApplied,
      routerIsEvaluationTarget: input.target === "salix_router",
    },
  };
}
