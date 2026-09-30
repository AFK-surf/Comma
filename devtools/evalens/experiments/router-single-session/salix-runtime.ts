import { SalixAdapter, type Salix } from "@evalens/adapters/salix";
import type { Trajectory } from "@evalens/core";

import {
  executeTripleBranch,
  transcriptSourcePrefix,
  type BranchExecution,
  type RouterSingleSessionPhase,
  type TripleBranchRun,
} from "./contracts";
import type { RouterSingleSessionItem } from "./dataset";
import {
  rawTrajectoryIdsForPhase,
  readRawTrajectory,
  salixHistoryForPhase,
  salixWindowedHistoryForPhase,
  sha256Text,
  type CodexHistoryWindowStats,
  type SalixWindowedHistory,
} from "./history";

export function runSalixSingleSession(input: {
  salix: SalixAdapter;
  item: RouterSingleSessionItem;
  template: string;
  dataRoot: string;
  timeoutMs: number;
  historyTokenBudget?: number;
}): Promise<TripleBranchRun> {
  const preparedLongHistory =
    input.historyTokenBudget === undefined
      ? undefined
      : salixWindowedHistoryForPhase(
          input.item,
          "accumulated",
          input.historyTokenBudget
        );
  return executeTripleBranch({
    item: input.item,
    target: "salix_router",
    topology: "router_worker",
    runBranch: (phase) =>
      runSalixBranch({
        salix: input.salix,
        item: input.item,
        template: input.template,
        dataRoot: input.dataRoot,
        timeoutMs: input.timeoutMs,
        phase,
        preparedHistory: phase === "fresh" ? undefined : preparedLongHistory,
      }),
  });
}

async function runSalixBranch(input: {
  salix: SalixAdapter;
  item: RouterSingleSessionItem;
  template: string;
  dataRoot: string;
  timeoutMs: number;
  phase: RouterSingleSessionPhase;
  preparedHistory?: SalixWindowedHistory;
}): Promise<BranchExecution> {
  const { salix, item, phase } = input;
  const branchStartedAt = new Date();
  const agents: NonNullable<Salix.EvalFixture["agents"]> = [
    { role: "router", template: input.template },
    { role: "worker", ref: "available-worker", template: input.template },
  ];
  const prepared = await salix.runs.prepareRun({
    name: `single-session-${item.id}-router-worker-${phase}`,
    agents,
  });
  const target = salix.runs.agentSession(prepared, { role: "router" });
  const sourcePrefix = transcriptSourcePrefix(item.id, phase);
  let seededMessageCount = 0;
  let seedHash = "";
  let compactionStatus: string | null = null;
  let compactionReason: string | null = null;
  let observedWorkerIds: string[] = [];
  const startedAt = performance.now();

  try {
    const seeded = await seedSalixBranchHistory({
      salix,
      target,
      item,
      phase,
      dataRoot: input.dataRoot,
      sourcePrefix,
      preparedHistory: input.preparedHistory,
    });
    seededMessageCount = seeded.count;
    seedHash = seeded.hash;
    if (phase === "compacted") {
      const compact = await salix.transcripts.compactAgentSession({
        agentId: target.agentId,
        sessionId: target.sessionId,
      });
      compactionStatus = compact.status ?? "unknown";
      compactionReason = compact.reason ?? null;
    }

    const turnStartedAt = new Date();
    const turn = await salix.sessions.runSessionTurn({
      target,
      turnId: `router-single-session:${item.id}`,
      message: item.input.probe.message,
      routerDeliveryMode: "direct_session",
      pollMs: 500,
      timeoutMs: input.timeoutMs,
      traceLimit: item.input.rawHistory ? 10 : 500,
      messageLimit: item.input.rawHistory ? 10 : undefined,
    });
    const turnFinishedAt = new Date();

    const workers = await salix.runs.listWorkers({ groupId: prepared.groupId });
    observedWorkerIds = workers.map((worker) => worker.agentId);
    const answer = turn.answer ?? "";
    const replyMessageId = turn.replyWait.replyMessageId ?? null;
    const answerSource = turn.replyWait.answerSource;
    if (
      !turn.replyWait.timedOut &&
      (!answer.trim() || !replyMessageId || answerSource !== "session_transcript")
    ) {
      throw new Error(
        "router turn completed without an auditable session reply message"
      );
    }

    // Workers remain part of the natural topology, but only Router output,
    // trace, and usage are evaluation targets.
    const routerTrace = turn.trace;
    const toolNames = (routerTrace.execution.tool_calls ?? []).map(normalizedToolName);
    const usage = {
      promptTokens: routerTrace.execution.usage?.prompt_tokens ?? 0,
      completionTokens: routerTrace.execution.usage?.completion_tokens ?? 0,
      totalTokens: routerTrace.execution.usage?.total_tokens ?? 0,
    };

    return {
      result: {
        phase,
        isolationId: prepared.groupId,
        answer,
        answerSource: answerSource === "session_transcript" ? "salix_session" : "none",
        deliveredMessageId: turn.delivery.messageId ?? null,
        replyMessageId,
        timedOut: turn.replyWait.timedOut === true,
        replyFailureReason: turn.replyWait.failureReason ?? null,
        branchError: null,
        delegated: toolNames.includes("im_api.internal.task.create"),
        workerCreated: toolNames.includes("agent.create_worker") || workers.length > 1,
        workerCount: workers.length,
        ...usage,
        seededMessageCount,
        finalMessageCount:
          routerTrace.session.messageCount ?? routerTrace.session.messages.length,
        compactedThrough: routerTrace.session.compactedThrough ?? null,
        compactionStatus,
        compactionReason,
        compactionApplied: phase === "compacted",
        seedHash,
        historyWindow: seeded.historyWindow,
        durationMs: Math.max(0, Math.round(performance.now() - startedAt)),
      },
      trajectories: [
        retimeSalixBranchTrajectory({
          trajectory: turn.trajectory,
          probe: item.input.probe.message,
          answer,
          branchStartedAt,
          turnStartedAt,
          turnFinishedAt,
        }),
      ],
    };
  } finally {
    if (observedWorkerIds.length === 0) {
      try {
        observedWorkerIds = (
          await salix.runs.listWorkers({ groupId: prepared.groupId })
        ).map((worker) => worker.agentId);
      } catch {
        // cleanupRun will surface an actionable error if cleanup also fails.
      }
    }
    prepared.cleanupPlan.agentIds = [
      ...new Set([...(prepared.cleanupPlan.agentIds ?? []), ...observedWorkerIds]),
    ];
    await salix.runs.cleanupRun(prepared);
  }
}

export function retimeSalixBranchTrajectory(input: {
  trajectory: Trajectory;
  probe: string;
  answer: string;
  branchStartedAt: Date;
  turnStartedAt: Date;
  turnFinishedAt: Date;
}): Trajectory {
  const probeIndex = input.trajectory.steps.findLastIndex(
    (step) => step.type === "user" && step.content === input.probe
  );
  const answerIndex = input.trajectory.steps.findLastIndex(
    (step) => step.type === "assistant" && step.content === input.answer
  );
  const branchStartMs = input.branchStartedAt.getTime();
  const turnFinishMs = input.turnFinishedAt.getTime();

  return {
    ...input.trajectory,
    steps: input.trajectory.steps
      .map((step, index) => {
        if (index === probeIndex) {
          return { ...step, timestamp: input.turnStartedAt };
        }
        if (index === answerIndex) {
          return { ...step, timestamp: input.turnFinishedAt };
        }
        if (step.type !== "tool_call" && step.type !== "tool_result") {
          return {
            ...step,
            timestamp:
              probeIndex >= 0 && index > probeIndex
                ? input.turnStartedAt
                : input.branchStartedAt,
          };
        }
        return {
          ...step,
          timestamp: new Date(
            Math.min(turnFinishMs, Math.max(branchStartMs, step.timestamp.getTime()))
          ),
        };
      })
      .toSorted((left, right) => left.timestamp.getTime() - right.timestamp.getTime()),
  };
}

type SeededBranchHistory = {
  count: number;
  hash: string;
  historyWindow?: CodexHistoryWindowStats;
};

async function seedSalixBranchHistory(input: {
  salix: SalixAdapter;
  target: Salix.PreparedAgentSession;
  item: RouterSingleSessionItem;
  phase: RouterSingleSessionPhase;
  dataRoot: string;
  sourcePrefix: string;
  preparedHistory?: SalixWindowedHistory;
}): Promise<SeededBranchHistory> {
  if (!input.item.input.rawHistory) {
    const history =
      input.preparedHistory?.entries ?? salixHistoryForPhase(input.item, input.phase);
    const entries = input.salix.transcripts.buildTranscriptSeedEntries(history, {
      sourcePrefix: input.sourcePrefix,
    });
    await input.salix.transcripts.seedAgentTranscript({
      agentId: input.target.agentId,
      sessionId: input.target.sessionId,
      sourceId: input.sourcePrefix,
      entries,
    });
    return {
      count: entries.length,
      hash: sha256Text(JSON.stringify(entries)),
      historyWindow: input.preparedHistory?.stats,
    };
  }

  const ids = rawTrajectoryIdsForPhase(input.item, input.phase);
  const hasher = new Bun.CryptoHasher("sha256");
  const seedId = `evalens-${sha256Text(input.sourcePrefix).slice(0, 32)}`;
  for (const [index, trajectoryId] of ids.entries()) {
    const content = await readRawTrajectory(input.dataRoot, trajectoryId);
    const sourceMessageId = `${input.sourcePrefix}:${index + 1}`;
    const entry: Salix.TranscriptSeedEntry = {
      role: "runtime",
      type: "longmemeval-v2.trajectory-json",
      content,
      sourceMessageId,
      dedupeKey: sourceMessageId,
      sourceRefs: {
        dataset: "longmemeval-v2",
        trajectory_id: trajectoryId,
        source_format: input.item.input.rawHistory.format,
        source_index: index,
      },
    };
    hasher.update(JSON.stringify(entry));
    hasher.update("\n");
    await input.salix.transcripts.stageAgentTranscriptBatch({
      agentId: input.target.agentId,
      sessionId: input.target.sessionId,
      seedId,
      batchIndex: index,
      sourceId: input.sourcePrefix,
      entries: [entry],
    });
  }
  await input.salix.transcripts.finalizeAgentTranscriptBatches({
    agentId: input.target.agentId,
    sessionId: input.target.sessionId,
    seedId,
    expectedBatchCount: ids.length,
  });
  return { count: ids.length, hash: hasher.digest("hex") };
}

function normalizedToolName(
  call: NonNullable<Salix.AgentSessionTrace["tool_calls"]>[number]
): string {
  if (call.name && call.name !== "call") return call.name;
  if (!call.input) return call.name ?? "unknown";
  try {
    const parsed = JSON.parse(call.input) as Record<string, unknown>;
    const nested = parsed.tool ?? parsed.name;
    return typeof nested === "string" ? nested : (call.name ?? "unknown");
  } catch {
    return call.name ?? "unknown";
  }
}
