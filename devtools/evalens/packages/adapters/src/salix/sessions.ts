import {
  latestAssistantReply,
  latestRouterConversationReply,
  maxMessageId,
  routerConversationBaseline,
  routerConversationBaselineAfterMessage,
  SalixMessageBundleSchema,
  type RouterConversationBaseline,
} from "./messages";
import { isHttpMiss, type HttpMiss, type SalixClient } from "./client";
import {
  AgentSessionTraceSchema,
  emptySalixSessionMetadata,
  salixJsonSchema,
  salixDeliveryResponseSchema,
  salixRouterMessageResponseSchema,
  salixSessionMetadataSchema,
  salixStatusSchema,
  salixWorkerSessionsSchema,
} from "./protocol";
import type { Salix } from "./types";
import type { SalixRunsService } from "./runs";
import type { SalixTranscriptsService } from "./transcripts";
import { sessionTraceToTrajectory } from "./output";

type GroupQuiescenceWaitInput = Salix.AssistantReplyWaitInput & {
  groupId: string;
  traceLimit?: number;
  quiescenceMs?: number;
};

type GroupQuiescenceObservation = {
  session: Salix.SessionArtifactBundle;
  reply?: Salix.AssistantReply;
  progressObserved: boolean;
  settled: {
    router: boolean;
    workers: boolean;
    all: boolean;
  };
  signature: string;
};

type GroupQuiescenceState = {
  observedProgress: boolean;
  latestReply?: Salix.AssistantReply;
  lastSignature?: string;
  quietSince?: number;
  completed: boolean;
};

// A quiescence poll is allowed to follow pagination, but never to scan a group
// without a fixed upper bound.
const GROUP_QUIESCENCE_CONVERSATION_LIMIT = 1_000;

export class SalixSessionsService {
  constructor(
    private readonly client: SalixClient,
    private readonly runs: SalixRunsService,
    private readonly transcripts: SalixTranscriptsService
  ) {}
  async listWorkerSessions(
    input: Salix.ListWorkerSessionsInput
  ): Promise<Salix.WorkerSessionRef[]> {
    let workerIds: string[];
    if (input.workerAgentIds) {
      workerIds = input.workerAgentIds;
    } else if (input.workerAgentId) {
      workerIds = [input.workerAgentId];
    } else if (input.groupId) {
      workerIds = (await this.runs.listWorkers({ groupId: input.groupId })).map(
        (worker) => worker.agentId
      );
    } else {
      throw new Error(
        "listWorkerSessions requires groupId, workerAgentId, or workerAgentIds"
      );
    }

    const sessionGroups = await Promise.all(
      workerIds.map(async (workerAgentId) => {
        const sessions = await this.client.request(
          `/v1/runtime/agents/${encodeURIComponent(workerAgentId)}/sessions`,
          {
            query: { include_hidden: input.includeHidden ?? true },
            schema: salixWorkerSessionsSchema,
          }
        );

        return sessions.map((session) =>
          Object.assign(session, { agentId: workerAgentId })
        );
      })
    );

    return sessionGroups.flat();
  }

  async runRouterTurn(input: Salix.RouterTurnInput): Promise<Salix.ChainRunArtifact> {
    const messageResult = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/router/messages`,
      {
        method: "POST",
        schema: salixRouterMessageResponseSchema,
        body:
          typeof input.message === "string"
            ? { content: input.message }
            : input.message,
      }
    );

    const settled = input.wait
      ? await this.waitForSettled({
          ...input.wait,
          groupId: input.groupId,
          kind: input.wait.kind ?? "router_turn",
        })
      : undefined;

    return {
      groupId: input.groupId,
      chainId: messageResult.chainId,
      conversationId: messageResult.conversationId,
      messageId: messageResult.messageId,
      messageResult,
      settled,
    };
  }

  async deliverAgentMessage(
    input: Salix.DirectDeliveryInput
  ): Promise<Salix.DeliveryArtifact> {
    const delivery = await this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/messages`,
      {
        method: "POST",
        schema: salixDeliveryResponseSchema,
        body: {
          role: input.role ?? "user",
          ...(typeof input.message === "string"
            ? { content: input.message }
            : input.message),
          // Last so an object-shaped message can never override the
          // caller-owned identity.
          source_message_id: input.sourceMessageId,
        },
      }
    );

    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      accepted: delivery.accepted,
    };
  }

  private async deliverWorkerConversationMessage(
    target: Salix.PreparedAgentSession,
    message: Salix.DirectDeliveryInput["message"],
    turnId: string
  ): Promise<Salix.DeliveryArtifact> {
    if (!target.conversationId) {
      return this.deliverAgentMessage({
        agentId: target.agentId,
        sessionId: target.sessionId,
        role: "user",
        message,
        sourceMessageId: `evalens:turn:${turnId}`,
      });
    }
    const result = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(target.groupId)}/conversations/${encodeURIComponent(target.conversationId)}/messages`,
      {
        method: "POST",
        schema: salixRouterMessageResponseSchema,
        body:
          typeof message === "string"
            ? { content: [{ type: "text", text: message }] }
            : message,
      }
    );
    return {
      agentId: target.agentId,
      sessionId: target.sessionId,
      conversationId: result.conversationId ?? target.conversationId,
      messageId: result.messageId,
    };
  }

  async runSessionTurn(
    input: Salix.SessionTurnInput
  ): Promise<Salix.SessionTurnArtifact> {
    const message = sessionTurnMessage(input.message, input.context);
    if (
      input.target.agentRole === "router" &&
      input.routerDeliveryMode !== "direct_session"
    ) {
      const [beforeMessages, beforeSession] = await Promise.all([
        this.transcripts.collectRouterMessages(input.target.groupId),
        this.collectAgentSession({
          agentId: input.target.agentId,
          sessionId: input.target.sessionId,
        }),
      ]);
      let baseline = routerConversationBaseline(beforeMessages);
      const afterSessionMessageId =
        maxMessageId(SalixMessageBundleSchema.parse(beforeSession)) ?? 0;
      const delivery = await this.runRouterTurn({
        groupId: input.target.groupId,
        message,
      });
      const deliveredMessageId = delivery.messageId;
      if (deliveredMessageId) {
        const afterDeliveryMessages = await this.transcripts.collectRouterMessages(
          input.target.groupId
        );
        baseline =
          routerConversationBaselineAfterMessage(
            afterDeliveryMessages,
            deliveredMessageId
          ) ?? baseline;
      }
      const replyWait = await this.waitForRouterConversationReply({
        groupId: input.target.groupId,
        agentId: input.target.agentId,
        baseline,
        pollMs: input.pollMs,
        timeoutMs: input.timeoutMs,
        visibleReplyGraceMs: input.visibleReplyGraceMs,
        sessionTarget: {
          agentId: input.target.agentId,
          sessionId: input.target.sessionId,
          afterMessageId: afterSessionMessageId,
        },
      });
      const trace = await this.collectSessionTraceFile({
        agentId: input.target.agentId,
        sessionId: input.target.sessionId,
        traceLimit: input.traceLimit,
        messageLimit: input.messageLimit,
      });

      return {
        target: input.target,
        delivery,
        replyWait,
        answer: replyWait.answer,
        trace,
        trajectory: sessionTraceToTrajectory(trace),
      };
    }

    const conversationId = input.target.conversationId;
    const beforeConversation = conversationId
      ? await this.transcripts.collectConversationMessages(
          input.target.groupId,
          conversationId
        )
      : undefined;
    const beforeSession = beforeConversation
      ? undefined
      : await this.collectAgentSession({
          agentId: input.target.agentId,
          sessionId: input.target.sessionId,
          messageLimit: input.messageLimit,
        });
    let conversationBaseline = beforeConversation
      ? routerConversationBaseline(beforeConversation)
      : undefined;
    const baselineMessageId = beforeSession
      ? (maxMessageId(SalixMessageBundleSchema.parse(beforeSession)) ?? 0)
      : 0;
    const delivery = await this.deliverWorkerConversationMessage(
      input.target,
      message,
      input.turnId
    );
    if (conversationId && conversationBaseline && delivery.messageId) {
      const afterDeliveryMessages = await this.transcripts.collectConversationMessages(
        input.target.groupId,
        conversationId
      );
      conversationBaseline =
        routerConversationBaselineAfterMessage(
          afterDeliveryMessages,
          delivery.messageId
        ) ?? conversationBaseline;
    }
    const replyWait =
      conversationId && conversationBaseline
        ? await this.waitForConversationReply({
            groupId: input.target.groupId,
            agentId: input.target.agentId,
            baseline: conversationBaseline,
            pollMs: input.pollMs,
            timeoutMs: input.timeoutMs,
            collectMessages: () =>
              this.transcripts.collectConversationMessages(
                input.target.groupId,
                conversationId
              ),
          })
        : input.replyCompletion === "group_quiescent"
          ? await this.waitForGroupQuiescence({
              groupId: input.target.groupId,
              agentId: input.target.agentId,
              sessionId: input.target.sessionId,
              afterMessageId: baselineMessageId,
              pollMs: input.pollMs,
              timeoutMs: input.timeoutMs,
              messageLimit: input.messageLimit,
              traceLimit: input.traceLimit,
              quiescenceMs: input.completionQuiescenceMs,
            })
          : await this.waitForAssistantReply({
              agentId: input.target.agentId,
              sessionId: input.target.sessionId,
              afterMessageId: baselineMessageId,
              pollMs: input.pollMs,
              timeoutMs: input.timeoutMs,
              messageLimit: input.messageLimit,
            });
    const trace = await this.collectSessionTraceFile({
      agentId: input.target.agentId,
      sessionId: input.target.sessionId,
      traceLimit: input.traceLimit,
      messageLimit: input.messageLimit,
    });

    return {
      target: input.target,
      delivery,
      replyWait,
      answer: replyWait.answer,
      trace,
      trajectory: sessionTraceToTrajectory(trace),
    };
  }

  async waitForSettled(input: Salix.WaitInput): Promise<Salix.SettledState> {
    const started = Date.now();
    const pollMs = input.pollMs ?? 1_000;
    const deadline = input.timeoutMs ? started + input.timeoutMs : undefined;
    let lastStatus: string | undefined;

    while (true) {
      const status = await this.readSettledTarget(input);
      if (status === undefined) {
        throw new Error("wait target requires an agent session or group target");
      }
      if (isHttpMiss(status)) {
        if (deadline !== undefined && Date.now() >= deadline) {
          return {
            settled: false,
            status: lastStatus,
            elapsedMs: Date.now() - started,
          };
        }
        await Bun.sleep(pollMs);
        continue;
      }
      lastStatus = status;
      if (isTerminalStatus(status)) {
        return {
          settled: true,
          status,
          elapsedMs: Date.now() - started,
        };
      }

      if (deadline !== undefined && Date.now() >= deadline) {
        return { settled: false, status, elapsedMs: Date.now() - started };
      }

      await Bun.sleep(pollMs);
    }
  }

  async waitForAssistantReply(
    input: Salix.AssistantReplyWaitInput
  ): Promise<Salix.AssistantReplyWaitResult> {
    const started = Date.now();
    const pollMs = input.pollMs ?? 1_000;
    const deadline = started + (input.timeoutMs ?? 120_000);
    while (true) {
      const latestSession = await this.collectAgentSession({
        agentId: input.agentId,
        sessionId: input.sessionId,
        messageLimit: input.messageLimit,
      });
      const reply = latestAssistantReply(latestSession, input.afterMessageId);
      if (reply) {
        return {
          elapsedMs: Date.now() - started,
          afterMessageId: input.afterMessageId,
          messageId: reply.messageId,
          replyMessageId: reply.message.id,
          answerSource: "session_transcript",
          answer: reply.content,
          session: latestSession,
        };
      }

      if (Date.now() >= deadline) {
        return {
          elapsedMs: Date.now() - started,
          afterMessageId: input.afterMessageId,
          timedOut: true,
          session: latestSession,
        };
      }

      await Bun.sleep(pollMs);
    }
  }

  async waitForGroupQuiescence(
    input: GroupQuiescenceWaitInput
  ): Promise<Salix.AssistantReplyWaitResult> {
    const timing = groupQuiescenceTiming(input);
    let state: GroupQuiescenceState = {
      observedProgress: false,
      completed: false,
    };

    while (true) {
      const observation = await this.observeGroupQuiescence(input);
      const now = Date.now();
      state = advanceGroupQuiescence(state, observation, now, timing.quiescenceMs);

      if (state.completed || now >= timing.deadline) {
        return groupQuiescenceResult({
          request: input,
          observation,
          state,
          elapsedMs: now - timing.started,
          timedOut: !state.completed,
        });
      }

      await Bun.sleep(timing.pollMs);
    }
  }

  private async observeGroupQuiescence(
    input: GroupQuiescenceWaitInput
  ): Promise<GroupQuiescenceObservation> {
    const [session, trace, workerSessions, conversations] = await Promise.all([
      this.collectAgentSession({
        agentId: input.agentId,
        sessionId: input.sessionId,
        messageLimit: input.messageLimit,
      }),
      this.collectAgentTrace({
        agentId: input.agentId,
        sessionId: input.sessionId,
        traceLimit: input.traceLimit,
      }),
      this.listWorkerSessions({ groupId: input.groupId }),
      this.runs.listConversationsBounded({
        groupId: input.groupId,
        maxConversations: GROUP_QUIESCENCE_CONVERSATION_LIMIT,
      }),
    ]);

    return summarizeGroupQuiescence({
      session,
      trace,
      workerSessions,
      conversations,
      afterMessageId: input.afterMessageId,
    });
  }

  async waitForRouterConversationReply(input: {
    groupId: string;
    agentId?: string;
    baseline: RouterConversationBaseline;
    pollMs?: number;
    timeoutMs?: number;
    visibleReplyGraceMs?: number;
    sessionTarget?: {
      agentId: string;
      sessionId: string;
      afterMessageId: number;
    };
  }): Promise<Salix.AssistantReplyWaitResult> {
    return this.waitForConversationReply({
      ...input,
      collectMessages: () => this.transcripts.collectRouterMessages(input.groupId),
    });
  }

  private async waitForConversationReply(input: {
    groupId: string;
    agentId?: string;
    baseline: RouterConversationBaseline;
    pollMs?: number;
    timeoutMs?: number;
    visibleReplyGraceMs?: number;
    sessionTarget?: {
      agentId: string;
      sessionId: string;
      afterMessageId: number;
    };
    collectMessages: () => Promise<Salix.SessionMessage[]>;
  }): Promise<Salix.AssistantReplyWaitResult> {
    const started = Date.now();
    const pollMs = input.pollMs ?? 1_000;
    const deadline = started + (input.timeoutMs ?? 120_000);
    const visibleReplyGraceMs = input.visibleReplyGraceMs ?? 2_000;
    let undeliveredObservedAt: number | undefined;
    while (true) {
      const messages = await input.collectMessages();
      const reply = latestRouterConversationReply(
        messages,
        input.baseline,
        input.agentId
      );
      if (reply) {
        return {
          elapsedMs: Date.now() - started,
          afterMessageId: input.baseline.messageCount,
          messageId: reply.messageId,
          replyMessageId: reply.message.id,
          answerSource: "router_conversation",
          answer: reply.content,
        };
      }

      if (input.sessionTarget) {
        const session = await this.collectAgentSession({
          agentId: input.sessionTarget.agentId,
          sessionId: input.sessionTarget.sessionId,
        });
        const sessionReply = latestAssistantReply(
          session,
          input.sessionTarget.afterMessageId
        );
        if (sessionReply && isSettledSession(session.session)) {
          undeliveredObservedAt ??= Date.now();
          if (Date.now() - undeliveredObservedAt >= visibleReplyGraceMs) {
            return {
              elapsedMs: Date.now() - started,
              afterMessageId: input.baseline.messageCount,
              timedOut: true,
              failureReason: "undelivered_session_reply",
              sessionReplyMessageId: sessionReply.message.id,
              session,
            };
          }
        } else {
          undeliveredObservedAt = undefined;
        }
      }

      if (Date.now() >= deadline) {
        return {
          elapsedMs: Date.now() - started,
          afterMessageId: input.baseline.messageCount,
          timedOut: true,
          failureReason: "timeout",
        };
      }
      await Bun.sleep(pollMs);
    }
  }

  async collectAgentSession(
    input: Salix.SessionCollectInput
  ): Promise<Salix.SessionArtifactBundle> {
    const sessionPath = `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}`;
    const messagesPath =
      input.messageLimit === undefined
        ? `${sessionPath}/messages`
        : `${sessionPath}/records`;
    const [session, messages] = await Promise.all([
      this.client.request(sessionPath, {
        allowStatuses: [404],
        schema: salixJsonSchema,
      }),
      this.client.request(messagesPath, {
        query:
          input.messageLimit === undefined ? undefined : { limit: input.messageLimit },
        allowStatuses: [404],
        schema: salixJsonSchema,
      }),
    ]);
    const page = isHttpMiss(messages)
      ? { messages: [] }
      : sessionMessagePage(messages, input.messageLimit !== undefined);

    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      session: isHttpMiss(session) ? undefined : session,
      messages: page.messages,
      ...(page.hasMore === undefined ? {} : { messageHasMore: page.hasMore }),
      ...(page.nextBefore === undefined ? {} : { nextBefore: page.nextBefore }),
    };
  }

  async collectSessionTraceFile(
    input: Salix.SessionTraceCollectInput
  ): Promise<Salix.SessionTraceFile> {
    const sessionPath = `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}`;
    const [sessionBundle, traceArtifact] = await Promise.all([
      this.collectAgentSession(input),
      this.collectAgentTrace(input),
    ]);
    const messages = SalixMessageBundleSchema.parse(sessionBundle);
    const trace = traceArtifact.trace ?? {};
    const parsedSessionMetadata = salixSessionMetadataSchema.safeParse(
      sessionBundle.session
    );
    const parsedMessageMetadata = salixSessionMetadataSchema.safeParse(
      sessionBundle.messages
    );
    const sessionMetadata = parsedSessionMetadata.success
      ? parsedSessionMetadata.data
      : emptySalixSessionMetadata;
    const messageMetadata = parsedMessageMetadata.success
      ? parsedMessageMetadata.data
      : emptySalixSessionMetadata;

    return {
      schemaVersion: 1,
      kind: "salix.session_trace",
      identity: {
        agentId: input.agentId,
        sessionId: input.sessionId,
        ...(this.client.tenantId ? { tenantId: this.client.tenantId } : {}),
      },
      collectedAt: new Date().toISOString(),
      source: {
        sessionEndpoint: sessionPath,
        messagesEndpoint:
          input.messageLimit === undefined
            ? `${sessionPath}/messages`
            : `${sessionPath}/records`,
        traceEndpoint: `${sessionPath}/trace`,
        ...(input.traceLimit === undefined ? {} : { traceLimit: input.traceLimit }),
        ...(input.messageLimit === undefined
          ? {}
          : { messageLimit: input.messageLimit }),
        ...(sessionBundle.messageHasMore === undefined
          ? {}
          : { messageHasMore: sessionBundle.messageHasMore }),
        ...(trace.has_more === undefined ? {} : { hasMore: trace.has_more }),
      },
      session: {
        messages,
        ...((sessionMetadata.compactedThrough ?? messageMetadata.compactedThrough) ===
        undefined
          ? {}
          : {
              compactedThrough:
                sessionMetadata.compactedThrough ?? messageMetadata.compactedThrough,
            }),
        ...((sessionMetadata.summarySequence ?? messageMetadata.summarySequence) ===
        undefined
          ? {}
          : {
              summarySequence:
                sessionMetadata.summarySequence ?? messageMetadata.summarySequence,
            }),
        messageCount:
          sessionMetadata.messageCount ??
          messageMetadata.messageCount ??
          messages.length,
        ...(sessionMetadata.summaries === undefined
          ? {}
          : { summaries: sessionMetadata.summaries }),
      },
      execution: trace,
      related: input.related,
    };
  }

  async collectSessionTrajectory(input: Salix.SessionTraceCollectInput) {
    return (await this.collectSessionTrace(input)).trajectory;
  }

  async collectSessionTrace(input: Salix.SessionTraceCollectInput) {
    const trace = await this.collectSessionTraceFile(input);
    return {
      trace,
      trajectory: sessionTraceToTrajectory(trace),
    };
  }

  async collectWorkerTrajectories(
    input: Salix.ListWorkerSessionsInput & {
      traceLimit?: number;
      messageLimit?: number;
    }
  ) {
    const sessions = await this.listWorkerSessions(input);
    const artifacts = await Promise.all(
      sessions.map((session) =>
        this.collectSessionTrace({
          agentId: session.agentId,
          sessionId: session.sessionId,
          traceLimit: input.traceLimit,
          messageLimit: input.messageLimit,
        })
      )
    );
    return artifacts.map((artifact) => artifact.trajectory);
  }

  async collectAgentTrace(
    input: Salix.AgentTraceCollectInput
  ): Promise<Salix.AgentTraceArtifact> {
    const trace = await this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/trace`,
      {
        query: { limit: input.traceLimit },
        allowStatuses: [404],
        schema: AgentSessionTraceSchema,
      }
    );

    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      trace: isHttpMiss(trace) ? undefined : trace,
    };
  }

  private async readSettledTarget(
    input: Salix.WaitInput
  ): Promise<string | HttpMiss | undefined> {
    if (input.agentId && input.sessionId) {
      return this.client.request(
        `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}`,
        {
          allowStatuses: [404],
          schema: salixStatusSchema,
        }
      );
    }

    if (input.groupId && input.conversationId) {
      return this.client.request(
        `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/conversations/${encodeURIComponent(input.conversationId)}`,
        { allowStatuses: [404], schema: salixStatusSchema }
      );
    }

    if (input.groupId && input.kind === "router_turn") {
      return this.client.request(
        `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/router/conversation`,
        {
          allowStatuses: [404],
          schema: salixStatusSchema,
        }
      );
    }

    return undefined;
  }
}

function groupQuiescenceTiming(input: GroupQuiescenceWaitInput): {
  started: number;
  pollMs: number;
  deadline: number;
  quiescenceMs: number;
} {
  const started = Date.now();
  const quiescenceMs = input.quiescenceMs ?? 30_000;
  if (!Number.isFinite(quiescenceMs) || quiescenceMs < 0) {
    throw new Error("Salix completion quiescenceMs must be non-negative");
  }

  return {
    started,
    pollMs: input.pollMs ?? 1_000,
    deadline: started + (input.timeoutMs ?? 120_000),
    quiescenceMs,
  };
}

function summarizeGroupQuiescence(input: {
  session: Salix.SessionArtifactBundle;
  trace: Salix.AgentTraceArtifact;
  workerSessions: Salix.WorkerSessionRef[];
  conversations: Salix.Conversation[];
  afterMessageId: number;
}): GroupQuiescenceObservation {
  const reply = latestAssistantReply(input.session, input.afterMessageId);
  const toolCalls = input.trace.trace?.tool_calls ?? [];
  const workersSettled = input.workerSessions.every(
    (worker) => worker.status !== undefined && isTerminalStatus(worker.status)
  );
  const routerSettled =
    isSettledSession(input.session.session) ||
    (input.workerSessions.length > 0 &&
      workersSettled &&
      isWaitingCoordinatorSession(input.session.session));
  const sessionRecord =
    input.session.session && typeof input.session.session === "object"
      ? (input.session.session as Record<string, unknown>)
      : {};
  const settled = {
    router: routerSettled,
    workers: workersSettled,
    all: routerSettled && workersSettled,
  };

  return {
    session: input.session,
    reply,
    progressObserved:
      reply !== undefined ||
      toolCalls.length > 0 ||
      input.workerSessions.length > 0 ||
      !routerSettled,
    settled,
    signature: JSON.stringify({
      messageId: maxMessageId(SalixMessageBundleSchema.parse(input.session)),
      messageCount: input.session.messages.length,
      status: sessionRecord.status,
      activityStatus: sessionRecord.activity_status,
      toolCalls: toolCalls.map((call) => [call.call_id, call.name, call.status]),
      workerSessions: sortGroupQuiescenceRows(
        input.workerSessions.map((worker) => [
          worker.agentId,
          worker.sessionId,
          worker.status,
        ])
      ),
    }),
  };
}

function sortGroupQuiescenceRows(rows: unknown[][]): unknown[][] {
  return rows.sort((left, right) =>
    JSON.stringify(left).localeCompare(JSON.stringify(right))
  );
}

function advanceGroupQuiescence(
  previous: GroupQuiescenceState,
  observation: GroupQuiescenceObservation,
  now: number,
  quiescenceMs: number
): GroupQuiescenceState {
  const observedProgress = previous.observedProgress || observation.progressObserved;
  const quietSince = !observation.settled.all
    ? undefined
    : observation.signature !== previous.lastSignature
      ? now
      : (previous.quietSince ?? now);

  return {
    observedProgress,
    latestReply: observation.reply ?? previous.latestReply,
    lastSignature: observation.signature,
    quietSince,
    completed:
      observedProgress && quietSince !== undefined && now - quietSince >= quiescenceMs,
  };
}

function groupQuiescenceResult(input: {
  request: GroupQuiescenceWaitInput;
  observation: GroupQuiescenceObservation;
  state: GroupQuiescenceState;
  elapsedMs: number;
  timedOut: boolean;
}): Salix.AssistantReplyWaitResult {
  const latestReply = input.state.latestReply;
  return {
    elapsedMs: input.elapsedMs,
    afterMessageId: input.request.afterMessageId,
    ...(input.timedOut ? { timedOut: true } : {}),
    ...(latestReply?.messageId === undefined
      ? {}
      : { messageId: latestReply.messageId }),
    ...(latestReply?.message.id === undefined
      ? {}
      : { replyMessageId: latestReply.message.id }),
    ...(latestReply
      ? {
          answerSource: "session_transcript" as const,
          answer: latestReply.content,
        }
      : {}),
    session: input.observation.session,
  };
}

function sessionMessagePage(
  value: unknown,
  bounded: boolean
): {
  messages: Salix.SessionMessage[];
  hasMore?: boolean;
  nextBefore?: string;
} {
  if (!bounded) {
    return { messages: SalixMessageBundleSchema.parse(value) };
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Salix session records response must be an object");
  }
  const record = value as Record<string, unknown>;
  if (!Array.isArray(record.records)) {
    throw new Error("Salix session records response has no records array");
  }
  const messages = SalixMessageBundleSchema.parse({ messages: record.records });
  const hasMore = typeof record.has_more === "boolean" ? record.has_more : undefined;
  const nextBefore =
    typeof record.next_before === "string"
      ? record.next_before
      : typeof record.next_before === "number"
        ? String(record.next_before)
        : undefined;
  return {
    messages,
    ...(hasMore === undefined ? {} : { hasMore }),
    ...(nextBefore === undefined ? {} : { nextBefore }),
  };
}

function isTerminalStatus(status: string): boolean {
  return [
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
  ].includes(status.toLowerCase());
}

function isSettledSession(session: unknown): boolean {
  if (session === null || typeof session !== "object") return false;
  const record = session as Record<string, unknown>;
  const status = record.status;
  if (typeof status !== "string" || !isTerminalStatus(status)) return false;
  const activityStatus = record.activity_status;
  return !(
    typeof activityStatus === "string" &&
    ["thinking", "execution", "messaging", "waiting", "running", "queued"].includes(
      activityStatus.toLowerCase()
    )
  );
}

function isWaitingCoordinatorSession(session: unknown): boolean {
  if (session === null || typeof session !== "object") return false;
  const record = session as Record<string, unknown>;
  return (
    typeof record.status === "string" &&
    isTerminalStatus(record.status) &&
    typeof record.activity_status === "string" &&
    record.activity_status.toLowerCase() === "waiting"
  );
}
function sessionTurnMessage(
  message: Salix.SessionTurnInput["message"],
  context: string | undefined
): Salix.SessionTurnInput["message"] {
  if (!context) {
    return message;
  }
  if (typeof message === "string") {
    return `${message}\n\n补充上下文：${context}`;
  }
  return { ...message, context };
}
