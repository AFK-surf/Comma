import type { JSONType, z } from "zod";
import type { Trajectory } from "@evalens/core/message";
import type { SalixIntegrationConfig } from "../config";
import type {
  AgentSessionTrace as AgentSessionTraceModel,
  NormalizedSessionMessage,
  salixConversationDetailSchema,
  salixConversationPageSchema,
  salixConversationParticipantSchema,
} from "./protocol";

type JsonObject = Record<string, JSONType>;

export namespace Salix {
  export type EvalFixture = {
    name?: string;
    agents?: Array<{
      role: "router" | "worker";
      ref?: string;
      template?: string;
      slot?: string;
      sessionMode?: "standalone" | "deferred";
      systemPrompt?: string;
      routerSystemPrompt?: string;
      metadata?: JsonObject;
    }>;
  };

  export type CleanupPlan = {
    groupIds?: string[];
    agentIds?: string[];
    imConnects?: Array<{ groupId: string; connectId: string }>;
    imConnectDiscoveryGroupIds?: string[];
    resourceRefs?: string[];
  };

  export type IntegrationConfig = SalixIntegrationConfig;
  export type AppIntegrationConfig = Extract<
    IntegrationConfig,
    { credentials: { type: "app" } }
  >;
  export type OAuthIntegrationConfig = Extract<
    IntegrationConfig,
    { credentials: { type: "oauth" } }
  >;

  export type ImConnectMaterializationReceipt = {
    materializationId: string;
    materializationKind: "im_connect";
    provider: string;
    imConnect: {
      connectId: string;
      workspaceId: string;
      botId: string;
      botUserId: string;
      inboundAgentId: string;
    };
  };

  export type ManagedOAuthMaterializationReceipt = {
    materializationId: string;
    materializationKind: "managed_oauth";
    provider: string;
    oauthBinding: {
      bindingId: string;
      connectionId: string;
      alias: string;
    };
    mcpBindings: Array<{
      bindingId: string;
      alias?: string;
      mcpId?: string;
    }>;
  };

  export type RemoteMCPOAuthMaterializationReceipt = Omit<
    ManagedOAuthMaterializationReceipt,
    "materializationKind"
  > & {
    materializationKind: "remote_mcp_oauth";
  };

  export type IntegrationMaterializationReceipt =
    | ImConnectMaterializationReceipt
    | ManagedOAuthMaterializationReceipt
    | RemoteMCPOAuthMaterializationReceipt;

  export type PreparedRun = {
    tenantId: string;
    groupId: string;
    routerAgentId?: string;
    routerSessionId?: string;
    workerAgentIds: Record<string, string>;
    workerSessionIds?: Record<string, string>;
    workerConversationIds?: Record<string, string>;
    cleanupPlan: CleanupPlan;
  };

  export type ConversationParticipant = z.infer<
    typeof salixConversationParticipantSchema
  >;
  export type Conversation = z.infer<typeof salixConversationDetailSchema>;
  export type ConversationPage = z.infer<typeof salixConversationPageSchema>;

  export type ConnectorTokenCreateInput = {
    groupId: string;
    name?: string;
    alias?: string;
    expiresInSeconds?: number;
  };

  export type ConnectorToken = {
    token: string;
    tokenHash: string;
    tenantId: string;
    groupId: string;
    deviceId: string;
    connectorId: string;
    name: string;
    alias: string;
    server: string;
    connectUrl: string;
    env: {
      SALIX_SERVER: string;
      SALIX_CONNECTOR_TOKEN: string;
    };
    createdAt?: number;
    expiresAt?: number;
  };

  export type Environment = {
    groupId?: string;
    deviceId: string;
    environmentId?: string;
    connectorRunId?: string;
    name?: string;
    alias?: string;
    status?: string;
    os?: string;
    arch?: string;
    capabilities?: JsonObject;
  };

  export type EnvironmentListInput = {
    groupId?: string;
  };

  export type EnvironmentWaitInput = {
    groupId: string;
    deviceId: string;
    alias?: string;
    timeoutMs?: number;
    pollMs?: number;
  };

  export type DockerConnectorSupport =
    | {
        supported: true;
        clientVersion: string;
        serverVersion: string;
      }
    | {
        supported: false;
        reason:
          | "docker_cli_missing"
          | "docker_daemon_unavailable"
          | "unsupported_container_os";
        message: string;
      };

  /**
   * The image entrypoint must launch Salix Connector with its default command,
   * read `/run/secrets/salix-connector.json`, and support an arbitrary numeric
   * UID/GID. The host root is mounted read/write at `/workspace`.
   */
  export type DockerConnectorStartInput = {
    groupId: string;
    image: string;
    name: string;
    alias: string;
    root: {
      hostPath: string;
    };
    serverUrl?: string;
    tokenTtlSeconds?: number;
    connectTimeoutMs?: number;
    pollMs?: number;
  };

  export type DockerConnectorRuntime = {
    kind: "docker";
    containerId: string;
    containerName: string;
    root: {
      hostPath: string;
      containerPath: "/workspace";
    };
    environment: Environment;
    logs(options?: { tail?: number }): Promise<string>;
    stop(): Promise<void>;
  };

  export type PreparedAgentSession = {
    groupId: string;
    agentId: string;
    sessionId: string;
    conversationId?: string;
    agentRole: "router" | "worker";
    agentRef?: string;
    workerRef?: string;
  };

  export type PreparedAgentSessionInput =
    | {
        role: "router";
      }
    | {
        role: "worker";
        workerRef?: string;
        sessionId?: string;
      };

  export type WorkerAgentRef = {
    agentId: string;
    ref?: string;
    name?: string;
    role?: "router" | "worker" | "worker_agent";
    groupId?: string;
  };

  export type WorkerSessionRef = {
    agentId: string;
    sessionId: string;
    workerRef?: string;
    status?: string;
  };

  export type WaitInput = {
    kind?: "router_turn" | "worker_task" | "task_delivery";
    groupId?: string;
    agentId?: string;
    sessionId?: string;
    conversationId?: string;
    pollMs?: number;
    timeoutMs?: number;
  };

  export type SettledState = {
    settled: boolean;
    status?: string;
    elapsedMs: number;
  };

  export type RouterTurnInput = {
    groupId: string;
    message: string | JsonObject;
    wait?: WaitInput;
  };

  export type DirectDeliveryInput = {
    agentId: string;
    sessionId: string;
    message: string | JsonObject;
    role?: "system" | "user" | "assistant";
    /**
     * Stable source identity for the delivery, owned by the caller (the API
     * requires one). It must survive caller-level retries: a commit whose
     * response was lost must dedupe on the retry instead of creating a second
     * message, so the adapter never mints one.
     */
    sourceMessageId: string;
  };

  export type SessionTurnInput = {
    target: PreparedAgentSession;
    /**
     * Stable turn identity (e.g. derived from the dataset item id), reused on
     * retries of the same logical turn; it becomes the delivery's
     * source_message_id on the direct-session path.
     */
    turnId: string;
    message: string | JsonObject;
    context?: string;
    routerDeliveryMode?: "conversation" | "direct_session";
    /**
     * `first_reply` preserves the request/response behavior used by existing
     * callers. `group_quiescent` treats assistant messages as progress events
     * and keeps observing the router session, tool trace, and worker sessions
     * until the whole group has remained settled and unchanged for a bounded
     * quiet window. A terminal Router session whose activity is `waiting` is
     * quiescent only after at least one Worker session exists and every Worker
     * session is terminal. This is required for runtimes that can emit text,
     * pause while a worker runs, and later continue their tool loop without
     * another user message.
     */
    replyCompletion?: "first_reply" | "group_quiescent";
    completionQuiescenceMs?: number;
    pollMs?: number;
    timeoutMs?: number;
    /**
     * Grace period after the router session has stopped with a new internal
     * assistant message but the corresponding conversation still has no
     * visible agent message.
     */
    visibleReplyGraceMs?: number;
    traceLimit?: number;
    /**
     * Read only the newest N session messages through the bounded records
     * endpoint. Omit to preserve the legacy full-message collection behavior.
     */
    messageLimit?: number;
  };

  export type AgentFileWriteInput = {
    agentId: string;
    path: string;
    data: string | Uint8Array | ArrayBuffer;
    contentType?: string;
  };

  export type AgentFileWriteArtifact = {
    agentId: string;
    path: string;
  };

  export type AgentFileListInput = {
    agentId: string;
    path?: string;
  };

  export type AgentWorkspaceFileEntry = {
    path: string;
    kind: "file" | "dir";
    size?: number;
  };

  export type AgentFileReadInput = {
    agentId: string;
    path: string;
  };

  export type AgentFileReadArtifact = {
    agentId: string;
    path: string;
    data: Uint8Array;
    contentType?: string;
  };

  export type AgentFilesDownloadInput = {
    agentId: string;
    path?: string;
    maxFiles?: number;
    maxDepth?: number;
    maxTotalBytes?: number;
  };

  export type AgentDownloadedDirectory = {
    agentId: string;
    path: string;
    relativePath: string;
    kind: "dir";
    source?: AgentWorkspaceFileEntry;
  };

  export type AgentDownloadedFile = {
    agentId: string;
    path: string;
    relativePath: string;
    kind: "file";
    data: Uint8Array;
    size: number;
    contentType?: string;
    source?: AgentWorkspaceFileEntry;
  };

  export type AgentFilesDownloadError = {
    path: string;
    message: string;
    source?: AgentWorkspaceFileEntry;
  };

  export type AgentFilesDownloadArtifact = {
    agentId: string;
    rootPath: string;
    files: AgentDownloadedFile[];
    directories: AgentDownloadedDirectory[];
    errors: AgentFilesDownloadError[];
    totalBytes: number;
    truncated: boolean;
  };

  export type AgentFilesDownloadToDirectoryInput = AgentFilesDownloadInput & {
    outputDir: string;
  };

  export type AgentDownloadedLocalFile = Omit<AgentDownloadedFile, "data"> & {
    localPath: string;
  };

  export type AgentFilesDownloadToDirectoryArtifact = Omit<
    AgentFilesDownloadArtifact,
    "files"
  > & {
    outputDir: string;
    files: AgentDownloadedLocalFile[];
  };

  export type TranscriptSeedEntry = {
    role: "user" | "assistant" | "runtime" | "summary" | "tool";
    content: string;
    summary?: string;
    type?: string;
    source?: string;
    sourceRefs?: JsonObject;
    sourceMessageId?: string;
    dedupeKey?: string;
    runtimeMessageId?: string;
    createdAt?: string | number;
    model?: string;
    providerMeta?: JsonObject;
    toolCalls?: Array<{
      id: string;
      name: string;
      args?: JsonObject;
    }>;
    toolCallId?: string;
    toolUseId?: string;
    toolName?: string;
    status?: string;
    durationMs?: number;
    input?: JSONType;
    output?: JSONType;
    errorClass?: string;
    errorMessage?: string;
    startedAt?: string | number;
    completedAt?: string | number;
    inputTokens?: number;
    outputTokens?: number;
    cacheReadInputTokens?: number;
    cacheWriteInputTokens?: number;
    turnId?: string;
    roundId?: string;
    requestId?: string;
    traceId?: string;
  };

  export type TranscriptSeedInput = {
    agentId: string;
    sessionId: string;
    sourceId?: string;
    createdAt?: string | number;
    entries: TranscriptSeedEntry[];
  };

  export type TranscriptSeedBatchInput = TranscriptSeedInput & {
    seedId: string;
    batchIndex: number;
  };

  export type TranscriptSeedBatchArtifact = {
    status: "staged" | "duplicate";
    seedId: string;
    batchIndex: number;
    batchDigest: string;
    entryCount: number;
  };

  export type TranscriptSeedFinalizeInput = {
    agentId: string;
    sessionId: string;
    seedId: string;
    expectedBatchCount: number;
  };

  export type TranscriptSeedFinalizeArtifact = TranscriptSeedArtifact & {
    status: "finalized" | "replayed";
    aggregateDigest: string;
    batchCount: number;
    runtimeKind?: string;
  };

  export type TranscriptSeedMode =
    | "router_user_chat"
    | "worker_user_chat"
    | "agent_task_worker"
    | "agent_task_delegator";

  export type VisibleTranscriptSeedInput = {
    target: PreparedAgentSession;
    mode: TranscriptSeedMode;
    history: TranscriptSeedEntry[];
    sourceId?: string;
    createdAt?: string | number;
  };

  export type VisibleTranscriptSeedArtifact = {
    conversation?: {
      groupId: string;
      conversationId: string;
      requestedCount?: number;
      appendedCount?: number;
      skippedCount?: number;
      messageCount?: number;
    };
    session: TranscriptSeedArtifact;
  };

  export type TranscriptSeedEntryBuildOptions = {
    sourcePrefix?: string;
    defaultType?: string;
    runtimeType?: string;
    includeDedupeKey?: boolean;
  };

  export type TranscriptSeedArtifact = {
    agentId: string;
    sessionId: string;
    sourceId?: string;
    requestedCount?: number;
    appendedCount?: number;
    skippedCount?: number;
    messageCount?: number;
    lastMessageId?: number;
    compactedThrough?: number;
    summarySequence?: number;
  };

  export type CompactSessionInput = {
    agentId: string;
    sessionId: string;
  };

  export type CompactSessionArtifact = {
    agentId: string;
    sessionId: string;
    status?: string;
    reason?: string;
  };

  export type ListWorkersInput = {
    groupId: string;
  };

  export type ListWorkerSessionsInput = {
    groupId?: string;
    workerAgentId?: string;
    workerAgentIds?: string[];
    includeHidden?: boolean;
  };

  export type ChainCollectInput = {
    groupId?: string;
    workerAgentIds?: string[];
  };

  export type SessionCollectInput = {
    agentId: string;
    sessionId: string;
    messageLimit?: number;
  };

  export type AgentTraceCollectInput = SessionCollectInput & {
    traceLimit?: number;
  };

  export type AgentSessionTrace = AgentSessionTraceModel;
  export type SessionTraceFile = {
    schemaVersion: 1;
    kind: "salix.session_trace";
    identity: {
      tenantId?: string;
      agentId: string;
      sessionId: string;
    };
    collectedAt: string;
    source: {
      sessionEndpoint: string;
      messagesEndpoint: string;
      traceEndpoint: string;
      traceLimit?: number;
      messageLimit?: number;
      messageHasMore?: boolean;
      hasMore?: boolean;
    };
    session: {
      messages: SessionMessage[];
      compactedThrough?: number;
      summarySequence?: number;
      messageCount?: number;
      summaries?: JSONType[];
    };
    execution: AgentSessionTrace;
    related?: {
      delegatedTaskIds?: string[];
      workerSessionIds?: string[];
      artifactIds?: string[];
    };
  };
  export type SessionTraceIdentity = SessionTraceFile["identity"];
  export type SessionTraceSource = SessionTraceFile["source"];
  export type SessionTraceMessage = SessionMessage;
  export type SessionTraceSnapshot = SessionTraceFile["session"];
  export type SessionTraceRelated = NonNullable<SessionTraceFile["related"]>;

  export type SessionTraceCollectInput = AgentTraceCollectInput & {
    related?: SessionTraceRelated;
  };

  export type SessionMessage = NormalizedSessionMessage;

  export type AssistantReply = {
    content: string;
    messageId?: number;
    message: SessionMessage;
  };

  export type AssistantReplyWaitInput = {
    agentId: string;
    sessionId: string;
    afterMessageId: number;
    pollMs?: number;
    timeoutMs?: number;
    messageLimit?: number;
  };

  export type AssistantReplyWaitResult = {
    elapsedMs: number;
    afterMessageId: number;
    timedOut?: boolean;
    failureReason?: "timeout" | "undelivered_session_reply";
    messageId?: number;
    replyMessageId?: string;
    sessionReplyMessageId?: string;
    answerSource?: "router_conversation" | "session_transcript";
    answer?: string;
    session?: SessionArtifactBundle;
  };

  export type SessionTurnArtifact = {
    target: PreparedAgentSession;
    delivery: ChainRunArtifact | DeliveryArtifact;
    replyWait: AssistantReplyWaitResult;
    answer?: string;
    trace: SessionTraceFile;
    trajectory: Trajectory;
  };

  export type RunOutputCollectInput<Result extends JSONType> = {
    result: Result;
    artifactAgents?: Array<{ agentId: string }>;
    traceSessions?: SessionTraceCollectInput[];
  };

  export type ChainRunArtifact = {
    chainId?: string;
    conversationId?: string;
    groupId: string;
    messageId?: string;
    messageResult?: {
      chainId?: string;
      conversationId?: string;
      messageId?: string;
    };
    settled?: SettledState;
  };

  export type DeliveryArtifact = {
    agentId: string;
    sessionId: string;
    accepted?: boolean;
    conversationId?: string;
    messageId?: string;
  };

  export type SessionArtifactBundle = {
    agentId: string;
    sessionId: string;
    session?: JSONType;
    messages: SessionMessage[];
    messageHasMore?: boolean;
    nextBefore?: string;
  };

  export type AgentTraceArtifact = {
    agentId: string;
    sessionId: string;
    trace?: AgentSessionTrace;
  };

  export type ChainArtifactBundle = {
    groupId?: string;
    routerConversation?: JSONType;
    routerMessages: SessionMessage[];
    workerSessions: WorkerSessionRef[];
    sessionBundles: SessionArtifactBundle[];
  };
}
