import { isHttpMiss, type SalixClient, SalixHttpError } from "./client";
import {
  salixAgentGroupSchema,
  salixAgentSchema,
  salixConversationParticipantsSchema,
  salixConversationDetailSchema,
  salixConversationPageSchema,
  salixConversationSchema,
  salixImConnectsSchema,
  salixMaterializedAgentSchema,
  salixWorkerAgentsSchema,
  type SalixAgentResponse,
} from "./protocol";
import type { Salix } from "./types";

export class SalixRunsService {
  constructor(private readonly client: SalixClient) {}

  agentSession(
    run: Salix.PreparedRun,
    input: Salix.PreparedAgentSessionInput
  ): Salix.PreparedAgentSession {
    if (input.role === "router") {
      if (!run.routerAgentId || !run.routerSessionId) {
        throw new Error("prepared run does not contain a router session");
      }
      return {
        groupId: run.groupId,
        agentId: run.routerAgentId,
        sessionId: run.routerSessionId,
        agentRole: "router",
        agentRef: "router",
      };
    }

    const workerRef = input.workerRef ?? Object.keys(run.workerAgentIds)[0];
    const workerAgentId =
      (workerRef ? run.workerAgentIds[workerRef] : undefined) ??
      Object.values(run.workerAgentIds)[0];
    if (!workerAgentId) {
      throw new Error("prepared run does not contain a worker agent");
    }

    return {
      groupId: run.groupId,
      agentId: workerAgentId,
      sessionId:
        input.sessionId ??
        (workerRef ? run.workerSessionIds?.[workerRef] : undefined) ??
        run.workerSessionIds?.[workerAgentId] ??
        "main",
      conversationId:
        (workerRef ? run.workerConversationIds?.[workerRef] : undefined) ??
        run.workerConversationIds?.[workerAgentId],
      agentRole: "worker",
      agentRef: workerRef,
      workerRef,
    };
  }

  async prepareRun(spec: Salix.EvalFixture): Promise<Salix.PreparedRun> {
    const group = await this.client.request("/v1/runtime/agent-groups", {
      method: "POST",
      schema: salixAgentGroupSchema,
      body: {
        name: spec.name,
      },
    });

    const groupId = group.groupId;
    if (!groupId) {
      throw new Error("Salix returned an agent group without id");
    }

    const workerAgentIds: Record<string, string> = {};
    const workerSessionIds: Record<string, string> = {};
    const workerConversationIds: Record<string, string> = {};
    const agentIds: string[] = [];
    let routerAgentId: string | undefined;
    let routerSessionId: string | undefined;

    for (const agent of spec.agents ?? []) {
      const materialized = agent.slot
        ? await this.materializeInitialSlot(groupId, agent.slot)
        : await this.createAgent({
            group_id: groupId,
            role: agent.role,
            ref: agent.ref,
            template_id: agent.template,
            system_prompt: agent.systemPrompt,
            router_system_prompt: agent.routerSystemPrompt,
            metadata: agent.metadata,
          });

      const agentId = materialized.agentId;
      if (!agentId) {
        continue;
      }
      agentIds.push(agentId);
      if (agent.role === "router") {
        const sessionId = materialized.sessionId;
        if (!sessionId) {
          throw new Error(
            `Salix returned a router without a canonical session: ${agentId}`
          );
        }
        routerAgentId = agentId;
        routerSessionId = sessionId;
        await this.updateGroup(groupId, { router_agent_id: agentId });
      } else {
        const workerRef = agent.ref ?? agentId;
        workerAgentIds[workerRef] = agentId;
        if (agent.sessionMode !== "deferred") {
          const workerSession = await this.createWorkerSession(
            groupId,
            agentId,
            workerRef
          );
          workerSessionIds[workerRef] = workerSession.sessionId;
          workerConversationIds[workerRef] = workerSession.conversationId;
        }
      }
    }

    return {
      tenantId: this.client.tenantId ?? "unknown",
      groupId,
      routerAgentId,
      routerSessionId,
      workerAgentIds,
      workerSessionIds,
      workerConversationIds,
      cleanupPlan: { groupIds: [groupId], agentIds },
    };
  }

  async listConversations(input: {
    groupId: string;
    limit?: number;
    cursor?: string;
  }): Promise<Salix.ConversationPage> {
    return this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/conversations`,
      {
        query: { limit: input.limit, cursor: input.cursor },
        schema: salixConversationPageSchema,
      }
    );
  }

  async listConversationsBounded(input: {
    groupId: string;
    maxConversations: number;
    pageSize?: number;
  }): Promise<Salix.Conversation[]> {
    assertPositiveInteger(input.maxConversations, "maxConversations");
    const requestedPageSize = input.pageSize ?? 200;
    assertPositiveInteger(requestedPageSize, "pageSize");
    const pageSize = Math.min(requestedPageSize, input.maxConversations, 200);
    const maxPages = Math.ceil(input.maxConversations / pageSize);

    const conversations: Salix.Conversation[] = [];
    const observedCursors = new Set<string>();
    let pagesRead = 0;
    let cursor: string | undefined;
    while (true) {
      pagesRead += 1;
      const page = await this.listConversations({
        groupId: input.groupId,
        limit: pageSize,
        cursor,
      });
      if (conversations.length + page.data.length > input.maxConversations) {
        throw conversationLimitError(input.maxConversations);
      }
      conversations.push(...page.data);
      if (!page.hasMore) return conversations;
      if (pagesRead === maxPages) {
        throw new Error(`Salix conversation scan exceeded its ${maxPages}-page limit`);
      }
      if (conversations.length === input.maxConversations) {
        throw conversationLimitError(input.maxConversations);
      }
      if (!page.nextCursor) {
        throw new Error("Salix conversation page has_more without next_cursor");
      }
      if (observedCursors.has(page.nextCursor)) {
        throw new Error(`Salix conversation cursor repeated: ${page.nextCursor}`);
      }
      observedCursors.add(page.nextCursor);
      cursor = page.nextCursor;
    }
  }

  async getConversation(input: {
    groupId: string;
    conversationId: string;
  }): Promise<Salix.Conversation> {
    return this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/conversations/${encodeURIComponent(input.conversationId)}`,
      { schema: salixConversationDetailSchema }
    );
  }

  async listConversationParticipants(input: {
    groupId: string;
    conversationId: string;
  }): Promise<Salix.ConversationParticipant[]> {
    return this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/conversations/${encodeURIComponent(input.conversationId)}/participants`,
      { schema: salixConversationParticipantsSchema }
    );
  }

  private async createWorkerSession(
    groupId: string,
    agentId: string,
    workerRef: string
  ): Promise<{ conversationId: string; sessionId: string }> {
    const conversation = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations`,
      {
        method: "POST",
        schema: salixConversationSchema,
        body: {
          kind: "agent_task",
          title: `Evalens task for ${workerRef}`,
          participants: [
            {
              actor_type: "user",
              user_id: "current",
              state: "active",
              notification_filter: {
                messages: "all",
                statuses: "none",
              },
            },
            {
              actor_type: "agent",
              agent_id: agentId,
              role_label: "worker",
              state: "active",
              notification_filter: {
                messages: "all",
                statuses: "none",
              },
            },
          ],
        },
      }
    );
    const participants = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversation.conversationId)}/participants`,
      { schema: salixConversationParticipantsSchema }
    );
    const sessionId = participants.find(
      (participant) => participant.agentId === agentId
    )?.sessionId;
    if (!sessionId) {
      throw new Error(`Salix did not allocate a session for worker: ${agentId}`);
    }
    return { conversationId: conversation.conversationId, sessionId };
  }

  async cleanupRun(run: Salix.PreparedRun): Promise<void> {
    const retryBackoffMs = [100, 300] as const;
    for (let attempt = 0; ; attempt += 1) {
      try {
        await this.cleanupRunAttempt(run);
        return;
      } catch (error) {
        const causes = error instanceof AggregateError ? error.errors : [error];
        const retryable = causes.some(
          (cause) =>
            cause instanceof TypeError ||
            (cause instanceof SalixHttpError &&
              (cause.status === 429 || cause.status >= 500))
        );
        const delay = retryBackoffMs[attempt];
        if (!retryable || delay === undefined) throw error;
        await Bun.sleep(delay);
      }
    }
  }

  private async cleanupRunAttempt(run: Salix.PreparedRun): Promise<void> {
    const errors: unknown[] = [];
    const groupsWithUnconfirmedImCleanup = new Set<string>();
    const imConnects = new Map(
      (run.cleanupPlan.imConnects ?? []).map((ref) => [
        `${ref.groupId}:${ref.connectId}`,
        ref,
      ])
    );
    for (const groupId of run.cleanupPlan.imConnectDiscoveryGroupIds ?? []) {
      try {
        const discovered = await this.client.request(
          `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects`,
          { schema: salixImConnectsSchema, allowStatuses: [404] }
        );
        if (!isHttpMiss(discovered)) {
          for (const { connectId } of discovered) {
            imConnects.set(`${groupId}:${connectId}`, { groupId, connectId });
          }
        }
      } catch (error) {
        errors.push(error);
        groupsWithUnconfirmedImCleanup.add(groupId);
      }
    }

    const imConnectRefs = [...imConnects.values()];
    const imCleanupResults = await Promise.allSettled(
      imConnectRefs.map(({ groupId, connectId }) =>
        this.client
          .requestVoid(
            `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects/${encodeURIComponent(connectId)}`,
            { method: "DELETE", allowStatuses: [404] }
          )
          .then(() => undefined)
      )
    );
    imCleanupResults.forEach((result, index) => {
      if (result.status !== "rejected") return;
      errors.push(result.reason);
      groupsWithUnconfirmedImCleanup.add(imConnectRefs[index]!.groupId);
    });

    if (groupsWithUnconfirmedImCleanup.size === 0) {
      errors.push(
        ...(
          await Promise.allSettled(
            (run.cleanupPlan.agentIds ?? []).map((agentId) =>
              this.client
                .requestVoid(`/v1/runtime/agents/${encodeURIComponent(agentId)}`, {
                  method: "DELETE",
                  allowStatuses: [404],
                })
                .then(() => undefined)
            )
          )
        ).flatMap((result) => (result.status === "rejected" ? [result.reason] : []))
      );
    }

    errors.push(
      ...(
        await Promise.allSettled(
          (run.cleanupPlan.groupIds ?? [run.groupId])
            .filter((groupId) => !groupsWithUnconfirmedImCleanup.has(groupId))
            .map((groupId) => this.deleteGroupAndDiscoveredAgents(groupId))
        )
      ).flatMap((result) => (result.status === "rejected" ? [result.reason] : []))
    );

    if (errors.length > 0) {
      throw new AggregateError(
        errors,
        `Salix cleanup failed in ${errors.length} step(s)`
      );
    }
  }

  private async deleteGroupAndDiscoveredAgents(groupId: string): Promise<void> {
    const groupPath = `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}`;
    try {
      await this.client.requestVoid(groupPath, {
        method: "DELETE",
        allowStatuses: [404],
      });
      return;
    } catch (error) {
      if (!(error instanceof SalixHttpError) || error.status !== 409) throw error;
    }

    // Workflows may materialize internal workers after prepareRun, so they are not
    // present in cleanupPlan.agentIds. Discover them only when Salix confirms that
    // agents still reference the group, then remove the remaining tenant-scoped
    // agents before retrying the group deletion.
    const agents = await this.client.request("/v1/runtime/agents", {
      query: { group_id: groupId },
      schema: salixWorkerAgentsSchema,
    });
    const agentCleanup = await Promise.allSettled(
      agents.map((agent) =>
        this.client.requestVoid(
          `/v1/runtime/agents/${encodeURIComponent(agent.agentId)}`,
          { method: "DELETE", allowStatuses: [404] }
        )
      )
    );
    const agentErrors = agentCleanup.flatMap((result) =>
      result.status === "rejected" ? [result.reason] : []
    );
    if (agentErrors.length > 0) {
      throw new AggregateError(
        agentErrors,
        `Salix discovered-agent cleanup failed in ${agentErrors.length} step(s)`
      );
    }

    await this.client.requestVoid(groupPath, {
      method: "DELETE",
      allowStatuses: [404],
    });
  }

  async listWorkers(input: Salix.ListWorkersInput): Promise<Salix.WorkerAgentRef[]> {
    const agents = await this.client.request("/v1/runtime/agents", {
      query: { group_id: input.groupId },
      schema: salixWorkerAgentsSchema,
    });

    return agents
      .map((agent) => Object.assign(agent, { groupId: input.groupId }))
      .filter(
        (agent) =>
          agent.role === "worker" ||
          agent.role === "worker_agent" ||
          agent.ref !== undefined
      );
  }

  private async materializeInitialSlot(
    groupId: string,
    slot: string
  ): Promise<SalixAgentResponse> {
    return this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/initial-agent-slots/${encodeURIComponent(slot)}/materialize`,
      {
        method: "POST",
        schema: salixMaterializedAgentSchema,
      }
    );
  }

  private async createAgent(
    body: Record<string, unknown>
  ): Promise<SalixAgentResponse> {
    return this.client.request("/v1/runtime/agents", {
      method: "POST",
      schema: salixAgentSchema,
      body,
    });
  }

  private async updateGroup(
    groupId: string,
    body: Record<string, unknown>
  ): Promise<void> {
    await this.client.requestVoid(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}`,
      {
        method: "PATCH",
        body,
      }
    );
  }
}

function assertPositiveInteger(value: number, name: string): void {
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Salix ${name} must be a positive integer`);
  }
}

function conversationLimitError(maxConversations: number): Error {
  return new Error(
    `Salix conversation scan exceeded its ${maxConversations}-conversation limit`
  );
}
