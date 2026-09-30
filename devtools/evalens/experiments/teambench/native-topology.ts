import type { CodexAppServerThreadRecord } from "@evalens/adapters/codex";
import type { Salix } from "@evalens/adapters/salix";

import type { TeamBenchNativeResult } from "./contracts";

export function salixNativeTopology(input: {
  taskCreateObserved: boolean;
  workerSessions: readonly Salix.WorkerSessionRef[];
  respondingAgentIds: readonly string[];
  executorAgentId: string;
  verifierAgentId: string;
  settled: boolean;
}): {
  delegated: boolean;
  executorSessionIds: string[];
  verifierSessionIds: string[];
  violations: string[];
} {
  const executorSessionIds = sessionIdsForAgent(
    input.workerSessions,
    input.executorAgentId
  );
  const verifierSessionIds = sessionIdsForAgent(
    input.workerSessions,
    input.verifierAgentId
  );
  const respondingAgentIds = new Set(input.respondingAgentIds);
  const violations: string[] = [];

  if (!input.taskCreateObserved) violations.push("planner_did_not_delegate");
  if (executorSessionIds.length === 0) violations.push("executor_not_started");
  if (verifierSessionIds.length === 0) violations.push("verifier_not_started");
  if (!respondingAgentIds.has(input.executorAgentId)) {
    violations.push("executor_reply_not_observed");
  }
  if (!respondingAgentIds.has(input.verifierAgentId)) {
    violations.push("verifier_reply_not_observed");
  }
  if (!input.settled) violations.push("workers_unsettled_at_planner_return");

  return {
    delegated:
      input.taskCreateObserved &&
      executorSessionIds.length > 0 &&
      verifierSessionIds.length > 0,
    executorSessionIds,
    verifierSessionIds,
    violations,
  };
}

export function codexNativeTopologyViolations(input: {
  threads: readonly CodexAppServerThreadRecord[];
  agents: TeamBenchNativeResult["agents"];
  delegated: boolean;
  settled: boolean;
}): string[] {
  const violations: string[] = [];
  if (!input.delegated) violations.push("planner_did_not_delegate");

  const counts = new Map<TeamBenchNativeResult["agents"][number]["role"], number>();
  for (const agent of input.agents) {
    counts.set(agent.role, (counts.get(agent.role) ?? 0) + 1);
  }
  for (const role of ["planner", "executor", "verifier"] as const) {
    if (counts.get(role) !== 1) {
      violations.push(`expected_one_${role}_observed_${counts.get(role) ?? 0}`);
    }
  }
  if (!input.settled) violations.push("workers_unsettled_at_planner_return");

  const executor = input.threads.find((thread) => thread.agentRole === "executor");
  const verifier = input.threads.find((thread) => thread.agentRole === "verifier");
  const executorCompletedAt = executorCompletionTime(executor);
  if (executor && executorCompletedAt === undefined) {
    violations.push("executor_completion_not_observed");
  }
  if (verifier && verifier.createdAt === undefined) {
    violations.push("verifier_start_not_observed");
  }
  if (
    executorCompletedAt !== undefined &&
    verifier?.createdAt !== undefined &&
    verifier.createdAt < executorCompletedAt
  ) {
    violations.push("verifier_started_before_executor_completed");
  }
  return violations;
}

function sessionIdsForAgent(
  sessions: readonly Salix.WorkerSessionRef[],
  agentId: string
): string[] {
  return sessions
    .filter((session) => session.agentId === agentId)
    .map((session) => session.sessionId);
}

function executorCompletionTime(
  thread: CodexAppServerThreadRecord | undefined
): number | undefined {
  const turns = thread?.turns ?? [];
  if (
    turns.length === 0 ||
    turns.some((turn) => turn.status !== "completed" || turn.completedAt == null)
  ) {
    return undefined;
  }
  return Math.max(...turns.map((turn) => turn.completedAt!));
}
