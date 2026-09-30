import type { RunOutput } from "@evalens/core/run";
import type { Trajectory, TrajectoryStep } from "@evalens/core/message";
import type { JSONType } from "zod";
import { isHttpMiss, type SalixClient } from "./client";
import type { SalixFilesService } from "./files";
import { SalixMessageBundleSchema } from "./messages";
import { salixJsonSchema } from "./protocol";
import type { SalixSessionsService } from "./sessions";
import type { Salix } from "./types";

export class SalixOutputService {
  constructor(
    private readonly client: SalixClient,
    private readonly sessions: SalixSessionsService,
    private readonly files: SalixFilesService
  ) {}
  async collectChain(
    input: Salix.ChainCollectInput
  ): Promise<Salix.ChainArtifactBundle> {
    const routerConversation = input.groupId
      ? await this.client.request(
          `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/router/conversation`,
          {
            allowStatuses: [404],
            schema: salixJsonSchema,
          }
        )
      : undefined;
    const routerMessages = input.groupId
      ? await this.client.request(
          `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/router/messages`,
          {
            allowStatuses: [404],
            schema: salixJsonSchema,
          }
        )
      : undefined;
    const workerSessions =
      input.groupId || input.workerAgentIds
        ? await this.sessions.listWorkerSessions({
            groupId: input.groupId,
            workerAgentIds: input.workerAgentIds,
            includeHidden: true,
          })
        : [];
    const sessionBundles = await Promise.all(
      workerSessions.map((session) =>
        this.sessions.collectAgentSession({
          agentId: session.agentId,
          sessionId: session.sessionId,
        })
      )
    );

    return {
      groupId: input.groupId,
      routerConversation: isHttpMiss(routerConversation)
        ? undefined
        : routerConversation,
      routerMessages: isHttpMiss(routerMessages)
        ? []
        : SalixMessageBundleSchema.parse(routerMessages),
      workerSessions,
      sessionBundles,
    };
  }

  async collectRunOutput(
    input: Salix.RunOutputCollectInput<JSONType>
  ): Promise<RunOutput<JSONType>> {
    const [artifactDownloads, trajectories] = await Promise.all([
      Promise.all(
        (input.artifactAgents ?? []).map((agent) =>
          this.files.downloadAgentFiles(agent)
        )
      ),
      Promise.all(
        (input.traceSessions ?? []).map((session) =>
          this.sessions.collectSessionTrajectory(session)
        )
      ),
    ]);
    const artifacts = createArtifactArchive(artifactDownloads);

    return {
      result: input.result,
      trajectories,
      ...(artifacts ? { artifacts } : {}),
    };
  }
}
import { SalixResponseDateSchema } from "./protocol";

export function createArtifactArchive(
  downloads: readonly Salix.AgentFilesDownloadArtifact[]
): Bun.Archive | undefined {
  const files: Record<string, Uint8Array> = {};
  for (const download of downloads) {
    for (const file of download.files) {
      const archivePath = archiveFilePath(download.agentId, file.relativePath);
      if (Object.hasOwn(files, archivePath)) {
        throw new Error(`duplicate Salix artifact path: ${archivePath}`);
      }
      files[archivePath] = file.data;
    }
  }
  return Object.keys(files).length > 0 ? new Bun.Archive(files) : undefined;
}

export function sessionTraceToTrajectory(trace: Salix.SessionTraceFile): Trajectory {
  const steps: TrajectoryStep[] = [];
  const transcriptToolCallIds = new Set<string>();
  const collectedAt = SalixResponseDateSchema.parse(trace.collectedAt);
  if (!collectedAt) {
    throw new Error(`invalid Salix trace collectedAt: ${trace.collectedAt}`);
  }
  for (const message of trace.session.messages) {
    const messageSteps = messageToTrajectorySteps(message, collectedAt);
    for (const step of messageSteps) {
      if (step.type === "tool_call") transcriptToolCallIds.add(step.id);
      steps.push(step);
    }
  }
  for (const call of trace.execution.tool_calls ?? []) {
    const timestamp = SalixResponseDateSchema.parse(call.timestamp) ?? collectedAt;
    const id = call.call_id ?? `${trace.identity.sessionId}:tool:${steps.length}`;
    const name = call.name ?? "unknown";
    if (transcriptToolCallIds.has(id)) continue;
    steps.push({
      type: "tool_call",
      id,
      name,
      arguments: call.input ?? null,
      timestamp,
    });
    if (call.output !== undefined || call.error_message !== undefined) {
      steps.push({
        type: "tool_result",
        toolCallId: id,
        name,
        output: call.output ?? call.error_message ?? null,
        timestamp,
        ...(call.duration_ms === undefined ? {} : { durationMs: call.duration_ms }),
        ...(call.status === undefined ? {} : { status: call.status }),
        ...(call.error_class === undefined ? {} : { errorClass: call.error_class }),
        ...(call.error_message === undefined
          ? {}
          : { errorMessage: call.error_message }),
      });
    }
  }
  return {
    id:
      trace.execution.trace_id ??
      `${trace.identity.agentId}:${trace.identity.sessionId}`,
    steps,
  };
}

function archiveFilePath(agentId: string, relativePath: string): string {
  if (!agentId || agentId === "." || agentId === ".." || /[\\/]/u.test(agentId)) {
    throw new Error(`invalid Salix artifact agent id: ${agentId}`);
  }
  const normalized = relativePath.replaceAll("\\", "/").replace(/^\/+/, "");
  const segments = normalized.split("/");
  if (!normalized || segments.some((segment) => segment === "..")) {
    throw new Error(`invalid Salix artifact path: ${relativePath}`);
  }
  return `${agentId}/${normalized}`;
}

function messageToTrajectorySteps(
  message: Salix.SessionTraceMessage,
  fallbackTimestamp: Date
): TrajectoryStep[] {
  const {
    role,
    content,
    model,
    createdAt,
    toolCalls,
    toolCallId,
    toolName,
    durationMs,
    status,
    errorClass,
    errorMessage,
  } = message;
  const timestamp = createdAt ?? fallbackTimestamp;
  if (role === "system" && content !== undefined) {
    return [{ type: "system", content, timestamp }];
  }
  if (role === "user" && content !== undefined) {
    return [{ type: "user", content, timestamp }];
  }
  if (role === "assistant") {
    return [
      {
        type: "assistant",
        ...(content === undefined ? {} : { content }),
        ...(model === undefined ? {} : { model }),
        timestamp,
      },
      ...toolCalls.map((call): TrajectoryStep => ({
        type: "tool_call",
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        timestamp,
      })),
    ];
  }
  if ((role === "runtime" || role === "summary") && content !== undefined) {
    return [{ type: "system", content, timestamp }];
  }
  if (role === "tool" && toolCallId) {
    return [
      {
        type: "tool_result",
        toolCallId,
        name: toolName ?? "unknown",
        output: content ?? null,
        timestamp,
        ...(durationMs === undefined ? {} : { durationMs }),
        ...(status === undefined ? {} : { status }),
        ...(errorClass === undefined ? {} : { errorClass }),
        ...(errorMessage === undefined ? {} : { errorMessage }),
      },
    ];
  }
  return [];
}
