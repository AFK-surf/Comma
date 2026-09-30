import {
  browserBindingSchema,
  browserResultSchema,
  browserEventSchema,
  browserPath,
  type BrowserBinding,
  type BrowserResult,
  type BrowserEvent,
} from "./browser";
import {
  subscriptionResetSchema,
  type SubscriptionReset,
  subscriptionAccountSchema,
  subscriptionPageSchema,
  subscriptionOAuthSchema,
  subscriptionOAuthPollSchema,
  type SubscriptionAccount,
  type SubscriptionPage,
  type SubscriptionOAuth,
  type SubscriptionProvider,
} from "./subscriptionAccounts";
import {
  meetingTaskReceiptSchema,
  type MeetingTaskReceipt,
  type MeetingTaskEntry,
  type MeetingTaskCommand,
} from "./meeting-tasks";
import {
  modelTemplateSchema,
  discoveredModelsSchema,
  type DiscoveredModels,
  type ModelDiscoveryInput,
  agentModelsSchema,
  workerModelsSchema,
  agentModelSchema,
  deletedModelSchema,
  type ModelTemplate,
  type ModelTemplateInput,
  type SubscriptionModelChoice,
  type AgentModels,
  type AgentModel,
} from "./modelTemplates";
import type {
  CommaApiConfig,
  CommaApiSessionTransport,
  CommaApiErrorBody,
  CommaConversation,
  CommaTaskShare,
  CommaTaskShareEntry,
  CommaConversationPreview,
  CommaConversationEvent,
  CommaConversationListEvent,
  CommaTaskSearchResult,
  CommaTaskOrder,
  CommaPlugin,
  CommaPluginInstallResult,
  CommaPluginPersonalSources,
  CommaPluginAccountConfirmation,
  CommaPluginConfirmedAccount,
  CommaRecommendationEnvelope,
  CommaRecommendationLinkPreview,
  CommaRecommendationSettingsPatch,
  CommaGroupFile,
  CommaWorkspaceBootstrap,
  CommaTelegramIntegrationState,
  CommaIMessageIntegrationState,
  CommaIMessageClaim,
  CommaWeChatConnection,
  CommaWeChatIntegrationState,
  CommaTelegramConnectAttempt,
  JsonValue,
} from "./types";
import { sessionAdmissionFailureSchema } from "@comma/session-contract";
import {
  commaDeviceSchema,
  commaDevicePageSchema,
  type CommaDevice,
  type CommaDevicePage,
  commaApiErrorBodySchema,
  commaConnectorTokenRevocationSchema,
  commaConnectorTokenSchema,
  commaRouterApiKeyCreatedSchema,
  commaRouterApiKeyDeletionSchema,
  commaRouterApiKeySchema,
  commaVoiceApiKeyCreatedSchema,
  commaVoiceApiKeySchema,
  commaVoiceIntegrationSchema,
  commaVoiceVerificationSchema,
  commaSignalIntegrationSchema,
  commaSignalNumberSchema,
  commaChatSuggestionSchema,
  commaConversationEventSchema,
  commaTaskParticipantStatusesSchema,
  type CommaTaskParticipantStatuses,
  commaConversationListEventSchema,
  commaConversationSchema,
  commaTaskShareSchema,
  commaTaskSharePageSchema,
  commaConversationPreviewSchema,
  commaTaskSearchResultSchema,
  commaTaskOrderSchema,
  commaTaskLabelCatalogSchema,
  type CommaTaskLabelCatalog,
  salixMessageSchema,
  commaPageSchema,
  commaPluginAuthorizationSchema,
  commaPluginInstallResultSchema,
  commaPluginPersonalSourcesSchema,
  commaPluginAccountConfirmationSchema,
  commaPluginConfirmedAccountSchema,
  commaPluginSchema,
  commaRecommendationEnvelopeSchema,
  commaRecommendationLinkPreviewSchema,
  commaRecommendationRefreshSchema,
  commaSkillDetailSchema,
  commaSkillFileSchema,
  commaSkillSchema,
  commaGroupFileSchema,
  commaWorkspaceBootstrapSchema,
  commaTelegramIntegrationStateSchema,
  commaIMessageIntegrationStateSchema,
  commaIMessageClaimSchema,
  commaWeChatConnectionSchema,
  commaWeChatIntegrationStateSchema,
  commaTelegramConnectAttemptSchema,
  commaTelegramDisconnectSchema,
  commaUserProfileSchema,
  commaSynchronicityDeviceSchema,
  commaSynchronicityStatusSchema,
  commaWorkspaceSchema,
  commaBillingPlanSchema,
  commaBillingSummarySchema,
  commaBillingSessionSchema,
  commaBillingChangeSchema,
  commaBillingChangePreviewSchema,
  commaRedemptionResultSchema,
  type CommaChatSuggestion,
  type CommaConnectorToken,
  type CommaRouterApiKey,
  type CommaRouterApiKeyCreated,
  type CommaVoiceApiKey,
  type CommaVoiceApiKeyCreated,
  type CommaVoiceIntegration,
  type CommaVoiceVerification,
  type CommaSignalIntegration,
  type CommaSignalNumber,
  type SalixMessage,
  type SalixBlobRef,
  type CommaSkill,
  type CommaSkillDetail,
  type CommaSkillFile,
  type CommaWorkspace,
  type CommaUserProfile,
  type CommaSynchronicityDevice,
  type CommaSynchronicityStatus,
  type CommaBillingPlan,
  type CommaBillingSummary,
  type CommaBillingSession,
  type CommaBillingChange,
  type CommaBillingChangePreview,
  type CommaRedemptionResult,
} from "./schemas";
import { z } from "zod";
import { getActiveCommaConfig } from "@comma/config";

const sessionChangedResponseSchema = z.strictObject({
  error: z.literal("session_changed"),
});

const sessionProductLeaseUnavailableResponseSchema = z.strictObject({
  error: sessionAdmissionFailureSchema,
});

export class CommaApiError extends Error {
  readonly status: number;
  readonly body: CommaApiErrorBody | undefined;

  constructor(status: number, message: string, body?: CommaApiErrorBody) {
    super(message);
    this.name = "CommaApiError";
    this.status = status;
    this.body = body;
  }
}

const computeWorkloadSchema = z.object({
  id: z.string(),
  environment_id: z.string(),
  kind: z.string(),
  desired_state: z.string().optional(),
  observed_state: z.string(),
  updated_at: z.string().optional(),
});
const computeProjectionSchema = z.object({
  workspace_name: z.string().nullable().optional(),
  environments: z.array(
    z.object({
      id: z.string(),
      desired_state: z.string(),
      observed_state: z.string(),
      can_create: z.boolean().optional(),
    })
  ),
  workloads: z.array(computeWorkloadSchema),
  next_workload_cursor: z.string().nullable().optional(),
});
export type CommaComputeProjection = z.infer<typeof computeProjectionSchema>;
export type CommaComputeWorkload = z.infer<typeof computeWorkloadSchema>;

// The owner's automatic proactive messages. Absent a choice they are on.
const proactiveSettingsSchema = z.object({ enabled: z.boolean() });
export type CommaProactiveSettings = z.infer<typeof proactiveSettingsSchema>;

export interface CommaApiClient {
  getCompute(
    workspaceId: string,
    options?: {
      signal?: AbortSignal;
      workloadAfter?: string;
    }
  ): Promise<CommaComputeProjection>;
  createShellWorkload(
    workspaceId: string,
    environmentId: string,
    requestId: string
  ): Promise<{ workload: CommaComputeWorkload }>;
  getComputeCreation(
    workspaceId: string,
    requestId: string,
    options?: { signal?: AbortSignal }
  ): Promise<{ workload: CommaComputeWorkload }>;

  listSubscriptionAccounts(
    workspaceId: string,
    after?: string,
    options?: { signal?: AbortSignal }
  ): Promise<SubscriptionPage>;
  createSubscriptionAccount(
    workspaceId: string,
    input: { provider: SubscriptionProvider; credentials: Record<string, JsonValue> }
  ): Promise<SubscriptionAccount>;
  updateSubscriptionAccount(
    workspaceId: string,
    id: string,
    input: {
      version: string;
      disabled?: boolean;
      credentials?: Record<string, JsonValue>;
    }
  ): Promise<SubscriptionAccount>;
  deleteSubscriptionAccount(
    workspaceId: string,
    id: string,
    version: string
  ): Promise<{ deleted: true }>;
  refreshSubscriptionQuota(
    workspaceId: string,
    id: string
  ): Promise<SubscriptionAccount>;
  resetSubscriptionQuota(
    workspaceId: string,
    id: string,
    input: { version: string; request_id: string }
  ): Promise<SubscriptionReset>;
  beginSubscriptionOAuth(
    workspaceId: string,
    input: {
      provider: SubscriptionProvider;
      account_id?: string;
      version?: string;
      mode?: "device" | "callback";
    }
  ): Promise<SubscriptionOAuth>;
  pollSubscriptionOAuth(
    workspaceId: string,
    id: string
  ): Promise<SubscriptionAccount | { status: "pending"; interval: number }>;
  completeSubscriptionOAuth(
    workspaceId: string,
    id: string,
    code: string
  ): Promise<SubscriptionAccount>;

  renameDevice(
    workspaceId: string,
    deviceId: string,
    name: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaDevice>;
  removeDevice(
    workspaceId: string,
    deviceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<{ removed: boolean }>;
  listDevices(
    workspaceId: string,
    options?: { cursor?: string; signal?: AbortSignal }
  ): Promise<CommaDevicePage>;
  getDevice(
    workspaceId: string,
    deviceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaDevice>;
  setDeviceAccess(
    workspaceId: string,
    deviceId: string,
    allow: boolean,
    options?: { signal?: AbortSignal }
  ): Promise<{ allows_operations: boolean }>;
  listBillingPlans(options?: { signal?: AbortSignal }): Promise<CommaBillingPlan[]>;
  getBillingSummary(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaBillingSummary>;
  createBillingCheckout(
    workspaceId: string,
    planKey: string
  ): Promise<CommaBillingSession>;
  createBillingPortal(workspaceId: string): Promise<CommaBillingSession>;
  previewBillingSubscriptionChange(
    workspaceId: string,
    planKey: string
  ): Promise<CommaBillingChangePreview>;
  changeBillingSubscription(
    workspaceId: string,
    planKey: string,
    preview: CommaBillingChangePreview,
    requestId: string
  ): Promise<CommaBillingChange>;
  cancelBillingSubscriptionRenewal(workspaceId: string): Promise<CommaBillingChange>;
  redeemBillingCode(workspaceId: string, code: string): Promise<CommaRedemptionResult>;
  getProfile(options?: { signal?: AbortSignal }): Promise<CommaUserProfile>;
  updateProfile(
    attrs: { name: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaUserProfile>;
  uploadAvatar(
    file: File,
    options?: { signal?: AbortSignal }
  ): Promise<CommaUserProfile>;
  deleteAvatar(options?: { signal?: AbortSignal }): Promise<CommaUserProfile>;
  fetchAvatar(
    avatarRevision: string,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  listWorkspaces(options?: { signal?: AbortSignal }): Promise<CommaWorkspace[]>;
  discoverModels(
    workspaceId: string,
    input: ModelDiscoveryInput,
    options?: { signal?: AbortSignal }
  ): Promise<DiscoveredModels>;
  listModelTemplates(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<ModelTemplate[]>;
  createModelTemplate(
    workspaceId: string,
    input: ModelTemplateInput
  ): Promise<ModelTemplate>;
  resolveSubscriptionModel(
    workspaceId: string,
    input: SubscriptionModelChoice
  ): Promise<ModelTemplate>;
  updateModelTemplate(
    workspaceId: string,
    id: string,
    input: Partial<ModelTemplateInput>
  ): Promise<ModelTemplate>;
  deleteModelTemplate(workspaceId: string, id: string): Promise<{ deleted: true }>;
  getAgentModels(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<AgentModels>;
  /** `templateId: null` returns this Agent to its platform role default. */
  setAgentModel(
    workspaceId: string,
    target: string,
    templateId: string | null
  ): Promise<AgentModel>;

  getWorkerModels(workspaceId: string, cursor: string): Promise<AgentModels["workers"]>;
  setWorkerDefault(
    workspaceId: string,
    templateId: string | null
  ): Promise<{ template_id: string | null }>;

  /** Whether this user's Workspace has its org and network on the Synchronicity control plane. */
  getSynchronicityStatus(options?: {
    signal?: AbortSignal;
  }): Promise<CommaSynchronicityStatus>;
  /** Enrolls this device's node key into the Workspace's network; answers with the zone to bind. */
  enrollSynchronicityDevice(
    attrs: { label: string; nk: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaSynchronicityDevice>;
  enterMeetingTask(
    groupId: string,
    entry: MeetingTaskEntry
  ): Promise<MeetingTaskReceipt>;
  updateMeetingTask(
    groupId: string,
    occurrenceId: string,
    command: MeetingTaskCommand
  ): Promise<MeetingTaskReceipt>;
  bootstrapWorkspace(options?: {
    signal?: AbortSignal;
  }): Promise<CommaWorkspaceBootstrap>;
  getIMessageIntegration(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaIMessageIntegrationState>;
  startIMessageConnect(workspaceId: string): Promise<CommaIMessageClaim>;
  getWeChatIntegration(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaWeChatIntegrationState>;
  startWeChatConnect(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaWeChatConnection>;
  pollWeChatConnect(
    workspaceId: string,
    attemptId: string,
    verifyCode?: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaWeChatConnection>;
  cancelWeChatConnect(
    workspaceId: string,
    attemptId: string,
    options?: { signal?: AbortSignal }
  ): Promise<void>;
  disconnectWeChat(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<void>;
  cancelIMessageConnect(workspaceId: string, code: string): Promise<void>;
  disconnectIMessage(workspaceId: string): Promise<void>;
  getTelegramIntegration(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaTelegramIntegrationState>;
  startTelegramConnect(workspaceId: string): Promise<CommaTelegramConnectAttempt>;
  cancelTelegramConnect(workspaceId: string, attempt: { state: string }): Promise<void>;
  disconnectTelegram(workspaceId: string): Promise<boolean>;
  createConnectorToken(
    workspaceId: string,
    attrs?: {
      name?: string;
      alias?: string;
      expiresInSeconds?: number;
      scope?: "local_file_read";
      stableDeviceId?: string;
      installation?: boolean;
    },
    options?: { signal?: AbortSignal }
  ): Promise<CommaConnectorToken>;
  revokeConnectorToken(
    workspaceId: string,
    attrs: { token: string },
    options?: { signal?: AbortSignal }
  ): Promise<void>;
  listRouterApiKeys(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaRouterApiKey[]>;
  createRouterApiKey(
    workspaceId: string,
    attrs: { name: string; expiresAt?: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaRouterApiKeyCreated>;
  updateRouterApiKey(
    workspaceId: string,
    keyId: string,
    attrs: { name?: string; status?: "active" | "disabled"; expiresAt?: string | null },
    options?: { signal?: AbortSignal }
  ): Promise<CommaRouterApiKey>;
  deleteRouterApiKey(
    workspaceId: string,
    keyId: string,
    options?: { signal?: AbortSignal }
  ): Promise<void>;
  listVoiceApiKeys(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceApiKey[]>;
  createVoiceApiKey(
    workspaceId: string,
    attrs: { name: string; expiresAt?: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceApiKeyCreated>;
  updateVoiceApiKey(
    workspaceId: string,
    keyId: string,
    attrs: { name?: string; status?: "active" | "disabled"; expiresAt?: string | null },
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceApiKey>;
  deleteVoiceApiKey(
    workspaceId: string,
    keyId: string,
    options?: { signal?: AbortSignal }
  ): Promise<void>;
  getVoiceIntegration(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceIntegration>;
  /** Sends an SMS code to `e164`. The number is bound only after `checkVoiceNumber`. */
  startVoiceNumberVerification(
    workspaceId: string,
    attrs: { e164: string; line?: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceVerification>;
  checkVoiceNumberVerification(
    workspaceId: string,
    attrs: { e164: string; code: string; line?: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceIntegration>;
  removeVoiceNumber(
    workspaceId: string,
    e164: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceIntegration>;
  /** Sets the caller PIN of `e164`; an empty `pin` clears it. */
  setVoiceNumberPin(
    workspaceId: string,
    attrs: { e164: string; pin: string },
    options?: { signal?: AbortSignal }
  ): Promise<CommaVoiceIntegration>;
  /** The Signal chats connected to the workspace's default group. */
  getSignalIntegration(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalIntegration>;
  /** Creates a one-time connection code; the result carries it once, in `claim`. */
  startSignalClaim(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalIntegration>;
  cancelSignalClaim(
    workspaceId: string,
    claimId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalIntegration>;
  removeSignalBinding(
    workspaceId: string,
    bindingId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalIntegration>;
  getSignalNumber(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalNumber>;
  /** Sets the workspace's own Signal number; an empty `number` uses the platform number. */
  setSignalNumber(
    workspaceId: string,
    number: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSignalNumber>;
  setTaskArchived(
    groupId: string,
    conversationId: string,
    action: "archive" | "unarchive",
    version: number
  ): Promise<CommaConversation>;
  /** The Task's active public share link, or `undefined` when it is not shared. */
  getTaskShare(
    groupId: string,
    conversationId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaTaskShare | undefined>;
  /** Shares the Task, or moves its existing link's cutoff to the latest message. */
  publishTaskShare(groupId: string, conversationId: string): Promise<CommaTaskShare>;
  /** Replaces the link; the previous URL stops working. */
  resetTaskShare(groupId: string, conversationId: string): Promise<CommaTaskShare>;
  /** Stops sharing the Task. */
  revokeTaskShare(groupId: string, conversationId: string): Promise<void>;
  /** One page of the Group's active share links, most recently shared first. */
  listTaskShares(
    groupId: string,
    opts?: { cursor?: string; limit?: number; signal?: AbortSignal }
  ): Promise<{
    data: CommaTaskShareEntry[];
    hasMore: boolean;
    nextCursor?: string;
  }>;
  getTaskSummaries(groupId: string, ids: string[]): Promise<CommaConversation[]>;
  listConversations(groupId: string): Promise<CommaConversation[]>;
  renameTask(
    groupId: string,
    conversationId: string,
    title: string
  ): Promise<CommaConversation>;
  /** Replace a Task's labels with ids from the Group catalog. */
  setTaskLabels(
    groupId: string,
    conversationId: string,
    labelIds: readonly string[]
  ): Promise<CommaConversation>;
  /** The Group's label catalog plus any agent proposals awaiting a human. */
  listTaskLabels(
    groupId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaTaskLabelCatalog>;
  createTaskLabel(
    groupId: string,
    attrs: { name: string; color?: string; description?: string }
  ): Promise<CommaTaskLabelCatalog>;
  updateTaskLabel(
    groupId: string,
    labelId: string,
    attrs: { name?: string; color?: string; description?: string }
  ): Promise<CommaTaskLabelCatalog>;
  deleteTaskLabel(groupId: string, labelId: string): Promise<CommaTaskLabelCatalog>;
  resolveTaskLabelProposal(
    groupId: string,
    proposalId: string,
    decision: "approve" | "reject",
    options?: { autoApprove: true }
  ): Promise<CommaTaskLabelCatalog>;
  setTaskLabelApprovalPolicy(
    groupId: string,
    policy: CommaTaskLabelCatalog["approval_policy"]
  ): Promise<CommaTaskLabelCatalog>;
  /** The Group's stored Task-board arrangement, as bucket → ordered task ids. */
  getTaskOrder(groupId: string): Promise<CommaTaskOrder>;
  /** Replace one bucket's stored Task order; an empty list clears the bucket. */
  putTaskOrder(groupId: string, bucket: string, ids: string[]): Promise<CommaTaskOrder>;
  listConversationPage(
    groupId: string,
    opts?: {
      archive?: "exclude" | "only" | "include";
      cursor?: string;
      limit?: number;
      signal?: AbortSignal;
    }
  ): Promise<{
    data: CommaConversation[];
    hasMore: boolean;
    nextCursor?: string;
  }>;
  searchTasks(
    groupId: string,
    query: string,
    opts?: { limit?: number; signal?: AbortSignal }
  ): Promise<CommaTaskSearchResult[]>;
  pollConversations(
    groupId: string,
    opts?: {
      archive?: "exclude" | "only" | "include";
      cursor?: string;
      etag?: string;
      limit?: number;
      signal?: AbortSignal;
    }
  ): Promise<{
    data?: CommaConversation[];
    etag?: string;
    hasMore?: boolean;
    nextCursor?: string;
    notModified: boolean;
  }>;
  ensureGroupChat(
    groupId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaConversation>;
  getConversation(
    groupId: string,
    conversationId: string,
    options?: { messageLimit?: number; signal?: AbortSignal }
  ): Promise<CommaConversation>;
  getConversationPreview(
    groupId: string,
    conversationId: string,
    options?: { includeWorker?: boolean; signal?: AbortSignal }
  ): Promise<CommaConversationPreview>;
  acceptTaskReview(
    groupId: string,
    conversationId: string,
    reviewVersion: number
  ): Promise<CommaConversation>;
  pollConversation(
    groupId: string,
    conversationId: string,
    opts?: { etag?: string; signal?: AbortSignal }
  ): Promise<{
    conversation?: CommaConversation;
    etag?: string;
    notModified: boolean;
  }>;
  listWorkspaceSkills(workspaceId: string): Promise<CommaSkill[]>;
  getWorkspaceSkill(
    workspaceId: string,
    skillId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSkillDetail>;
  getWorkspaceSkillFile(
    workspaceId: string,
    skillId: string,
    path: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaSkillFile>;
  listWorkspacePlugins(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaPlugin[]>;
  installWorkspacePlugin(
    workspaceId: string,
    pluginId: string,
    options?: {
      authorizationState?: string;
      signal?: AbortSignal;
      verifyOnly?: boolean;
    }
  ): Promise<CommaPluginInstallResult>;
  uninstallWorkspacePlugin(workspaceId: string, pluginId: string): Promise<CommaPlugin>;
  getPluginPersonalSources(
    workspaceId: string,
    pluginId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaPluginPersonalSources>;
  preparePluginAccountConfirmation(
    workspaceId: string,
    pluginId: string,
    toolkit: string,
    connectionId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaPluginAccountConfirmation>;
  confirmPluginAccount(
    workspaceId: string,
    pluginId: string,
    state: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaPluginConfirmedAccount>;
  reauthorizeWorkspacePlugin(
    workspaceId: string,
    pluginId: string,
    options: {
      connectionId?: string;
      authorizationState?: string;
      signal?: AbortSignal;
      verifyOnly?: boolean;
    }
  ): Promise<CommaPluginInstallResult>;
  cancelPluginOperation(
    workspaceId: string,
    pluginId: string,
    state: string
  ): Promise<void>;
  getRecommendations(
    workspaceId: string,
    options?: { locale?: string; signal?: AbortSignal; timezone?: string }
  ): Promise<CommaRecommendationEnvelope>;
  updateRecommendationSettings(
    workspaceId: string,
    settings: CommaRecommendationSettingsPatch
  ): Promise<CommaRecommendationEnvelope>;
  getProactiveSettings(
    groupId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaProactiveSettings>;
  updateProactiveSettings(
    groupId: string,
    settings: CommaProactiveSettings & { requestId: string }
  ): Promise<CommaProactiveSettings>;
  refreshRecommendations(workspaceId: string): Promise<{
    envelope: CommaRecommendationEnvelope;
    run: {
      generation: number;
      id: string;
      sourceRevision: number;
      status: "pending" | "running" | "published" | "superseded" | "failed";
      trigger: "manual" | "schedule" | "agent_tool";
    };
  }>;
  getRecommendationLinkPreview(
    workspaceId: string,
    link: { href: string; sourceId?: string | undefined },
    options?: { signal?: AbortSignal }
  ): Promise<CommaRecommendationLinkPreview>;
  uploadGroupFile(
    groupId: string,
    attrs: { data: Blob; name: string; signal?: AbortSignal }
  ): Promise<CommaGroupFile>;
  fetchGroupFile(
    groupId: string,
    path: string,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  fetchAgentBlob(
    groupId: string,
    agentId: string,
    ref: SalixBlobRef,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  fetchConversationAttachment(
    groupId: string,
    conversationId: string,
    messageId: string,
    attachmentIndex: number,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  listMessages(groupId: string, conversationId: string): Promise<SalixMessage[]>;
  getMessageContext(
    groupId: string,
    conversationId: string,
    messageId: string,
    options?: { signal?: AbortSignal }
  ): Promise<SalixMessage[]>;
  generateChatSuggestions(
    groupId: string,
    conversationId: string,
    options?: { locale?: string; signal?: AbortSignal }
  ): Promise<CommaChatSuggestion[]>;
  sendMessage(
    groupId: string,
    conversationId: string,
    attrs: {
      text: string;
      clientRequestId?: string;
      clientDeviceId?: string;
      replyToMessageId?: string;
      localFiles?: CommaLocalFileRef[];
      skills?: { location: string }[];
    }
  ): Promise<CommaConversation>;
  clearBrowserStorage(workspaceId: string): Promise<{ cleared: boolean }>;
  listBrowsers(
    workspaceId: string,
    target: { conversationId: string; participantId: string },
    signal?: AbortSignal
  ): Promise<{ browsers: BrowserBinding[] }>;
  browserCommand(
    workspaceId: string,
    browser: BrowserBinding,
    viewerId: string,
    operation: string,
    args?: Record<string, JsonValue>
  ): Promise<BrowserResult>;
  streamBrowser(
    workspaceId: string,
    browser: BrowserBinding,
    tabId: string,
    viewerId: string,
    signal: AbortSignal,
    onEvent: (event: BrowserEvent) => void
  ): Promise<void>;
  streamConversationEvents(
    groupId: string,
    conversationId: string,
    opts: {
      signal?: AbortSignal;
      waitMs?: number;
      onEvent: (event: CommaConversationEvent, eventName: string) => void;
    }
  ): Promise<void>;
  streamConversationListEvents(
    groupId: string,
    opts: {
      conversationId?: string;
      onParticipantStatuses?: (event: CommaTaskParticipantStatuses) => void;
      signal?: AbortSignal;
      waitMs?: number;
      onEvent: (event: CommaConversationListEvent) => void;
    }
  ): Promise<void>;
}

export type CommaLocalFileRef = {
  displayName: string;
  localFileRef: string;
  mediaType: string;
  size: number;
};

export function createCommaApi(config: CommaApiConfig): CommaApiClient {
  if (config.sessionTransport && config.token.trim()) {
    throw new Error(
      "A host Session transport and a renderer bearer token cannot be used together."
    );
  }
  const fetchImpl = config.fetch ?? fetch;
  const baseUrl = config.baseUrl.replace(/\/+$/, "");
  const conversationListCache = new Map<
    string,
    {
      data: CommaConversation[];
      etag?: string;
      hasMore: boolean;
      nextCursor?: string;
    }
  >();

  function responseError(response: Response) {
    return sessionTransportApiError(
      response,
      config.sessionTransport,
      config.onUnauthorized
    );
  }

  async function request<T extends z.ZodType>(
    method: string,
    path: string,
    schema: T,
    body?: Record<string, JsonValue>,
    signal?: AbortSignal
  ): Promise<z.output<T>> {
    const init: RequestInit = {
      credentials: config.sessionTransport?.credentials ?? "include",
      method,
      headers: requestHeaders(config.token, body, config.sessionTransport),
    };

    const combinedSignal = combineSignals(signal, config.sessionTransport?.signal);
    if (combinedSignal) {
      init.signal = combinedSignal;
    }

    if (body) {
      init.body = JSON.stringify(body);
    }

    const response = await fetchImpl(joinUrl(baseUrl, path), init);

    if (!response.ok) {
      throw await responseError(response);
    }

    return schema.parse(await response.json());
  }

  return {
    getCompute(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/compute?${new URLSearchParams({ workload_after: options.workloadAfter ?? "" })}`,
        computeProjectionSchema,
        undefined,
        options.signal
      );
    },
    getComputeCreation(workspaceId, creationRequestId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/compute/requests/${encodeURIComponent(creationRequestId)}`,
        z.object({ workload: computeWorkloadSchema }),
        undefined,
        options.signal
      );
    },
    createShellWorkload(workspaceId, environmentId, creationRequestId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/compute/workloads`,
        z.object({ workload: computeWorkloadSchema }),
        { environment_id: environmentId, kind: "shell", request_id: creationRequestId }
      );
    },
    async listBillingPlans(options = {}) {
      const page = await request(
        "GET",
        "/v1/comma/billing/plans",
        z.object({ data: z.array(commaBillingPlanSchema) }),
        undefined,
        options.signal
      );
      return page.data;
    },

    getBillingSummary(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/summary`,
        commaBillingSummarySchema,
        undefined,
        options.signal
      );
    },

    createBillingCheckout(workspaceId, planKey) {
      const successUrl = billingReturnUrl("success");
      const cancelUrl = billingReturnUrl("cancel");
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/checkout`,
        commaBillingSessionSchema,
        {
          plan_key: planKey,
          success_url: successUrl,
          cancel_url: cancelUrl,
          client_request_id: crypto.randomUUID(),
        }
      );
    },

    createBillingPortal(workspaceId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/portal`,
        commaBillingSessionSchema,
        {
          return_url: billingReturnUrl("portal"),
          client_request_id: crypto.randomUUID(),
        }
      );
    },

    previewBillingSubscriptionChange(workspaceId, planKey) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/subscription/preview`,
        commaBillingChangePreviewSchema,
        { plan_key: planKey, client_request_id: crypto.randomUUID() }
      );
    },
    changeBillingSubscription(workspaceId, planKey, preview, changeRequestId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/subscription/change`,
        commaBillingChangeSchema,
        {
          plan_key: planKey,
          current_price_id: preview.current_price_id,
          proration_date: preview.proration_date,
          period_end: preview.period_end,
          success_url: billingReturnUrl("subscription"),
          client_request_id: changeRequestId,
        }
      );
    },
    cancelBillingSubscriptionRenewal(workspaceId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/subscription/cancel`,
        commaBillingChangeSchema,
        { client_request_id: crypto.randomUUID() }
      );
    },

    redeemBillingCode(workspaceId, code) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/redeem`,
        commaRedemptionResultSchema,
        { code, client_request_id: crypto.randomUUID() }
      );
    },

    getProfile(options = {}) {
      return request(
        "GET",
        "/v1/comma/me/profile",
        commaUserProfileSchema,
        undefined,
        options.signal
      );
    },

    updateProfile(attrs, options = {}) {
      return request(
        "PATCH",
        "/v1/comma/me/profile",
        commaUserProfileSchema,
        attrs,
        options.signal
      );
    },

    async uploadAvatar(file, options = {}) {
      const form = new FormData();
      form.append("avatar", file);
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      const combinedSignal = combineSignals(
        options.signal,
        config.sessionTransport?.signal
      );
      const response = await fetchImpl(joinUrl(baseUrl, "/v1/comma/me/avatar"), {
        body: form,
        credentials: config.sessionTransport?.credentials ?? "include",
        headers,
        method: "PUT",
        ...(combinedSignal ? { signal: combinedSignal } : {}),
      });
      if (!response.ok) throw await responseError(response);
      return commaUserProfileSchema.parse(await response.json());
    },

    deleteAvatar(options = {}) {
      return request(
        "DELETE",
        "/v1/comma/me/avatar",
        commaUserProfileSchema,
        undefined,
        options.signal
      );
    },

    async fetchAvatar(avatarRevision, options = {}) {
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      const combinedSignal = combineSignals(
        options.signal,
        config.sessionTransport?.signal
      );
      const response = await fetchImpl(
        joinUrl(baseUrl, `/v1/comma/me/avatar/${encodeURIComponent(avatarRevision)}`),
        {
          credentials: config.sessionTransport?.credentials ?? "include",
          headers,
          method: "GET",
          ...(combinedSignal ? { signal: combinedSignal } : {}),
        }
      );
      if (!response.ok) throw await responseError(response);
      return response.blob();
    },

    listSubscriptionAccounts(workspaceId, after = "", options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts?after=${encodeURIComponent(after)}`,
        subscriptionPageSchema,
        undefined,
        options.signal
      );
    },
    createSubscriptionAccount(workspaceId, input) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts`,
        subscriptionAccountSchema,
        input,
        undefined
      );
    },
    updateSubscriptionAccount(workspaceId, id, input) {
      return request(
        "PATCH",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/${encodeURIComponent(id)}`,
        subscriptionAccountSchema,
        input,
        undefined
      );
    },
    deleteSubscriptionAccount(workspaceId, id, version) {
      return request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/${encodeURIComponent(id)}`,
        deletedModelSchema,
        { version },
        undefined
      );
    },
    refreshSubscriptionQuota(workspaceId, id) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/${encodeURIComponent(id)}/quota`,
        subscriptionAccountSchema,
        {},
        undefined
      );
    },
    resetSubscriptionQuota(workspaceId, id, input) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/${encodeURIComponent(id)}/quota/reset`,
        subscriptionResetSchema,
        input,
        undefined
      );
    },
    beginSubscriptionOAuth(workspaceId, input) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/oauth`,
        subscriptionOAuthSchema,
        input,
        undefined
      );
    },
    pollSubscriptionOAuth(workspaceId, id) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/oauth/${encodeURIComponent(id)}`,
        subscriptionOAuthPollSchema,
        { code: "" },
        undefined
      );
    },
    completeSubscriptionOAuth(workspaceId, id, code) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/subscription-accounts/oauth/${encodeURIComponent(id)}`,
        subscriptionAccountSchema,
        { code },
        undefined
      );
    },
    discoverModels(workspaceId, input, options = {}) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-discovery`,
        discoveredModelsSchema,
        input,
        options.signal
      );
    },
    async listModelTemplates(workspaceId, options = {}) {
      const page = await request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-templates`,
        commaPageSchema(modelTemplateSchema),
        undefined,
        options.signal
      );
      return page.data;
    },
    createModelTemplate(workspaceId, input) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-templates`,
        modelTemplateSchema,
        input
      );
    },
    resolveSubscriptionModel(workspaceId, input) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-templates/resolve-subscription`,
        modelTemplateSchema,
        input
      );
    },
    updateModelTemplate(workspaceId, id, input) {
      return request(
        "PATCH",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-templates/${encodeURIComponent(id)}`,
        modelTemplateSchema,
        input
      );
    },
    deleteModelTemplate(workspaceId, id) {
      return request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/model-templates/${encodeURIComponent(id)}`,
        deletedModelSchema
      );
    },
    getAgentModels(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/agent-models`,
        agentModelsSchema,
        undefined,
        options.signal
      );
    },
    setAgentModel(workspaceId, role, templateId) {
      return request(
        "PUT",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/agent-models/${encodeURIComponent(role)}`,
        agentModelSchema,
        { template_id: templateId }
      );
    },
    getWorkerModels(workspaceId, cursor) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/agent-models/workers?cursor=${encodeURIComponent(cursor)}`,
        workerModelsSchema
      );
    },
    setWorkerDefault(workspaceId, templateId) {
      return request(
        "PUT",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/agent-models/worker-default`,
        z.object({ template_id: z.string().nullable() }),
        { template_id: templateId }
      );
    },
    renameDevice(workspaceId, deviceId, name, options = {}) {
      return request(
        "PUT",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/devices/${encodeURIComponent(deviceId)}`,
        commaDeviceSchema,
        { name },
        options.signal
      );
    },
    removeDevice(workspaceId, deviceId, options = {}) {
      return request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/devices/${encodeURIComponent(deviceId)}`,
        z.object({ removed: z.boolean() }),
        undefined,
        options.signal
      );
    },
    listDevices(workspaceId, options = {}) {
      const query = new URLSearchParams({ limit: "20" });
      if (options.cursor) query.set("cursor", options.cursor);
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/devices?${query}`,
        commaDevicePageSchema,
        undefined,
        options.signal
      );
    },

    setDeviceAccess(workspaceId, deviceId, allow, options = {}) {
      return request(
        "PUT",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/devices/${encodeURIComponent(deviceId)}/access`,
        z.object({ allows_operations: z.boolean() }),
        { allow_operations: allow },
        options.signal
      );
    },

    getDevice(workspaceId, deviceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/devices/${encodeURIComponent(deviceId)}`,
        commaDeviceSchema,
        undefined,
        options.signal
      );
    },

    async listWorkspaces(options = {}) {
      const page = await request(
        "GET",
        "/v1/comma/workspaces",
        commaPageSchema(commaWorkspaceSchema),
        undefined,
        options.signal
      );
      return page.data;
    },

    bootstrapWorkspace(options = {}) {
      return request(
        "POST",
        "/v1/comma/me/bootstrap",
        commaWorkspaceBootstrapSchema,
        {},
        options.signal
      );
    },

    getWeChatIntegration(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/wechat`,
        commaWeChatIntegrationStateSchema,
        undefined,
        options.signal
      );
    },
    startWeChatConnect(workspaceId, options = {}) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/wechat/connect`,
        commaWeChatConnectionSchema,
        {},
        options.signal
      );
    },
    pollWeChatConnect(workspaceId, attemptId, verifyCode, options = {}) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/wechat/connect/poll`,
        commaWeChatConnectionSchema,
        { attempt_id: attemptId, ...(verifyCode ? { verify_code: verifyCode } : {}) },
        options.signal
      );
    },
    async cancelWeChatConnect(workspaceId, attemptId, options = {}) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/wechat/connect`,
        z.object({ cancelled: z.boolean() }),
        { attempt_id: attemptId },
        options.signal
      );
    },
    async disconnectWeChat(workspaceId, options = {}) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/wechat`,
        z.object({ disconnected: z.boolean() }),
        undefined,
        options.signal
      );
    },

    getIMessageIntegration(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/imessage`,
        commaIMessageIntegrationStateSchema,
        undefined,
        options.signal
      );
    },
    startIMessageConnect(workspaceId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/imessage/connect`,
        commaIMessageClaimSchema,
        {}
      );
    },
    async cancelIMessageConnect(workspaceId, code) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/imessage/connect`,
        z.object({ cancelled: z.boolean() }),
        { code }
      );
    },
    async disconnectIMessage(workspaceId) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/imessage`,
        z.object({ disconnected: z.boolean() })
      );
    },

    getTelegramIntegration(workspaceId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/telegram`,
        commaTelegramIntegrationStateSchema,
        undefined,
        options.signal
      );
    },

    getSynchronicityStatus(options = {}) {
      return request(
        "GET",
        "/v1/comma/me/synchronicity/status",
        commaSynchronicityStatusSchema,
        undefined,
        options.signal
      );
    },

    startTelegramConnect(workspaceId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/telegram/connect`,
        commaTelegramConnectAttemptSchema,
        { environment: getActiveCommaConfig().channel }
      );
    },

    async cancelTelegramConnect(workspaceId, attempt) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/telegram/connect`,
        z.object({ cancelled: z.boolean() }),
        attempt
      );
    },

    async disconnectTelegram(workspaceId) {
      const result = await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/telegram`,
        commaTelegramDisconnectSchema,
        {}
      );
      return result.disconnected;
    },

    enrollSynchronicityDevice(attrs, options = {}) {
      return request(
        "PUT",
        "/v1/comma/me/synchronicity/devices/current",
        commaSynchronicityDeviceSchema,
        { label: attrs.label, nk: attrs.nk },
        options.signal
      );
    },

    createConnectorToken(workspaceId, attrs = {}, options = {}) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/connector-token`,
        commaConnectorTokenSchema,
        compact({
          name: attrs.name,
          alias: attrs.alias,
          expires_in_seconds: attrs.expiresInSeconds,
          scope: attrs.scope,
          stable_device_id: attrs.stableDeviceId,
          installation: attrs.installation,
        }),
        options.signal
      );
    },

    async revokeConnectorToken(workspaceId, attrs, options = {}) {
      await request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/connector-token`,
        commaConnectorTokenRevocationSchema,
        { token: attrs.token },
        options.signal
      );
    },

    listRouterApiKeys(workspaceId, options = {}) {
      return request(
        "GET",
        routerApiKeysPath(workspaceId),
        z.array(commaRouterApiKeySchema),
        undefined,
        options.signal
      );
    },

    createRouterApiKey(workspaceId, attrs, options = {}) {
      return request(
        "POST",
        routerApiKeysPath(workspaceId),
        commaRouterApiKeyCreatedSchema,
        compact({ name: attrs.name, expires_at: attrs.expiresAt }),
        options.signal
      );
    },

    updateRouterApiKey(workspaceId, keyId, attrs, options = {}) {
      const body = compact({ name: attrs.name, status: attrs.status });
      // `null` clears the expiry and must survive `compact`, which only drops
      // undefined and empty strings.
      if (attrs.expiresAt !== undefined) body.expires_at = attrs.expiresAt;
      return request(
        "PATCH",
        `${routerApiKeysPath(workspaceId)}/${encodeURIComponent(keyId)}`,
        commaRouterApiKeySchema,
        body,
        options.signal
      );
    },

    async deleteRouterApiKey(workspaceId, keyId, options = {}) {
      await request(
        "DELETE",
        `${routerApiKeysPath(workspaceId)}/${encodeURIComponent(keyId)}`,
        commaRouterApiKeyDeletionSchema,
        undefined,
        options.signal
      );
    },

    listVoiceApiKeys(workspaceId, options = {}) {
      return request(
        "GET",
        voiceApiKeysPath(workspaceId),
        z.array(commaVoiceApiKeySchema),
        undefined,
        options.signal
      );
    },

    createVoiceApiKey(workspaceId, attrs, options = {}) {
      return request(
        "POST",
        voiceApiKeysPath(workspaceId),
        commaVoiceApiKeyCreatedSchema,
        compact({ name: attrs.name, expires_at: attrs.expiresAt }),
        options.signal
      );
    },

    updateVoiceApiKey(workspaceId, keyId, attrs, options = {}) {
      const body = compact({ name: attrs.name, status: attrs.status });
      if (attrs.expiresAt !== undefined) body.expires_at = attrs.expiresAt;
      return request(
        "PATCH",
        `${voiceApiKeysPath(workspaceId)}/${encodeURIComponent(keyId)}`,
        commaVoiceApiKeySchema,
        body,
        options.signal
      );
    },

    async deleteVoiceApiKey(workspaceId, keyId, options = {}) {
      await request(
        "DELETE",
        `${voiceApiKeysPath(workspaceId)}/${encodeURIComponent(keyId)}`,
        commaRouterApiKeyDeletionSchema,
        undefined,
        options.signal
      );
    },

    getVoiceIntegration(workspaceId, options = {}) {
      return request(
        "GET",
        voiceIntegrationPath(workspaceId),
        commaVoiceIntegrationSchema,
        undefined,
        options.signal
      );
    },

    startVoiceNumberVerification(workspaceId, attrs, options = {}) {
      return request(
        "POST",
        `${voiceIntegrationPath(workspaceId)}/numbers/verify-start`,
        commaVoiceVerificationSchema,
        compact({ e164: attrs.e164, line: attrs.line }),
        options.signal
      );
    },

    checkVoiceNumberVerification(workspaceId, attrs, options = {}) {
      return request(
        "POST",
        `${voiceIntegrationPath(workspaceId)}/numbers/verify-check`,
        commaVoiceIntegrationSchema,
        compact({ e164: attrs.e164, code: attrs.code, line: attrs.line }),
        options.signal
      );
    },

    removeVoiceNumber(workspaceId, e164, options = {}) {
      return request(
        "DELETE",
        `${voiceIntegrationPath(workspaceId)}/numbers/${encodeURIComponent(e164)}`,
        commaVoiceIntegrationSchema,
        undefined,
        options.signal
      );
    },

    setVoiceNumberPin(workspaceId, attrs, options = {}) {
      return request(
        "PUT",
        `${voiceIntegrationPath(workspaceId)}/pin`,
        commaVoiceIntegrationSchema,
        { e164: attrs.e164, pin: attrs.pin },
        options.signal
      );
    },

    getSignalIntegration(workspaceId, options = {}) {
      return request(
        "GET",
        signalIntegrationPath(workspaceId),
        commaSignalIntegrationSchema,
        undefined,
        options.signal
      );
    },

    startSignalClaim(workspaceId, options = {}) {
      return request(
        "POST",
        `${signalIntegrationPath(workspaceId)}/claims`,
        commaSignalIntegrationSchema,
        {},
        options.signal
      );
    },

    cancelSignalClaim(workspaceId, claimId, options = {}) {
      return request(
        "DELETE",
        `${signalIntegrationPath(workspaceId)}/claims/${encodeURIComponent(claimId)}`,
        commaSignalIntegrationSchema,
        undefined,
        options.signal
      );
    },

    removeSignalBinding(workspaceId, bindingId, options = {}) {
      return request(
        "DELETE",
        `${signalIntegrationPath(workspaceId)}/bindings/${encodeURIComponent(bindingId)}`,
        commaSignalIntegrationSchema,
        undefined,
        options.signal
      );
    },

    getSignalNumber(workspaceId, options = {}) {
      return request(
        "GET",
        `${signalIntegrationPath(workspaceId)}/number`,
        commaSignalNumberSchema,
        undefined,
        options.signal
      );
    },

    setSignalNumber(workspaceId, number, options = {}) {
      return request(
        "PUT",
        `${signalIntegrationPath(workspaceId)}/number`,
        commaSignalNumberSchema,
        { number },
        options.signal
      );
    },

    setTaskArchived(groupId, conversationId, action, version) {
      return request(
        "POST",
        `${conversationPath(groupId, conversationId)}/${action}`,
        commaConversationSchema,
        { expected_updated_at: version }
      );
    },
    async getTaskShare(groupId, conversationId, options = {}) {
      try {
        return await request(
          "GET",
          `${conversationPath(groupId, conversationId)}/share`,
          commaTaskShareSchema,
          undefined,
          options.signal
        );
      } catch (error) {
        if (error instanceof CommaApiError && error.status === 404) return undefined;
        throw error;
      }
    },
    publishTaskShare(groupId, conversationId) {
      return request(
        "PUT",
        `${conversationPath(groupId, conversationId)}/share`,
        commaTaskShareSchema
      );
    },
    resetTaskShare(groupId, conversationId) {
      return request(
        "POST",
        `${conversationPath(groupId, conversationId)}/share/reset`,
        commaTaskShareSchema
      );
    },
    async revokeTaskShare(groupId, conversationId) {
      await request(
        "DELETE",
        `${conversationPath(groupId, conversationId)}/share`,
        z.object({ revoked: z.literal(true) })
      );
    },
    async listTaskShares(groupId, opts = {}) {
      const page = await request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/task-shares${queryString({
          cursor: opts.cursor,
          limit: opts.limit,
        })}`,
        commaTaskSharePageSchema,
        undefined,
        opts.signal
      );
      return {
        data: page.data,
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
    },
    async getTaskSummaries(groupId, ids) {
      return (
        await request(
          "GET",
          `/v1/comma/groups/${encodeURIComponent(groupId)}/task-summaries${queryString({ ids: ids.join(",") })}`,
          z.object({ data: z.array(commaConversationSchema) })
        )
      ).data;
    },
    async listConversations(groupId) {
      return (await this.listConversationPage(groupId)).data;
    },

    async searchTasks(groupId, query, opts = {}) {
      const result = await request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/search${queryString(
          {
            limit: opts.limit,
            q: query,
          }
        )}`,
        z.object({ data: z.array(commaTaskSearchResultSchema) }),
        undefined,
        opts.signal
      );
      return result.data;
    },

    renameTask(groupId, conversationId, title) {
      return request(
        "PATCH",
        conversationPath(groupId, conversationId),
        commaConversationSchema,
        { title }
      );
    },

    setTaskLabels(groupId, conversationId, labelIds) {
      return request(
        "PATCH",
        conversationPath(groupId, conversationId),
        commaConversationSchema,
        { labels: [...labelIds] }
      );
    },

    listTaskLabels(groupId, options = {}) {
      return request(
        "GET",
        taskLabelsPath(groupId),
        commaTaskLabelCatalogSchema,
        undefined,
        options.signal
      );
    },

    createTaskLabel(groupId, attrs) {
      return request("POST", taskLabelsPath(groupId), commaTaskLabelCatalogSchema, {
        name: attrs.name,
        ...(attrs.color !== undefined ? { color: attrs.color } : {}),
        ...(attrs.description !== undefined ? { description: attrs.description } : {}),
      });
    },

    updateTaskLabel(groupId, labelId, attrs) {
      return request(
        "PATCH",
        `${taskLabelsPath(groupId)}/${encodeURIComponent(labelId)}`,
        commaTaskLabelCatalogSchema,
        {
          ...(attrs.name !== undefined ? { name: attrs.name } : {}),
          ...(attrs.color !== undefined ? { color: attrs.color } : {}),
          ...(attrs.description !== undefined
            ? { description: attrs.description }
            : {}),
        }
      );
    },

    deleteTaskLabel(groupId, labelId) {
      return request(
        "DELETE",
        `${taskLabelsPath(groupId)}/${encodeURIComponent(labelId)}`,
        commaTaskLabelCatalogSchema
      );
    },

    resolveTaskLabelProposal(groupId, proposalId, decision, options) {
      return request(
        "POST",
        `${taskLabelsPath(groupId)}/proposals/${encodeURIComponent(proposalId)}/resolve`,
        commaTaskLabelCatalogSchema,
        {
          decision,
          ...(decision === "approve" && options?.autoApprove
            ? { auto_approve: true }
            : {}),
        }
      );
    },

    setTaskLabelApprovalPolicy(groupId, policy) {
      return request(
        "PATCH",
        `${taskLabelsPath(groupId)}/policy`,
        commaTaskLabelCatalogSchema,
        { approval_policy: policy }
      );
    },

    getTaskOrder(groupId) {
      return request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/task-order`,
        commaTaskOrderSchema
      );
    },

    putTaskOrder(groupId, bucket, ids) {
      return request(
        "PUT",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/task-order/${encodeURIComponent(bucket)}`,
        commaTaskOrderSchema,
        { ids }
      );
    },

    async listConversationPage(groupId, opts = {}) {
      const cacheKey = conversationPageCacheKey(groupId, opts);
      const cached = conversationListCache.get(cacheKey);
      const page = await this.pollConversations(groupId, {
        ...(opts.archive ? { archive: opts.archive } : {}),
        ...(opts.cursor ? { cursor: opts.cursor } : {}),
        ...(cached?.etag ? { etag: cached.etag } : {}),
        ...(opts.limit ? { limit: opts.limit } : {}),
        ...(opts.signal ? { signal: opts.signal } : {}),
      });

      if (page.data) {
        const next = {
          data: page.data,
          hasMore: page.hasMore === true,
          ...(page.etag ? { etag: page.etag } : {}),
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
        };
        conversationListCache.set(cacheKey, next);
        return {
          data: next.data,
          hasMore: next.hasMore,
          ...(next.nextCursor ? { nextCursor: next.nextCursor } : {}),
        };
      }

      return {
        data: cached?.data ?? [],
        hasMore: cached?.hasMore === true,
        ...(cached?.nextCursor ? { nextCursor: cached.nextCursor } : {}),
      };
    },

    async pollConversations(groupId, opts = {}) {
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      if (opts.etag) {
        headers["if-none-match"] = opts.etag;
      }

      const query = queryString({
        archive: opts.archive,
        cursor: opts.cursor,
        limit: opts.limit,
      });
      const init: RequestInit = {
        credentials: config.sessionTransport?.credentials ?? "include",
        headers,
        method: "GET",
      };
      const combinedSignal = combineSignals(
        opts.signal,
        config.sessionTransport?.signal
      );
      if (combinedSignal) {
        init.signal = combinedSignal;
      }

      const response = await fetchImpl(
        joinUrl(
          baseUrl,
          `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations${query}`
        ),
        init
      );
      const etag = response.headers.get("etag") ?? opts.etag;

      if (response.status === 304) {
        return { ...(etag ? { etag } : {}), notModified: true };
      }

      if (!response.ok) {
        throw await responseError(response);
      }

      const page = commaPageSchema(commaConversationSchema).parse(
        await response.json()
      );

      return {
        data: page.data,
        ...(etag ? { etag } : {}),
        hasMore: page.has_more === true,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
        notModified: false,
      };
    },

    enterMeetingTask(groupId, entry) {
      return request(
        "POST",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/meeting-tasks`,
        meetingTaskReceiptSchema,
        entry,
        AbortSignal.timeout(30_000)
      );
    },
    updateMeetingTask(groupId, occurrenceId, command) {
      return request(
        "POST",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/meeting-tasks/${encodeURIComponent(occurrenceId)}`,
        meetingTaskReceiptSchema,
        command,
        AbortSignal.timeout(30_000)
      );
    },

    ensureGroupChat(groupId, options = {}) {
      return request(
        "POST",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/assistant-chat`,
        commaConversationSchema,
        {},
        options.signal
      );
    },

    getConversation(groupId, conversationId, options = {}) {
      const path = conversationPath(groupId, conversationId);
      return request(
        "GET",
        options.messageLimit === undefined
          ? path
          : `${path}?message_limit=${encodeURIComponent(options.messageLimit)}`,
        commaConversationSchema,
        undefined,
        options.signal
      );
    },

    getConversationPreview(groupId, conversationId, options = {}) {
      const path = `${conversationPath(groupId, conversationId)}/preview`;
      return request(
        "GET",
        options.includeWorker ? `${path}?include_worker=true` : path,
        commaConversationPreviewSchema,
        undefined,
        options.signal
      );
    },

    acceptTaskReview(groupId, conversationId, reviewVersion) {
      return request(
        "POST",
        `${conversationPath(groupId, conversationId)}/accept`,
        commaConversationSchema,
        { review_version: reviewVersion }
      );
    },

    async pollConversation(groupId, conversationId, opts = {}) {
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      if (opts.etag) {
        headers["if-none-match"] = opts.etag;
      }

      const init: RequestInit = {
        credentials: config.sessionTransport?.credentials ?? "include",
        headers,
        method: "GET",
      };
      const combinedSignal = combineSignals(
        opts.signal,
        config.sessionTransport?.signal
      );
      if (combinedSignal) {
        init.signal = combinedSignal;
      }

      const response = await fetchImpl(
        joinUrl(baseUrl, conversationPath(groupId, conversationId)),
        init
      );
      const etag = response.headers.get("etag") ?? opts.etag;

      if (response.status === 304) {
        return {
          ...(etag ? { etag } : {}),
          notModified: true,
        };
      }

      if (!response.ok) {
        throw await responseError(response);
      }

      return {
        conversation: commaConversationSchema.parse(await response.json()),
        ...(etag ? { etag } : {}),
        notModified: false,
      };
    },

    async listWorkspaceSkills(workspaceId) {
      const page = await request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/skills`,
        commaPageSchema(commaSkillSchema)
      );
      return page.data;
    },

    async getWorkspaceSkill(workspaceId, skillId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillId)}`,
        commaSkillDetailSchema,
        undefined,
        options.signal
      );
    },

    async getWorkspaceSkillFile(workspaceId, skillId, path, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillId)}/file?path=${encodeURIComponent(path)}`,
        commaSkillFileSchema,
        undefined,
        options.signal
      );
    },

    async listWorkspacePlugins(workspaceId, options = {}) {
      const page = await request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins`,
        commaPageSchema(commaPluginSchema),
        undefined,
        options.signal
      );
      return page.data;
    },

    async installWorkspacePlugin(workspaceId, pluginId, options = {}) {
      const path = `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}`;
      const response = await request(
        "POST",
        `${path}/install`,
        z.union([commaPluginInstallResultSchema, commaPluginSchema]),
        {
          contract: "unified_v1",
          ...(options.authorizationState
            ? { authorization_state: options.authorizationState }
            : {}),
          ...(options.verifyOnly ? { verify_only: true } : {}),
        },
        options.signal
      );

      if ("plugin" in response) {
        return response;
      }

      // Rolling-upgrade fallback: an older CommaWeb ignores the contract marker
      // and returns the legacy plain plugin. Finish its former Connect step
      // internally so the product still exposes one Install operation.
      try {
        const authorization = await request(
          "POST",
          `${path}/authorize`,
          commaPluginAuthorizationSchema,
          {},
          options.signal
        );

        if (options.verifyOnly) {
          // Old CommaWeb cannot verify an exact attempt: /authorize always starts
          // another provider flow. Treat that replacement URL as cancellation
          // and roll back the legacy enablement instead of reopening it.
          const plugin = await request("DELETE", path, commaPluginSchema);
          return { plugin, authorization: null };
        }

        return {
          plugin: { ...response, installed: false },
          authorization,
        };
      } catch (error) {
        if (
          error instanceof CommaApiError &&
          error.status === 400 &&
          (error.message === "this plugin has no connectable data source" ||
            error.message === "all plugin data sources are already connected")
        ) {
          return { plugin: response, authorization: null };
        }

        await request("DELETE", path, commaPluginSchema).catch(() => undefined);
        throw error;
      }
    },

    uninstallWorkspacePlugin(workspaceId, pluginId) {
      return request(
        "DELETE",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}`,
        commaPluginSchema
      );
    },

    getPluginPersonalSources(workspaceId, pluginId, options = {}) {
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}/personal-sources`,
        commaPluginPersonalSourcesSchema,
        undefined,
        options.signal
      );
    },

    preparePluginAccountConfirmation(
      workspaceId,
      pluginId,
      toolkit,
      connectionId,
      options = {}
    ) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}/personal-sources/prepare`,
        commaPluginAccountConfirmationSchema,
        { toolkit, connection_id: connectionId },
        options.signal
      );
    },

    confirmPluginAccount(workspaceId, pluginId, state, options = {}) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}/personal-sources/confirm`,
        commaPluginConfirmedAccountSchema,
        { state },
        options.signal
      );
    },

    reauthorizeWorkspacePlugin(workspaceId, pluginId, options) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}/reauthorize`,
        commaPluginInstallResultSchema,
        {
          ...(options.connectionId ? { connection_id: options.connectionId } : {}),
          ...(options.authorizationState
            ? { authorization_state: options.authorizationState }
            : {}),
          ...(options.verifyOnly ? { verify_only: true } : {}),
        },
        options.signal
      );
    },

    async cancelPluginOperation(workspaceId, pluginId, state) {
      await request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/plugins/${encodeURIComponent(pluginId)}/personal-sources/cancel`,
        z.object({ cancelled: z.literal(true) }),
        { state }
      );
    },

    getRecommendations(workspaceId, options = {}) {
      const params = new URLSearchParams();
      const timezone = options.timezone?.trim();
      const locale = options.locale?.trim();
      if (timezone) params.set("timezone", timezone);
      // The briefing is model-generated, so the renderer needs the UI language
      // the same way it needs the timezone; the server stores it for the daily
      // scheduled run, which has no client to ask.
      if (locale) params.set("locale", locale);
      const query = params.size > 0 ? `?${params.toString()}` : "";
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/recommendations${query}`,
        commaRecommendationEnvelopeSchema,
        undefined,
        options.signal
      );
    },

    updateRecommendationSettings(workspaceId, settings) {
      return request(
        "PATCH",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/recommendations/settings`,
        commaRecommendationEnvelopeSchema,
        settings as unknown as Record<string, JsonValue>
      );
    },

    getProactiveSettings(groupId, options = {}) {
      return request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/proactive`,
        proactiveSettingsSchema,
        undefined,
        options.signal
      );
    },

    updateProactiveSettings(groupId, settings) {
      return request(
        "PUT",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/proactive`,
        proactiveSettingsSchema,
        { enabled: settings.enabled, request_id: settings.requestId }
      );
    },

    refreshRecommendations(workspaceId) {
      return request(
        "POST",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/recommendations/refresh`,
        commaRecommendationRefreshSchema,
        {}
      );
    },

    getRecommendationLinkPreview(workspaceId, link, options = {}) {
      const params = new URLSearchParams({ href: link.href });
      if (link.sourceId) params.set("sourceId", link.sourceId);
      return request(
        "GET",
        `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/recommendations/link-preview?${params.toString()}`,
        commaRecommendationLinkPreviewSchema,
        undefined,
        options.signal
      );
    },

    async uploadGroupFile(groupId, attrs) {
      const form = new FormData();
      form.append("file", attrs.data, attrs.name);
      const init: RequestInit = {
        credentials: config.sessionTransport?.credentials ?? "include",
        method: "POST",
        headers: requestHeaders(config.token, undefined, config.sessionTransport),
        body: form,
      };

      const combinedSignal = combineSignals(
        attrs.signal,
        config.sessionTransport?.signal
      );
      if (combinedSignal) {
        init.signal = combinedSignal;
      }

      const response = await fetchImpl(
        joinUrl(baseUrl, `/v1/comma/groups/${encodeURIComponent(groupId)}/files`),
        init
      );

      if (!response.ok) {
        throw await responseError(response);
      }

      return commaGroupFileSchema.parse(await response.json());
    },

    /**
     * An attachment is addressed by the message it arrived on, so this asks for
     * exactly the bytes the sender attached — never for a workspace path.
     */
    async fetchConversationAttachment(
      groupId,
      conversationId,
      messageId,
      attachmentIndex,
      options = {}
    ) {
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      const combinedSignal = combineSignals(
        options.signal,
        config.sessionTransport?.signal
      );
      const response = await fetchImpl(
        joinUrl(
          baseUrl,
          `/v1/comma/groups/${encodeURIComponent(groupId)}` +
            `/conversations/${encodeURIComponent(conversationId)}` +
            `/messages/${encodeURIComponent(messageId)}` +
            `/attachments/${encodeURIComponent(String(attachmentIndex))}`
        ),
        {
          credentials: config.sessionTransport?.credentials ?? "include",
          headers,
          method: "GET",
          ...(combinedSignal ? { signal: combinedSignal } : {}),
        }
      );
      if (!response.ok) throw await responseError(response);
      return response.blob();
    },

    async fetchGroupFile(groupId, path, options = {}) {
      const headers = requestHeaders(config.token, undefined, config.sessionTransport);
      const combinedSignal = combineSignals(
        options.signal,
        config.sessionTransport?.signal
      );
      const query = new URLSearchParams({ path }).toString();
      const response = await fetchImpl(
        joinUrl(
          baseUrl,
          `/v1/comma/groups/${encodeURIComponent(groupId)}/files?${query}`
        ),
        {
          credentials: config.sessionTransport?.credentials ?? "include",
          headers,
          method: "GET",
          ...(combinedSignal ? { signal: combinedSignal } : {}),
        }
      );
      if (!response.ok) throw await responseError(response);
      return response.blob();
    },

    async fetchAgentBlob(groupId, agentId, ref, options = {}) {
      const headers = requestHeaders(config.token, { ref }, config.sessionTransport);
      const combinedSignal = combineSignals(
        options.signal,
        config.sessionTransport?.signal
      );
      const response = await fetchImpl(
        joinUrl(
          baseUrl,
          `/v1/comma/groups/${encodeURIComponent(groupId)}/agents/${encodeURIComponent(agentId)}/resources`
        ),
        {
          body: JSON.stringify({ ref }),
          credentials: config.sessionTransport?.credentials ?? "include",
          headers,
          method: "POST",
          ...(combinedSignal ? { signal: combinedSignal } : {}),
        }
      );
      if (!response.ok) throw await responseError(response);
      return response.blob();
    },

    async listMessages(groupId, conversationId) {
      const page = await request(
        "GET",
        `${conversationPath(groupId, conversationId)}/messages`,
        commaPageSchema(salixMessageSchema)
      );
      return page.data;
    },

    async getMessageContext(groupId, conversationId, messageId, options = {}) {
      const page = await request(
        "GET",
        `${conversationPath(groupId, conversationId)}/messages/${encodeURIComponent(messageId)}/context`,
        commaPageSchema(salixMessageSchema),
        undefined,
        options.signal
      );
      return page.data;
    },

    async generateChatSuggestions(groupId, conversationId, options = {}) {
      const params = new URLSearchParams();
      const locale = options.locale?.trim();
      // The generator uses the conversation language and keeps the UI locale as a
      // fallback when the conversation does not establish a language.
      if (locale) params.set("locale", locale);
      const query = params.size > 0 ? `?${params.toString()}` : "";
      const page = await request(
        "POST",
        `${conversationPath(groupId, conversationId)}/suggestions${query}`,
        commaPageSchema(commaChatSuggestionSchema),
        {},
        options.signal
      );
      return page.data;
    },

    sendMessage(groupId, conversationId, attrs) {
      const message = attrs.localFiles?.length
        ? {
            content: [
              ...(attrs.text ? [{ type: "text" as const, text: attrs.text }] : []),
              ...attrs.localFiles.map((file) => ({
                type: "local_file" as const,
                local_file_ref: file.localFileRef,
                display_name: file.displayName,
                media_type: file.mediaType,
                size: file.size,
              })),
            ],
          }
        : { type: "text" as const, text: attrs.text };
      return request(
        "POST",
        `${conversationPath(groupId, conversationId)}/messages`,
        commaConversationSchema,
        {
          message,
          client_request_id: attrs.clientRequestId ?? requestId(),
          ...(attrs.replyToMessageId
            ? { reply_to_message_id: attrs.replyToMessageId }
            : {}),
          ...(attrs.clientDeviceId ? { client_device_id: attrs.clientDeviceId } : {}),
          ...(attrs.skills?.length ? { skills: attrs.skills } : {}),
        }
      );
    },

    clearBrowserStorage(workspaceId) {
      return request(
        "POST",
        browserPath(workspaceId) + "/clear-storage",
        z.object({ cleared: z.boolean() }),
        {}
      );
    },
    listBrowsers(workspaceId, target, signal) {
      return request(
        "GET",
        browserPath(workspaceId) +
          "?" +
          new URLSearchParams({
            conversation_id: target.conversationId,
            participant_id: target.participantId,
          }),
        z.object({ browsers: z.array(browserBindingSchema).max(50) }),
        undefined,
        signal
      );
    },
    browserCommand(workspaceId, browser, viewerId, operation, args = {}) {
      return request("POST", browserPath(workspaceId, browser), browserResultSchema, {
        viewer_id: viewerId,
        operation,
        args,
      });
    },
    streamBrowser(workspaceId, browser, tabId, viewerId, signal, onEvent) {
      return streamSse(
        fetchImpl,
        config.token,
        {
          url: joinUrl(
            baseUrl,
            browserPath(workspaceId, browser) +
              "/events?" +
              new URLSearchParams({ tab_id: tabId, viewer_id: viewerId })
          ),
          signal,
          ...(config.onUnauthorized ? { onUnauthorized: config.onUnauthorized } : {}),
          ...(config.sessionTransport
            ? { sessionTransport: config.sessionTransport }
            : {}),
        },
        (value) => onEvent(browserEventSchema.parse(value))
      );
    },

    streamConversationEvents(groupId, conversationId, opts) {
      const query = queryString({
        wait: opts.waitMs,
      });
      const streamOpts: StreamConversationOptions = {
        url: joinUrl(
          baseUrl,
          `${conversationPath(groupId, conversationId)}/events${query}`
        ),
        onEvent: opts.onEvent,
      };

      if (opts.signal) {
        streamOpts.signal = opts.signal;
      }
      if (config.onUnauthorized) {
        streamOpts.onUnauthorized = config.onUnauthorized;
      }
      if (config.sessionTransport) {
        streamOpts.sessionTransport = config.sessionTransport;
      }

      return streamConversationEvents(fetchImpl, config.token, streamOpts);
    },

    streamConversationListEvents(groupId, opts) {
      const query = queryString({
        wait: opts.waitMs,
        conversation_id: opts.conversationId,
      });
      const streamOpts: StreamConversationListOptions = {
        ...(opts.onParticipantStatuses
          ? { onParticipantStatuses: opts.onParticipantStatuses }
          : {}),
        url: joinUrl(
          baseUrl,
          `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/events${query}`
        ),
        onEvent: opts.onEvent,
      };

      if (opts.signal) {
        streamOpts.signal = opts.signal;
      }
      if (config.onUnauthorized) {
        streamOpts.onUnauthorized = config.onUnauthorized;
      }
      if (config.sessionTransport) {
        streamOpts.sessionTransport = config.sessionTransport;
      }

      return streamConversationListEvents(fetchImpl, config.token, streamOpts);
    },
  };
}

function billingReturnUrl(status: "cancel" | "portal" | "subscription" | "success") {
  const config = getActiveCommaConfig();
  const params = new URLSearchParams({
    environment: config.channel,
    status,
  });
  return `${config.apiBaseUrl.replace(/\/+$/, "")}/v1/comma/billing/stripe/checkout/return?${params}`;
}

interface StreamConversationOptions {
  url: string;
  signal?: AbortSignal;
  onUnauthorized?: () => void;
  onEvent: (event: CommaConversationEvent, eventName: string) => void;
  sessionTransport?: CommaApiSessionTransport;
}

interface StreamConversationListOptions {
  onParticipantStatuses?: (event: CommaTaskParticipantStatuses) => void;
  url: string;
  signal?: AbortSignal;
  onUnauthorized?: () => void;
  onEvent: (event: CommaConversationListEvent) => void;
  sessionTransport?: CommaApiSessionTransport;
}

async function streamConversationEvents(
  fetchImpl: typeof fetch,
  token: string,
  opts: StreamConversationOptions
) {
  return streamSse(fetchImpl, token, opts, (value, eventName) => {
    opts.onEvent(commaConversationEventSchema.parse(value), eventName);
  });
}

async function streamConversationListEvents(
  fetchImpl: typeof fetch,
  token: string,
  opts: StreamConversationListOptions
) {
  return streamSse(fetchImpl, token, opts, (value, eventName) => {
    if (eventName === "task_participant_statuses") {
      opts.onParticipantStatuses?.(commaTaskParticipantStatusesSchema.parse(value));
      return;
    }
    opts.onEvent(commaConversationListEventSchema.parse(value));
  });
}

async function streamSse(
  fetchImpl: typeof fetch,
  token: string,
  opts: {
    url: string;
    signal?: AbortSignal;
    onUnauthorized?: () => void;
    sessionTransport?: CommaApiSessionTransport;
  },
  onEvent: (value: unknown, eventName: string) => void
) {
  const init: RequestInit = {
    credentials: opts.sessionTransport?.credentials ?? "include",
    headers: requestHeaders(token, undefined, opts.sessionTransport),
  };

  const combinedSignal = combineSignals(opts.signal, opts.sessionTransport?.signal);
  if (combinedSignal) {
    init.signal = combinedSignal;
  }

  const response = await fetchImpl(opts.url, init);

  if (!response.ok) {
    throw await sessionTransportApiError(
      response,
      opts.sessionTransport,
      opts.onUnauthorized
    );
  }

  if (!response.body) {
    throw new CommaApiError(0, "Comma API response did not include a stream body.");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (!opts.signal?.aborted) {
      const { done, value } = await reader.read();

      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });
      buffer = drainSseBuffer(buffer, onEvent);
    }

    buffer += decoder.decode();
    drainSseBuffer(buffer, onEvent);
  } finally {
    reader.releaseLock();
  }
}

function drainSseBuffer(
  buffer: string,
  onEvent: (value: unknown, eventName: string) => void
) {
  let next = buffer;
  let boundary = next.indexOf("\n\n");

  while (boundary !== -1) {
    const raw = next.slice(0, boundary);
    next = next.slice(boundary + 2);
    emitSse(raw, onEvent);
    boundary = next.indexOf("\n\n");
  }

  return next;
}

function emitSse(raw: string, onEvent: (value: unknown, eventName: string) => void) {
  let eventName = "message";
  const data: string[] = [];

  for (const line of raw.split(/\r?\n/)) {
    if (line.startsWith("event:")) {
      eventName = line.slice("event:".length).trim();
    } else if (line.startsWith("data:")) {
      data.push(line.slice("data:".length).trimStart());
    }
  }

  if (data.length === 0) {
    return;
  }

  onEvent(JSON.parse(data.join("\n")), eventName);
}

function conversationPath(groupId: string, conversationId: string) {
  return `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(
    conversationId
  )}`;
}

function taskLabelsPath(groupId: string) {
  return `/v1/comma/groups/${encodeURIComponent(groupId)}/task-labels`;
}

function routerApiKeysPath(workspaceId: string) {
  return `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/router-api-keys`;
}

function voiceApiKeysPath(workspaceId: string) {
  return `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/voice-api-keys`;
}

function voiceIntegrationPath(workspaceId: string) {
  return `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/voice`;
}

function signalIntegrationPath(workspaceId: string) {
  return `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/integrations/signal`;
}

function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
}

function queryString(attrs: Record<string, unknown>) {
  const query = new URLSearchParams();

  for (const [key, value] of Object.entries(attrs)) {
    if (value !== undefined && value !== "") {
      query.set(key, String(value));
    }
  }

  const encoded = query.toString();
  return encoded ? `?${encoded}` : "";
}

function conversationPageCacheKey(
  groupId: string,
  opts: { archive?: string; cursor?: string; limit?: number }
) {
  return `${groupId}\n${opts.archive ?? "exclude"}\n${opts.limit ?? ""}\n${opts.cursor ?? ""}`;
}

function requestHeaders(
  token: string,
  body?: unknown,
  sessionTransport?: CommaApiSessionTransport
) {
  const headers: Record<string, string> = {
    accept: "application/json, text/event-stream",
  };

  const trimmedToken = token.trim();
  if (trimmedToken) {
    headers.authorization = `Bearer ${trimmedToken}`;
  }

  if (body) {
    headers["content-type"] = "application/json";
  }

  sessionTransport?.applyHeaders(headers);
  return headers;
}

function combineSignals(
  requestSignal: AbortSignal | undefined,
  sessionSignal: AbortSignal | undefined
) {
  if (!requestSignal) {
    return sessionSignal;
  }
  if (!sessionSignal || requestSignal === sessionSignal) {
    return requestSignal;
  }
  return AbortSignal.any([requestSignal, sessionSignal]);
}

function compact<T extends Record<string, unknown>>(attrs: T) {
  return Object.fromEntries(
    Object.entries(attrs).filter(([, value]) => value !== undefined && value !== "")
  ) as Record<string, JsonValue>;
}

async function sessionTransportApiError(
  response: Response,
  sessionTransport?: CommaApiSessionTransport,
  onUnauthorized?: () => void
) {
  if (response.status === 401) {
    sessionTransport?.reportSessionRejection(401);
    onUnauthorized?.();
  }

  const value = await readJsonValue(response);
  if (response.status === 409 && isSessionRejectionBody(value)) {
    sessionTransport?.reportSessionRejection(409);
  }
  return apiErrorFromValue(response, value);
}

function apiErrorFromValue(response: Response, value: unknown) {
  const parsed = commaApiErrorBodySchema.safeParse(value);
  const body = parsed.success ? (parsed.data as CommaApiErrorBody) : undefined;
  const message = body?.error || `${response.status} ${response.statusText}`;
  return new CommaApiError(response.status, message, body);
}

async function readJsonValue(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return undefined;
  }
}

function isSessionRejectionBody(value: unknown) {
  return (
    sessionChangedResponseSchema.safeParse(value).success ||
    sessionProductLeaseUnavailableResponseSchema.safeParse(value).success
  );
}

function requestId() {
  if (globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }

  return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
