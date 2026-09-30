import type { CodexAdapterConfig } from "@evalens/adapters/config";
import {
  CodexAppServerAdapter,
  type CodexAppServerHistoryItem,
} from "@evalens/adapters/codex";

import {
  executeTripleBranch,
  type BranchExecution,
  type RouterSingleSessionPhase,
  type TripleBranchRun,
} from "./contracts";
import type { RouterSingleSessionItem } from "./dataset";
import {
  codexHistoryForPhase,
  codexWindowedHistoryForPhase,
  rawTrajectoryIdsForPhase,
  readRawTrajectory,
  sha256Text,
  type CodexHistoryWindowStats,
  type CodexWindowedHistory,
} from "./history";

export function runCodexSingleSession(input: {
  item: RouterSingleSessionItem;
  adapterConfig: CodexAdapterConfig;
  dataRoot: string;
  model: string;
  reasoningEffort: string;
  timeoutMs: number;
  historyTokenBudget?: number;
}): Promise<TripleBranchRun> {
  const historyByPhase = prepareCodexBranchHistories(
    input.item,
    input.historyTokenBudget
  );
  return executeTripleBranch({
    item: input.item,
    target: "codex",
    topology: "codex",
    runBranch: (phase) =>
      runCodexBranch({
        ...input,
        phase,
        preparedHistory: historyByPhase?.[phase],
      }),
  });
}

type SeededBranchHistory = {
  count: number;
  hash: string;
  historyWindow?: CodexHistoryWindowStats;
};

async function seedCodexBranchHistory(input: {
  adapter: CodexAppServerAdapter;
  threadId: string;
  item: RouterSingleSessionItem;
  phase: RouterSingleSessionPhase;
  dataRoot: string;
  preparedHistory?: CodexWindowedHistory;
}): Promise<SeededBranchHistory> {
  if (input.preparedHistory) {
    await input.adapter.injectItems(input.threadId, input.preparedHistory.items);
    return {
      count: input.preparedHistory.items.length,
      hash: sha256Text(JSON.stringify(input.preparedHistory.items)),
      historyWindow: input.preparedHistory.stats,
    };
  }
  if (!input.item.input.rawHistory) {
    const history = codexHistoryForPhase(input.item, input.phase);
    await input.adapter.injectItems(input.threadId, history);
    return {
      count: history.length,
      hash: sha256Text(JSON.stringify(history)),
    };
  }

  const ids = rawTrajectoryIdsForPhase(input.item, input.phase);
  const hasher = new Bun.CryptoHasher("sha256");
  for (const trajectoryId of ids) {
    const content = await readRawTrajectory(input.dataRoot, trajectoryId);
    const historyItem: CodexAppServerHistoryItem = {
      type: "message",
      role: "system",
      content: [{ type: "input_text", text: content }],
    };
    hasher.update(JSON.stringify(historyItem));
    hasher.update("\n");
    await input.adapter.injectItems(input.threadId, [historyItem]);
  }

  return {
    count: ids.length,
    hash: hasher.digest("hex"),
  };
}

async function runCodexBranch(input: {
  item: RouterSingleSessionItem;
  adapterConfig: CodexAdapterConfig;
  dataRoot: string;
  model: string;
  reasoningEffort: string;
  timeoutMs: number;
  phase: RouterSingleSessionPhase;
  preparedHistory?: CodexWindowedHistory;
}): Promise<BranchExecution> {
  const branchStartedMs = performance.now();
  const adapter = new CodexAppServerAdapter({
    ...input.adapterConfig,
    sandbox: "read-only",
    approvalPolicy: "never",
    model: input.model,
    ephemeral: true,
    requestTimeoutMs: input.timeoutMs,
    trajectoryHistoryMode: input.item.input.rawHistory ? "digest" : "full",
  });
  let threadId: string | undefined;
  let seeded: SeededBranchHistory = {
    count: 0,
    hash: "",
    historyWindow: input.preparedHistory?.stats,
  };
  let compactionStatus: string | null = null;
  let probeStartedAt: Date | undefined;
  try {
    const thread = await adapter.startThread({
      model: input.model,
      reasoningEffort: input.reasoningEffort,
      baseInstructions:
        "Answer the next user question only from the model-visible thread history. Do not use tools or external information.",
      developerInstructions:
        "Preserve the benchmark's requested answer format. Do not describe the evaluation setup.",
    });
    threadId = thread.threadId;
    seeded = await seedCodexBranchHistory({
      adapter,
      threadId: thread.threadId,
      item: input.item,
      phase: input.phase,
      dataRoot: input.dataRoot,
      preparedHistory: input.preparedHistory,
    });
    if (input.phase === "compacted") {
      compactionStatus = "started";
      await adapter.compactThread(thread.threadId, input.timeoutMs);
      compactionStatus = "completed";
    }
    probeStartedAt = new Date();
    const turn = await adapter.runTurn({
      threadId: thread.threadId,
      message: input.item.input.probe.message,
      model: input.model,
      reasoningEffort: input.reasoningEffort,
      timeoutMs: input.timeoutMs,
    });
    return {
      result: {
        phase: input.phase,
        isolationId: thread.threadId,
        answer: turn.answer,
        answerSource: "codex_app_server",
        deliveredMessageId: turn.turnId,
        replyMessageId: turn.turnId,
        timedOut: false,
        replyFailureReason: null,
        branchError: null,
        delegated: false,
        workerCreated: false,
        workerCount: 0,
        promptTokens: turn.inputTokens,
        completionTokens: turn.outputTokens,
        totalTokens: turn.totalTokens,
        seededMessageCount: seeded.count,
        finalMessageCount: seeded.count + 2,
        compactedThrough: null,
        compactionStatus,
        compactionReason: null,
        compactionApplied: input.phase === "compacted",
        seedHash: seeded.hash,
        historyWindow: seeded.historyWindow,
        durationMs: turn.durationMs,
      },
      trajectories: [turn.trajectory],
    };
  } catch (error) {
    if (!threadId || !isCodexContextWindowExceeded(error)) throw error;
    const finishedAt = new Date();
    const message = error instanceof Error ? error.message : String(error);
    const turnStartedAt = probeStartedAt ?? finishedAt;
    return {
      result: {
        phase: input.phase,
        isolationId: threadId,
        answer: "",
        answerSource: "none",
        deliveredMessageId: null,
        replyMessageId: null,
        timedOut: false,
        replyFailureReason: "model_error",
        branchError: message,
        delegated: false,
        workerCreated: false,
        workerCount: 0,
        promptTokens: 0,
        completionTokens: 0,
        totalTokens: 0,
        seededMessageCount: seeded.count,
        finalMessageCount: seeded.count + (probeStartedAt ? 1 : 0),
        compactedThrough: null,
        compactionStatus:
          input.phase === "compacted" ? "failed_context_window" : compactionStatus,
        compactionReason: message,
        compactionApplied: input.phase === "compacted",
        seedHash: seeded.hash,
        historyWindow: seeded.historyWindow,
        durationMs: Math.max(0, Math.round(performance.now() - branchStartedMs)),
      },
      trajectories: [
        adapter.createTrajectory({
          threadId,
          turnId: `failed-${input.phase}`,
          message: probeStartedAt ? input.item.input.probe.message : undefined,
          failure: message,
          model: input.model,
          startedAt: turnStartedAt,
          finishedAt,
        }),
      ],
    };
  } finally {
    await adapter.close();
  }
}

function prepareCodexBranchHistories(
  item: RouterSingleSessionItem,
  tokenBudget: number | undefined
): Partial<Record<RouterSingleSessionPhase, CodexWindowedHistory>> | undefined {
  if (tokenBudget === undefined) return undefined;
  if (item.input.rawHistory) {
    throw new Error("Fixed Codex history windows do not support raw trajectory items");
  }
  const accumulated = codexWindowedHistoryForPhase(item, "accumulated", tokenBudget);
  return {
    accumulated,
    compacted: accumulated,
  };
}

function isCodexContextWindowExceeded(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.message.includes('"codexErrorInfo":"contextWindowExceeded"') ||
      error.message.toLowerCase().includes("context window"))
  );
}
