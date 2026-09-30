import { isHttpMiss, type SalixClient } from "./client";
import { SalixMessageBundleSchema } from "./messages";
import {
  salixCompactSessionResponseSchema,
  salixConversationSchema,
  salixConversationSeedResponseSchema,
  salixJsonSchema,
  salixTranscriptSeedBatchResponseSchema,
  salixTranscriptSeedFinalizeResponseSchema,
  salixTranscriptSeedResponseSchema,
} from "./protocol";
import type { Salix } from "./types";
export class SalixTranscriptsService {
  constructor(private readonly client: SalixClient) {}
  async collectRouterMessages(groupId: string): Promise<Salix.SessionMessage[]> {
    const raw = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/router/messages`,
      {
        allowStatuses: [404],
        schema: salixJsonSchema,
      }
    );
    return isHttpMiss(raw) ? [] : SalixMessageBundleSchema.parse(raw);
  }

  async collectConversationMessages(
    groupId: string,
    conversationId: string
  ): Promise<Salix.SessionMessage[]> {
    const raw = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversationId)}/messages`,
      {
        allowStatuses: [404],
        schema: salixJsonSchema,
      }
    );
    return isHttpMiss(raw) ? [] : SalixMessageBundleSchema.parse(raw);
  }

  async seedAgentTranscript(
    input: Salix.TranscriptSeedInput
  ): Promise<Salix.TranscriptSeedArtifact> {
    const seed = await this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/transcript/seed`,
      {
        method: "POST",
        schema: salixTranscriptSeedResponseSchema,
        body: {
          source_id: input.sourceId,
          created_at: input.createdAt,
          entries: input.entries.map((entry) => transcriptSeedEntryBody(entry)),
        },
      }
    );

    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      sourceId: seed.sourceId ?? input.sourceId,
      requestedCount: seed.requestedCount,
      appendedCount: seed.appendedCount,
      skippedCount: seed.skippedCount,
      messageCount: seed.messageCount,
      lastMessageId: seed.lastMessageId,
      compactedThrough: seed.compactedThrough,
      summarySequence: seed.summarySequence,
    };
  }

  async stageAgentTranscriptBatch(
    input: Salix.TranscriptSeedBatchInput
  ): Promise<Salix.TranscriptSeedBatchArtifact> {
    return this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/transcript/seed-batches/${encodeURIComponent(input.seedId)}/${input.batchIndex}`,
      {
        method: "POST",
        schema: salixTranscriptSeedBatchResponseSchema,
        body: {
          source_id: input.sourceId,
          created_at: input.createdAt,
          entries: input.entries.map((entry) => transcriptSeedEntryBody(entry)),
        },
      }
    );
  }

  async finalizeAgentTranscriptBatches(
    input: Salix.TranscriptSeedFinalizeInput
  ): Promise<Salix.TranscriptSeedFinalizeArtifact> {
    const seed = await this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/transcript/seed-batches/${encodeURIComponent(input.seedId)}/finalize`,
      {
        method: "POST",
        schema: salixTranscriptSeedFinalizeResponseSchema,
        body: { expected_batch_count: input.expectedBatchCount },
      }
    );
    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      status: seed.status,
      aggregateDigest: seed.aggregateDigest,
      batchCount: seed.batchCount,
      runtimeKind: seed.runtimeKind,
      requestedCount: seed.requestedCount,
      appendedCount: seed.appendedCount,
      skippedCount: seed.skippedCount,
      messageCount: seed.messageCount,
      lastMessageId: seed.lastMessageId,
      compactedThrough: seed.compactedThrough,
      summarySequence: seed.summarySequence,
    };
  }

  async seedVisibleTranscript(
    input: Salix.VisibleTranscriptSeedInput
  ): Promise<Salix.VisibleTranscriptSeedArtifact> {
    if (input.mode !== "router_user_chat") {
      throw new Error(
        `seedVisibleTranscript mode ${input.mode} is not implemented by the Salix adapter`
      );
    }

    const routerConversation = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.target.groupId)}/router/conversation`,
      { schema: salixConversationSchema }
    );
    const seed = buildRouterVisibleTranscriptSeed(
      input,
      routerConversation.conversationId
    );
    const conversation = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(seed.groupId)}/conversations/${encodeURIComponent(seed.conversationId)}/transcript/seed`,
      {
        method: "POST",
        schema: salixConversationSeedResponseSchema,
        body: seed.conversationSeedBody,
      }
    );

    const session = await this.seedAgentTranscript({
      agentId: input.target.agentId,
      sessionId: input.target.sessionId,
      sourceId: input.sourceId,
      createdAt: input.createdAt,
      entries: seed.sessionEntries,
    });

    return {
      conversation: {
        groupId: seed.groupId,
        conversationId: seed.conversationId,
        requestedCount: conversation.requestedCount,
        appendedCount: conversation.appendedCount,
        skippedCount: conversation.skippedCount,
        messageCount: conversation.messageCount,
      },
      session,
    };
  }

  buildTranscriptSeedEntries(
    entries: readonly Salix.TranscriptSeedEntry[],
    options: Salix.TranscriptSeedEntryBuildOptions = {}
  ): Salix.TranscriptSeedEntry[] {
    return entries.map((entry, index) => {
      const sourceId = options.sourcePrefix
        ? `${options.sourcePrefix}:${index + 1}`
        : undefined;
      return {
        ...entry,
        type:
          entry.type ??
          (entry.role === "runtime" ? options.runtimeType : options.defaultType),
        sourceMessageId: entry.sourceMessageId ?? sourceId,
        dedupeKey:
          entry.dedupeKey ??
          (options.includeDedupeKey === false ? undefined : sourceId),
      };
    });
  }

  async compactAgentSession(
    input: Salix.CompactSessionInput
  ): Promise<Salix.CompactSessionArtifact> {
    const compact = await this.client.request(
      `/v1/runtime/agents/${encodeURIComponent(input.agentId)}/sessions/${encodeURIComponent(input.sessionId)}/compact`,
      {
        method: "POST",
        schema: salixCompactSessionResponseSchema,
      }
    );

    return {
      agentId: input.agentId,
      sessionId: input.sessionId,
      status: compact.status,
      reason: compact.reason,
    };
  }
}
type RouterVisibleTranscriptSeed = {
  groupId: string;
  conversationId: string;
  conversationSeedBody: Record<string, unknown>;
  sessionEntries: Salix.TranscriptSeedEntry[];
};

function buildRouterVisibleTranscriptSeed(
  input: Salix.VisibleTranscriptSeedInput,
  conversationId: string
): RouterVisibleTranscriptSeed {
  const target = input.target;
  if (target.agentRole !== "router") {
    throw new Error("router_user_chat transcript seeding requires a router target");
  }

  const groupId = target.groupId;
  const sourcePrefix =
    input.sourceId ?? `evalens:${groupId}:${target.sessionId}:visible`;
  const conversationMessages: Record<string, unknown>[] = [];
  const sessionEntries: Salix.TranscriptSeedEntry[] = [];

  input.history.forEach((entry, index) => {
    const messageId =
      entry.sourceMessageId ?? `${sourcePrefix}:${index + 1}:${entry.role}`;
    const createdAt = entry.createdAt ?? input.createdAt;

    if (entry.role === "user") {
      conversationMessages.push({
        client_request_id: messageId,
        actor_type: "user",
        user_id: "current",
        content: [{ type: "text", text: entry.content }],
        created_at: createdAt,
      });
      sessionEntries.push(
        {
          role: "summary",
          content: routerSourceContext(groupId, conversationId, messageId),
          sourceMessageId: `${messageId}:source-context`,
          dedupeKey: `${messageId}:source-context`,
          createdAt,
        },
        {
          role: "user",
          content: entry.content,
          sourceMessageId: messageId,
          dedupeKey: messageId,
          createdAt,
        }
      );
      return;
    }

    if (entry.role === "assistant") {
      const toolCallId = `evalens:${index + 1}:send-message`;
      const content = [{ type: "text", text: entry.content }];

      conversationMessages.push({
        client_request_id: messageId,
        actor_type: "agent",
        agent_id: target.agentId,
        role_label: "router",
        content,
        created_at: createdAt,
      });
      sessionEntries.push(
        {
          role: "assistant",
          content: "",
          sourceMessageId: `${messageId}:assistant-send-message`,
          dedupeKey: `${messageId}:assistant-send-message`,
          createdAt,
          toolCalls: [
            {
              id: toolCallId,
              name: "call_im_provider_api",
              args: {
                provider: "internal",
                connect_id: "internal",
                api: "internal.send_message",
                params_json: JSON.stringify({
                  conversation_id: conversationId,
                  content,
                }),
              },
            },
          ],
        },
        {
          role: "tool",
          content: JSON.stringify({
            sent: true,
            conversation_id: conversationId,
            message_id: messageId,
            inserted: true,
            dispatch_status: "recorded",
          }),
          toolCallId,
          toolName: "call_im_provider_api",
          sourceMessageId: `${messageId}:tool-result`,
          dedupeKey: `${messageId}:tool-result`,
          createdAt,
        }
      );
      return;
    }

    sessionEntries.push({
      ...entry,
      sourceMessageId: entry.sourceMessageId ?? messageId,
      dedupeKey: entry.dedupeKey ?? messageId,
      createdAt,
    });
  });

  return {
    groupId,
    conversationId,
    conversationSeedBody: {
      created_at: input.createdAt,
      conversation: {
        kind: "user_chat",
        title: "Bridge chat",
        participants: [
          {
            actor_type: "user",
            user_id: "current",
            role_label: "user",
          },
          {
            actor_type: "agent",
            agent_id: target.agentId,
            role_label: "router",
          },
        ],
      },
      messages: conversationMessages,
      mark_participants_delivered: true,
    },
    sessionEntries,
  };
}

function routerSourceContext(
  groupId: string,
  conversationId: string,
  messageId: string
): string {
  return `Inbound message source:
- provider: internal
- connect_id: internal
- reply_api: internal.send_message
- conversation_id: ${conversationId}
- message_id: ${messageId}
- agent_group_id: ${groupId}

This is source context for an ordinary internal Comma conversation message. Use it to understand where the message came from. Only send a visible reply if the task actually needs one; staying silent is valid.`;
}

function transcriptSeedEntryBody(
  entry: Salix.TranscriptSeedEntry
): Record<string, unknown> {
  return {
    role: entry.role,
    content: entry.content,
    summary: entry.summary,
    type: entry.type,
    source: entry.source,
    source_refs: entry.sourceRefs,
    source_message_id: entry.sourceMessageId,
    dedupe_key: entry.dedupeKey,
    runtime_message_id: entry.runtimeMessageId,
    created_at: entry.createdAt,
    model: entry.model,
    provider_meta: entry.providerMeta,
    tool_calls: entry.toolCalls,
    tool_call_id: entry.toolCallId,
    tool_use_id: entry.toolUseId,
    tool_name: entry.toolName,
    status: entry.status,
    duration_ms: entry.durationMs,
    input: entry.input,
    output: entry.output,
    error_class: entry.errorClass,
    error_message: entry.errorMessage,
    started_at: entry.startedAt,
    completed_at: entry.completedAt,
    input_tokens: entry.inputTokens,
    output_tokens: entry.outputTokens,
    cache_read_input_tokens: entry.cacheReadInputTokens,
    cache_write_input_tokens: entry.cacheWriteInputTokens,
    turn_id: entry.turnId,
    round_id: entry.roundId,
    request_id: entry.requestId,
    trace_id: entry.traceId,
  };
}
