import { camel, mapKeys } from "radash";
import { z } from "zod";

type SalixObject = Record<string, unknown>;
type SalixObjectNormalizer = (input: SalixObject) => SalixObject;

const isSalixObject = (input: unknown): input is SalixObject =>
  typeof input === "object" && input !== null && !Array.isArray(input);

const camelizeTopLevelKeys = (input: unknown): unknown => {
  if (!isSalixObject(input)) return input;

  const sourceKeys = new Map<string, string>();
  for (const key of Object.keys(input)) {
    const normalizedKey = camel(key);
    const sourceKey = sourceKeys.get(normalizedKey);
    if (sourceKey && sourceKey !== key) {
      throw new Error(
        `Ambiguous Salix response keys ${JSON.stringify(sourceKey)} and ${JSON.stringify(key)} both normalize to ${JSON.stringify(normalizedKey)}`
      );
    }
    sourceKeys.set(normalizedKey, key);
  }

  return mapKeys(input, (key) => camel(key));
};

const preprocessSalixObject = <Schema extends z.ZodType>(
  schema: Schema,
  normalize?: SalixObjectNormalizer
) =>
  z.preprocess((input) => {
    const camelized = camelizeTopLevelKeys(input);
    if (!normalize || !isSalixObject(camelized)) return camelized;
    return normalize(camelized);
  }, schema);

const normalizeConversationIdentity: SalixObjectNormalizer = (raw) => ({
  ...raw,
  conversationId: raw.conversationId ?? raw.id,
});

export const SalixOptionalStringSchema = z.string().min(1).optional();

export const SalixOptionalFiniteNumberSchema = z.number().finite().optional();

export const SalixOptionalArraySchema = z.array(z.json()).optional();

export const SalixResponseDateSchema = z
  .union([z.iso.datetime({ offset: true }), z.number().finite()])
  .pipe(z.coerce.date())
  .optional();

export const salixJsonSchema = z.json();
export const salixStringSchema = SalixOptionalStringSchema;
export const salixNumberSchema = SalixOptionalFiniteNumberSchema;
export const salixArraySchema = SalixOptionalArraySchema;
export const salixAgentGroupSchema = z
  .looseObject({
    id: salixStringSchema,
    group_id: salixStringSchema,
    agent_group_id: salixStringSchema,
  })
  .transform((raw) => ({
    groupId: raw.id ?? raw.group_id ?? raw.agent_group_id,
  }));
export const salixConnectorTokenSchema = preprocessSalixObject(
  z.object({
    token: z.string().min(1),
    tokenHash: z.string().min(1),
    tenantId: z.string().min(1),
    groupId: z.string().min(1),
    deviceId: z.string().min(1),
    connectorId: z.string().min(1),
    name: z.string().min(1),
    alias: z.string().min(1),
    server: z.string().min(1),
    connectUrl: z.string().min(1),
    env: z.object({
      SALIX_SERVER: z.string().min(1),
      SALIX_CONNECTOR_TOKEN: z.string().min(1),
    }),
    createdAt: z.number().finite().optional(),
    expiresAt: z
      .number()
      .finite()
      .nullish()
      .transform((value) => value ?? undefined),
  })
);
export const salixEnvironmentSchema = preprocessSalixObject(
  z.object({
    groupId: z.string().min(1).optional(),
    deviceId: z.string().min(1),
    environmentId: z.string().min(1).optional(),
    connectorRunId: z.string().min(1).optional(),
    name: z.string().min(1).optional(),
    alias: z.string().min(1).optional(),
    status: z.string().min(1).optional(),
    os: z.string().min(1).optional(),
    arch: z.string().min(1).optional(),
    capabilities: z.record(z.string(), z.json()).optional(),
  })
);
export const salixEnvironmentsSchema = z.array(salixEnvironmentSchema);
export const salixAgentSchema = z
  .looseObject({
    agent_id: salixStringSchema,
    id: salixStringSchema,
    router_session_id: salixStringSchema,
  })
  .transform((raw) => ({
    agentId: raw.agent_id ?? raw.id,
    sessionId: raw.router_session_id,
  }));
export const salixMaterializedAgentSchema = z
  .looseObject({ agent: salixAgentSchema.optional() })
  .transform((raw) => raw.agent ?? salixAgentSchema.parse(raw));
const salixMaterializedMcpBindingSchema = z
  .looseObject({
    binding_id: z.string().min(1),
    alias: z.string().min(1).optional(),
    mcp_id: z.string().min(1).optional(),
  })
  .transform((raw) => ({
    bindingId: raw.binding_id,
    alias: raw.alias,
    mcpId: raw.mcp_id,
  }));
const salixImConnectMaterializationReceiptSchema = z
  .looseObject({
    materialization_id: z.string().min(1),
    materialization_kind: z.literal("im_connect"),
    provider: z.string().min(1),
    resources: z.looseObject({
      im_connect: z.looseObject({
        connect_id: z.string().min(1),
        workspace_id: z.string().min(1),
        bot_id: z.string().min(1),
        bot_user_id: z.string().min(1),
        inbound_agent_id: z.string().min(1),
      }),
    }),
  })
  .transform((raw) => ({
    materializationId: raw.materialization_id,
    materializationKind: raw.materialization_kind,
    provider: raw.provider,
    imConnect: {
      connectId: raw.resources.im_connect.connect_id,
      workspaceId: raw.resources.im_connect.workspace_id,
      botId: raw.resources.im_connect.bot_id,
      botUserId: raw.resources.im_connect.bot_user_id,
      inboundAgentId: raw.resources.im_connect.inbound_agent_id,
    },
  }));
const salixOAuthMaterializationReceiptSchema = z
  .looseObject({
    materialization_id: z.string().min(1),
    materialization_kind: z.enum(["managed_oauth", "remote_mcp_oauth"]),
    provider: z.string().min(1),
    resources: z.looseObject({
      oauth_binding: z.looseObject({
        binding_id: z.string().min(1),
        connection_id: z.string().min(1),
        alias: z.string().min(1),
      }),
      mcp_bindings: z.array(salixMaterializedMcpBindingSchema).default([]),
    }),
  })
  .transform((raw) => ({
    materializationId: raw.materialization_id,
    materializationKind: raw.materialization_kind,
    provider: raw.provider,
    oauthBinding: {
      bindingId: raw.resources.oauth_binding.binding_id,
      connectionId: raw.resources.oauth_binding.connection_id,
      alias: raw.resources.oauth_binding.alias,
    },
    mcpBindings: raw.resources.mcp_bindings,
  }));
export const salixIntegrationMaterializationReceiptSchema = z.union([
  salixImConnectMaterializationReceiptSchema,
  salixOAuthMaterializationReceiptSchema,
]);
export const salixImConnectsSchema = z.array(
  z
    .looseObject({ connect_id: z.string().min(1) })
    .transform((raw) => ({ connectId: raw.connect_id }))
);
export const salixWorkerAgentSchema = z
  .looseObject({
    agent_id: salixStringSchema,
    id: salixStringSchema,
    ref: salixStringSchema,
    worker_ref: salixStringSchema,
    slot: salixStringSchema,
    name: salixStringSchema,
    title: salixStringSchema,
    role: salixStringSchema,
    agent_role: salixStringSchema,
    group_role: salixStringSchema,
    kind: salixStringSchema,
  })
  .transform((raw) => ({
    agentId: z
      .string()
      .min(1)
      .parse(raw.agent_id ?? raw.id),
    ref: raw.ref ?? raw.worker_ref ?? raw.slot,
    name: raw.name ?? raw.title,
    role: z
      .enum(["router", "worker", "worker_agent"])
      .optional()
      .parse(raw.role ?? raw.agent_role ?? raw.group_role ?? raw.kind),
  }));
export const salixWorkerAgentsSchema = z.array(salixWorkerAgentSchema);
export const salixWorkerSessionSchema = z
  .looseObject({
    session_id: salixStringSchema,
    id: salixStringSchema,
    worker_ref: salixStringSchema,
    agent_ref: salixStringSchema,
    status: salixStringSchema,
    state: salixStringSchema,
  })
  .transform((raw) => ({
    sessionId: z
      .string()
      .min(1)
      .parse(raw.session_id ?? raw.id),
    workerRef: raw.worker_ref ?? raw.agent_ref,
    status: raw.status ?? raw.state,
  }));
export const salixWorkerSessionsSchema = z.array(salixWorkerSessionSchema);
export const salixConversationSchema = preprocessSalixObject(
  z.object({ conversationId: z.string().min(1) }),
  normalizeConversationIdentity
);
export const salixConversationDetailSchema = preprocessSalixObject(
  z.object({
    conversationId: z.string().min(1),
    kind: salixStringSchema,
    status: salixStringSchema,
    title: salixStringSchema,
    createdByAgentId: salixStringSchema,
  }),
  normalizeConversationIdentity
);
export const salixConversationPageSchema = preprocessSalixObject(
  z.object({
    data: z.array(salixConversationDetailSchema),
    hasMore: z.boolean().default(false),
    nextCursor: salixStringSchema,
  })
);
export const salixConversationParticipantSchema = preprocessSalixObject(
  z.object({
    participantId: salixStringSchema,
    agentId: salixStringSchema,
    roleLabel: salixStringSchema,
    payload: preprocessSalixObject(
      z.object({ sessionId: salixStringSchema })
    ).optional(),
  })
).transform(({ payload, ...participant }) => ({
  ...participant,
  ...(payload?.sessionId === undefined ? {} : { sessionId: payload.sessionId }),
}));
export const salixConversationParticipantsSchema = preprocessSalixObject(
  z.object({
    participants: z.array(salixConversationParticipantSchema),
  })
).transform((raw) => raw.participants);
export const salixAgentWorkspaceFileEntrySchema = z
  .looseObject({
    path: salixStringSchema,
    kind: salixStringSchema,
    type: salixStringSchema,
    size: salixNumberSchema,
    size_bytes: salixNumberSchema,
    bytes: salixNumberSchema,
  })
  .transform((raw) => ({
    path: z.string().min(1).parse(raw.path),
    kind: z.enum(["file", "dir"]).parse(raw.kind ?? raw.type),
    size: raw.size ?? raw.size_bytes ?? raw.bytes,
  }));
export const salixAgentWorkspaceFileListSchema = z.array(
  salixAgentWorkspaceFileEntrySchema
);
export const salixRouterMessageResponseSchema = z
  .looseObject({
    chain_id: salixStringSchema,
    conversation_id: salixStringSchema,
    message_id: salixStringSchema,
  })
  .transform((raw) => ({
    chainId: raw.chain_id ?? raw.conversation_id ?? raw.message_id,
    conversationId: raw.conversation_id,
    messageId: raw.message_id,
  }));
export const salixDeliveryResponseSchema = z
  .looseObject({
    accepted: z.boolean().optional(),
  })
  .transform((raw) => ({
    accepted: raw.accepted,
  }));
export const salixTranscriptSeedResponseSchema = z
  .looseObject({
    source_id: salixStringSchema,
    requested_count: salixNumberSchema,
    appended_count: salixNumberSchema,
    skipped_count: salixNumberSchema,
    message_count: salixNumberSchema,
    last_message_id: salixNumberSchema,
    compacted_through: salixNumberSchema,
    summary_sequence: salixNumberSchema,
  })
  .transform((raw) => ({
    sourceId: raw.source_id,
    requestedCount: raw.requested_count,
    appendedCount: raw.appended_count,
    skippedCount: raw.skipped_count,
    messageCount: raw.message_count,
    lastMessageId: raw.last_message_id,
    compactedThrough: raw.compacted_through,
    summarySequence: raw.summary_sequence,
  }));
export const salixTranscriptSeedBatchResponseSchema = z
  .looseObject({
    status: z.enum(["staged", "duplicate"]),
    seed_id: z.string().min(1),
    batch_index: z.number().int().nonnegative(),
    batch_digest: z.string().min(1),
    entry_count: z.number().int().nonnegative(),
  })
  .transform((raw) => ({
    status: raw.status,
    seedId: raw.seed_id,
    batchIndex: raw.batch_index,
    batchDigest: raw.batch_digest,
    entryCount: raw.entry_count,
  }));
export const salixTranscriptSeedFinalizeResponseSchema = z
  .looseObject({
    status: z.enum(["finalized", "replayed"]),
    aggregate_digest: z.string().min(1),
    batch_count: z.number().int().nonnegative(),
    requested_count: salixNumberSchema,
    appended_count: salixNumberSchema,
    skipped_count: salixNumberSchema,
    message_count: salixNumberSchema,
    last_message_id: salixNumberSchema,
    compacted_through: salixNumberSchema,
    summary_sequence: salixNumberSchema,
    runtime_kind: salixStringSchema,
  })
  .transform((raw) => ({
    status: raw.status,
    aggregateDigest: raw.aggregate_digest,
    batchCount: raw.batch_count,
    requestedCount: raw.requested_count,
    appendedCount: raw.appended_count,
    skippedCount: raw.skipped_count,
    messageCount: raw.message_count,
    lastMessageId: raw.last_message_id,
    compactedThrough: raw.compacted_through,
    summarySequence: raw.summary_sequence,
    runtimeKind: raw.runtime_kind,
  }));
export const salixConversationSeedResponseSchema = z
  .looseObject({
    requested_count: salixNumberSchema,
    appended_count: salixNumberSchema,
    skipped_count: salixNumberSchema,
    message_count: salixNumberSchema,
  })
  .transform((raw) => ({
    requestedCount: raw.requested_count,
    appendedCount: raw.appended_count,
    skippedCount: raw.skipped_count,
    messageCount: raw.message_count,
  }));
export const salixCompactSessionResponseSchema = z
  .looseObject({
    status: salixStringSchema,
    reason: salixStringSchema,
  })
  .transform((raw) => ({
    status: raw.status,
    reason: raw.reason,
  }));
export const salixSessionMetadataSchema = z
  .looseObject({
    compacted_through: salixNumberSchema,
    summary_sequence: salixNumberSchema,
    message_count: salixNumberSchema,
    summaries: salixArraySchema,
    summaries_json: salixArraySchema,
  })
  .transform((raw) => ({
    compactedThrough: raw.compacted_through,
    summarySequence: raw.summary_sequence,
    messageCount: raw.message_count,
    summaries: raw.summaries ?? raw.summaries_json,
  }));
export const emptySalixSessionMetadata = salixSessionMetadataSchema.parse({});
export const salixStatusSchema = z
  .looseObject({
    status: salixStringSchema,
    state: salixStringSchema,
    runtime_status: salixStringSchema,
  })
  .transform((raw) => raw.status ?? raw.state ?? raw.runtime_status)
  .pipe(z.string().min(1));

export type SalixAgentResponse = z.infer<typeof salixAgentSchema>;

const MessageContentRecordSchema = z.looseObject({
  text: z.json().optional(),
  value: z.json().optional(),
  content: z.json().optional(),
});
const MessageContentSchema = z.json().transform(contentText);
const NullableOptionalStringSchema = z
  .string()
  .min(1)
  .nullish()
  .transform((value) => value ?? undefined);
const ToolCallSchema = z.looseObject({
  id: NullableOptionalStringSchema,
  call_id: NullableOptionalStringSchema,
  name: NullableOptionalStringSchema,
  args: z.json().optional(),
});

const MessageRoleSchema = z.string().optional().transform(normalizeMessageRole);

export const NormalizedSessionMessageSchema = z
  .looseObject({
    role: SalixOptionalStringSchema,
    actor_type: SalixOptionalStringSchema,
    participant_role: SalixOptionalStringSchema,
    sender_type: SalixOptionalStringSchema,
    agent_id: SalixOptionalStringSchema,
    sender_agent_id: SalixOptionalStringSchema,
    source_agent_id: SalixOptionalStringSchema,
    conversation_id: SalixOptionalStringSchema,
    id: z.union([z.string(), z.number()]).optional(),
    message_id: z.union([z.string(), z.number()]).optional(),
    content: MessageContentSchema,
    model: SalixOptionalStringSchema,
    created_at: SalixResponseDateSchema,
    createdAt: z.date().optional(),
    tool_calls: z.array(ToolCallSchema).optional(),
    tool_call_id: SalixOptionalStringSchema,
    tool_use_id: SalixOptionalStringSchema,
    tool_name: SalixOptionalStringSchema,
    name: SalixOptionalStringSchema,
    duration_ms: SalixOptionalFiniteNumberSchema,
    status: SalixOptionalStringSchema,
    error_class: SalixOptionalStringSchema,
    error_message: SalixOptionalStringSchema,
  })
  .transform((message) => {
    const rawId = message.id ?? message.message_id;
    const sequence =
      typeof rawId === "number"
        ? rawId
        : rawId && Number.isFinite(Number(rawId))
          ? Number(rawId)
          : undefined;
    return {
      id: rawId === undefined ? undefined : String(rawId),
      sequence,
      role: MessageRoleSchema.parse(
        message.role ??
          message.actor_type ??
          message.participant_role ??
          message.sender_type
      ),
      agentId: message.agent_id ?? message.sender_agent_id ?? message.source_agent_id,
      conversationId: message.conversation_id,
      content: message.content,
      model: message.model,
      createdAt: message.createdAt ?? message.created_at,
      toolCalls: (message.tool_calls ?? []).flatMap((call) => {
        const id = call.id ?? call.call_id;
        const name = call.name;
        return id && name ? [{ id, name, arguments: call.args ?? null }] : [];
      }),
      toolCallId: message.tool_call_id ?? message.tool_use_id,
      toolName: message.tool_name ?? message.name,
      durationMs: message.duration_ms,
      status: message.status,
      errorClass: message.error_class,
      errorMessage: message.error_message,
    };
  });
export type NormalizedSessionMessage = z.infer<typeof NormalizedSessionMessageSchema>;

const JsonObjectSchema = z.record(z.string(), z.json());
const TraceUsageSchema = z.object({
  prompt_tokens: z.number().optional(),
  completion_tokens: z.number().optional(),
  total_tokens: z.number().optional(),
  cache_read_input_tokens: z.number().optional(),
  cache_write_input_tokens: z.number().optional(),
});
const TraceStageSchema = z.looseObject({
  name: z.string(),
  start_time: z.string().optional(),
  duration_ms: z.number().optional(),
  status: z.string().optional(),
  trace_id: z.string().optional(),
  attributes: JsonObjectSchema.optional(),
});
const TraceToolCallSchema = z.object({
  call_id: z.string().optional(),
  name: z.string().optional(),
  status: z.string().optional(),
  timestamp: z.iso.datetime({ offset: true }).optional(),
  duration_ms: z.number().optional(),
  error_class: z.string().optional(),
  error_message: z.string().optional(),
  input: z.string().optional(),
  input_truncated: z.boolean().optional(),
  output: z.string().optional(),
  output_truncated: z.boolean().optional(),
});
const TraceSkillReadSchema = z.object({
  path: z.string(),
  timestamp: z.iso.datetime({ offset: true }).optional(),
});

export const AgentSessionTraceSchema = z.object({
  trace_id: z.string().optional(),
  usage: TraceUsageSchema.optional(),
  has_more: z.boolean().optional(),
  tool_calls: z.array(TraceToolCallSchema).optional(),
  skill_reads: z.array(TraceSkillReadSchema).optional(),
  stages: z.array(TraceStageSchema).optional(),
  critical_path: TraceStageSchema.optional(),
  archived: z.boolean().optional(),
  reason: z.string().optional(),
});
export type AgentSessionTrace = z.infer<typeof AgentSessionTraceSchema>;

function normalizeMessageRole(
  role: string | undefined
): "system" | "user" | "assistant" | "runtime" | "summary" | "tool" | undefined {
  if (role === "agent") return "assistant";
  if (
    role === "system" ||
    role === "user" ||
    role === "assistant" ||
    role === "runtime" ||
    role === "summary" ||
    role === "tool"
  ) {
    return role;
  }
  return undefined;
}

function contentText(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const content = value.map(contentText).filter(Boolean).join("\n");
    return content || undefined;
  }
  const parsed = MessageContentRecordSchema.safeParse(value);
  if (!parsed.success) return undefined;
  return (
    contentText(parsed.data.text) ??
    contentText(parsed.data.value) ??
    contentText(parsed.data.content)
  );
}
