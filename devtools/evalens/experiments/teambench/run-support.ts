import type { Salix, SalixAdapter } from "@evalens/adapters/salix";
import type { Trajectory } from "@evalens/core";

import type { ArchivedFile } from "./shared";

export async function stageSalixTeamBenchFiles(input: {
  salix: SalixAdapter;
  taskAgentIds: readonly string[];
  workspaceAgentIds: readonly string[];
  spec: ArchivedFile;
  brief: ArchivedFile;
  taskFiles: readonly ArchivedFile[];
  workspaceFiles: readonly ArchivedFile[];
}): Promise<void> {
  const taskFiles = [
    { path: "spec.md", data: input.spec.data },
    { path: "brief.md", data: input.brief.data },
    ...input.taskFiles,
  ];
  await Promise.all([
    ...input.taskAgentIds.flatMap((agentId) =>
      taskFiles.map((file) =>
        input.salix.files.writeAgentFile({
          agentId,
          path: `/task/${file.path}`,
          data: file.data,
        })
      )
    ),
    ...input.workspaceAgentIds.flatMap((agentId) =>
      input.workspaceFiles.map((file) =>
        input.salix.files.writeAgentFile({
          agentId,
          path: `/workspace/${file.path}`,
          data: file.data,
        })
      )
    ),
  ]);
}

export async function collectSalixTeamBenchArtifacts(input: {
  salix: SalixAdapter;
  workerSessions: readonly Salix.WorkerSessionRef[];
  executorAgentId: string;
  verifierAgentId: string;
  traceLimit: number;
  maxArtifactFiles: number;
  maxArtifactBytes: number;
}): Promise<{
  workerTrajectories: Trajectory[];
  respondingWorkerAgentIds: string[];
  executorFiles: Salix.AgentFilesDownloadArtifact;
  verifierFiles: Salix.AgentFilesDownloadArtifact;
}> {
  const [workerTraces, executorFiles, verifierFiles] = await Promise.all([
    Promise.all(
      input.workerSessions.map((session) =>
        input.salix.sessions.collectSessionTrace({
          agentId: session.agentId,
          sessionId: session.sessionId,
          traceLimit: input.traceLimit,
        })
      )
    ),
    input.salix.files.downloadAgentFiles({
      agentId: input.executorAgentId,
      path: "/workspace",
      maxFiles: input.maxArtifactFiles,
      maxTotalBytes: input.maxArtifactBytes,
    }),
    input.salix.files.downloadAgentFiles({
      agentId: input.verifierAgentId,
      path: "/submission",
      maxFiles: input.maxArtifactFiles,
      maxTotalBytes: input.maxArtifactBytes,
    }),
  ]);
  assertCompleteDownload("Executor workspace", executorFiles);
  assertCompleteDownload("Verifier submission", verifierFiles, true);
  return {
    workerTrajectories: workerTraces.map(({ trajectory }) => trajectory),
    respondingWorkerAgentIds: workerTraces.flatMap(({ trace }) =>
      trace.session.messages.some(
        (message) => message.role === "assistant" && Boolean(message.content)
      )
        ? [trace.identity.agentId]
        : []
    ),
    executorFiles,
    verifierFiles,
  };
}

export function assertCompleteDownload(
  label: string,
  download: Salix.AgentFilesDownloadArtifact,
  allowMissingRoot = false
): void {
  const ignorableMissingRoot =
    allowMissingRoot &&
    download.files.length === 0 &&
    download.errors.length === 1 &&
    /404|not found/iu.test(download.errors[0]?.message ?? "");
  if (download.truncated || (download.errors.length > 0 && !ignorableMissingRoot)) {
    throw new Error(
      `${label} snapshot is incomplete: ${JSON.stringify({
        truncated: download.truncated,
        errors: download.errors,
      })}`
    );
  }
}

export function assertObservedModel(
  trajectories: readonly Trajectory[],
  expectedModel: string
): void {
  const assistantSteps = trajectories.flatMap((trajectory) =>
    trajectory.steps.filter((step) => step.type === "assistant")
  );
  if (assistantSteps.length === 0) {
    throw new Error("native run did not expose any assistant model evidence");
  }
  if (assistantSteps.some((step) => !step.model)) {
    throw new Error("native run contains an assistant response without model evidence");
  }
  const observed = new Set(assistantSteps.map((step) => step.model!));
  const mismatches = [...observed].filter((model) => model !== expectedModel);
  if (mismatches.length > 0) {
    throw new Error(
      `native run observed an unexpected model: ${mismatches.join(", ")}`
    );
  }
}

export function salixWorkerState(sessions: readonly Salix.WorkerSessionRef[]): {
  settled: boolean;
  active: string[];
  systemError: string[];
  unknown: string[];
} {
  const terminal = new Set([
    "idle",
    "ready",
    "completed",
    "complete",
    "done",
    "failed",
    "errored",
    "error",
    "cancelled",
    "canceled",
  ]);
  const failed = new Set(["failed", "errored", "error"]);
  const active: string[] = [];
  const systemError: string[] = [];
  const unknown: string[] = [];
  for (const session of sessions) {
    const id = `${session.agentId}:${session.sessionId}`;
    const status = session.status?.toLowerCase();
    if (!status) {
      unknown.push(id);
    } else if (failed.has(status)) {
      systemError.push(id);
    } else if (!terminal.has(status)) {
      active.push(id);
    }
  }
  return {
    settled: active.length === 0 && unknown.length === 0,
    active,
    systemError,
    unknown,
  };
}

export async function waitForSalixWorkerSessionsSettled(
  listSessions: () => Promise<Salix.WorkerSessionRef[]>,
  input: {
    timeoutMs: number;
    pollMs: number;
    sleep?: (ms: number) => Promise<void>;
  }
): Promise<Salix.WorkerSessionRef[]> {
  const sleep = input.sleep ?? Bun.sleep;
  const deadline = performance.now() + input.timeoutMs;
  let sessions = await listSessions();
  while (sessions.length > 0 && !salixWorkerState(sessions).settled) {
    const remainingMs = deadline - performance.now();
    if (remainingMs <= 0) return sessions;
    await sleep(Math.min(input.pollMs, remainingMs));
    sessions = await listSessions();
  }
  return sessions;
}

export function dedupeTrajectories(trajectories: readonly Trajectory[]): Trajectory[] {
  const byId = new Map<string, Trajectory>();
  for (const trajectory of trajectories) {
    const existing = byId.get(trajectory.id);
    if (!existing || trajectory.steps.length > existing.steps.length) {
      byId.set(trajectory.id, trajectory);
    }
  }
  return [...byId.values()];
}

export function assertCleanupSucceeded(
  results: readonly PromiseSettledResult<unknown>[],
  message: string
): void {
  const errors = results.flatMap((result) =>
    result.status === "rejected" ? [result.reason] : []
  );
  if (errors.length > 0) throw new AggregateError(errors, message);
}
