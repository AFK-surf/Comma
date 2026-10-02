export type {
  CommaDevice,
  CommaDevicePage,
  CommaApiErrorBody,
  SalixContentBlock,
  SalixBlobRef,
  CommaConnectorToken,
  CommaRouterApiKey,
  CommaRouterApiKeyCreated,
  CommaVoiceApiKey,
  CommaVoiceApiKeyCreated,
  CommaVoiceIntegration,
  CommaVoiceNumber,
  CommaVoiceVerification,
  CommaSignalBinding,
  CommaSignalIntegration,
  CommaSignalNumber,
  CommaConversation,
  CommaConversationPreview,
  CommaTaskSearchResult,
  CommaTaskShare,
  CommaTaskShareEntry,
  CommaTaskOrder,
  CommaTaskLabel,
  CommaTaskLabelCatalog,
  CommaTaskLabelApprovalPolicy,
  CommaTaskLabelColor,
  CommaTaskLabelProposal,
  CommaConversationKind,
  CommaConversationEvent,
  CommaConversationListEvent,
  SalixMessage,
  CommaPage,
  CommaPlugin,
  CommaPluginInstallResult,
  CommaPluginPersonalSources,
  CommaPluginAccountConfirmation,
  CommaPluginConfirmedAccount,
  CommaPluginResource,
  CommaSkill,
  CommaSkillDetail,
  CommaSkillFile,
  CommaWorkspace,
  CommaUserProfile,
  CommaWorkspaceBootstrap,
  CommaTelegramIntegrationState,
  CommaIMessageIntegrationState,
  CommaIMessageClaim,
  CommaWeChatConnection,
  CommaWeChatIntegrationState,
  CommaTelegramConnectAttempt,
  CommaGroupFile,
  JsonValue,
  CommaRecommendationEnvelope,
  CommaRecommendationLinkPreview,
  CommaRecommendationSettings,
  CommaRecommendationSettingsPatch,
  CommaBillingPlan,
  CommaBillingSummary,
  CommaBillingSession,
  CommaBillingChangePreview,
  CommaBillingChange,
  CommaRedemptionResult,
} from "./schemas";

export interface CommaApiConfig {
  baseUrl: string;
  token: string;
  fetch?: typeof fetch;
  onUnauthorized?: () => void;
  sessionTransport?: CommaApiSessionTransport | undefined;
}

export interface CommaApiSessionTransport {
  readonly credentials: RequestCredentials;
  readonly signal: AbortSignal;
  applyHeaders(headers: Record<string, string>): void;
  reportSessionRejection(status: 401 | 409): void;
}
