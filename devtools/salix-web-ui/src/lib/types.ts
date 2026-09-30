export interface Tenant {
  tenant_id: string;
  name: string;
  created_at: number;
  config: string;
}

export type BrowserRenderingProvider = "cloudflare" | "tinyfish";

export interface TenantBrowserRenderingConfig {
  provider?: BrowserRenderingProvider;

  // Cloudflare-specific.
  account_id?: string;
  api_token?: string;
  api_base_url?: string;
  keep_alive_ms?: number;

  // Tinyfish-specific.
  tinyfish_api_key?: string;
  tinyfish_api_base_url?: string;
}

export interface OAuthProviderApp {
  provider: string;
  client_id?: string;
  client_secret_configured: boolean;
}

export interface OAuthBindingDetail {
  binding_id: string;
  group_id: string;
  provider: string;
  alias: string;
  provider_account_id: string;
  provider_account_name: string;
  scopes?: string[];
  expires_at?: number | null;
  status: string;
  metadata?: Record<string, unknown>;
  created_at: number;
}

export interface OAuthAuthorizeResponse {
  authorization_url: string;
  state: string;
}

export interface APIKeyInfo {
  key_hash: string;
  tenant_id: string;
  name: string;
  created_at: number;
  expires_at?: number;
}

export interface APIKeyCreateResponse {
  key: string;
  key_hash: string;
  name: string;
}

export interface ConnectorTokenInfo {
  token_hash: string;
  tenant_id: string;
  agent_id: string;
  group_id: string;
  name: string;
  alias: string;
  created_at: number;
  expires_at: number;
  expired?: boolean;
}

export interface ConnectorTokenCreateResponse extends ConnectorTokenInfo {
  token: string;
  server: string;
  connect_url: string;
  env?: Record<string, string>;
}

export interface AgentTemplate {
  template_id: string;
  name: string;
  model: string;
  provider?: string;
  provider_type?: string;
  provider_config?: Record<string, unknown>; // only in admin responses
  request_headers?: Record<string, string>; // only in admin responses
  image_config?: Record<string, unknown>; // only in admin responses
  video_config?: Record<string, unknown>; // only in admin responses
  vision_describer_config?: Record<string, unknown>; // only in admin responses
  analyze_config?: Record<string, unknown>; // only in admin responses
  supports_images?: boolean | null;
  max_tokens: number;
  context_tokens: number;
  created_at: number;
}

export interface AgentGroup {
  group_id: string;
  tenant_id: string;
  name: string;
  purpose?: string;
  hidden?: boolean;
  router_agent_id?: string;
  created_at: number;
}

export interface IMConnect {
  connect_id: string;
  tenant_id?: string;
  group_id: string;
  provider: string;
  app_name?: string;
  app_id?: string;
  tenant_key?: string;
  client_id?: string;
  workspace_id?: string;
  workspace_name?: string;
  enterprise_id?: string;
  owner_user_id?: string;
  bot_user_id?: string;
  bot_username?: string;
  webhook_url?: string;
  status?: string;
  last_error?: string;
  connected_at?: number;
  oauth_completed_at?: number;
  disabled_at?: number;
  created_at?: number;
  updated_at?: number;
  bot_token_configured?: boolean;
  client_secret_configured?: boolean;
  signing_secret_configured?: boolean;
  app_secret_configured?: boolean;
  verification_token_configured?: boolean;
  encrypt_key_configured?: boolean;
  oauth_url?: string;
}

export interface AgentSprite {
  sprite_name: string;
  status: string;
  error?: string;
  // Most recent transient provisioning failure while still `creating`.
  last_error?: string;
}

export interface RuntimeDebugFields {
  db_namespace?: string;
  tool_router_enabled?: boolean;
  sprites_enabled?: boolean;
}

export interface Agent {
  agent_id: string;
  tenant_id: string;
  group_id?: string;
  name?: string;
  system_prompt?: string;
  template_id?: string;
  provider?: string;
  forked_from?: string;
  status: string;
  node_id?: string;
  created_at: number;
  started_at?: number;
  completed_at?: number;
  error?: string;
  sprite?: AgentSprite;
  runtime_debug?: RuntimeDebugFields;
}

export interface AgentActivity {
  agent_id: string;
  session_id: string;
  conversation_id?: string | null;
  phase: string;
  status: string;
  summary: string;
  sequence: number;
  updated_at: number;
}

export interface StoredMessage {
  message_id: number;
  role: string;
  content: string;
  tool_call_id?: string;
  session_id?: string;
  model?: string;
  input_tokens?: number;
  output_tokens?: number;
  metadata?: Record<string, unknown>;
  compacted_through?: number;
  created_at: number;
}

export interface RuntimeMessage {
  id?: number;
  role: string;
  content: string;
  tool_call_id?: string;
  tool_calls?: unknown[];
}

export interface RuntimeSessionMessages {
  session_id: string;
  status: string;
  last_ack_message_id: number;
  messages: RuntimeMessage[];
  /** Live-window scope: history beyond the window has been archived. */
  archived_through?: number;
  history_truncated?: boolean;
}

export interface NativeIMSessionMessage {
  message_id: string;
  kind?: string;
  role: string;
  content: string;
  metadata?: Record<string, unknown>;
  session_id?: string;
  created_at: number;
}

export interface MessageSearchResult {
  message_id: number;
  role: string;
  session_id?: string;
  created_at: number;
  snippet: string;
  score: number;
}

/** Search envelope: results are live-window scoped; archived history is
 * not searched and the response says so. */
export interface MessageSearchResponse {
  results: MessageSearchResult[];
  scope: string;
  archived_not_searched: boolean;
}

export interface CursorPage<T> {
  data: T[];
  next_cursor?: string;
  has_more: boolean;
}

export interface GroupConversationParticipant {
  participant_id: string;
  conversation_id?: string;
  actor_type: string;
  user_id?: string;
  agent_id?: string;
  agent_name?: string;
  payload?: Record<string, unknown>;
  role_label?: string;
  state?: string;
  notification_filter?: {
    messages: "all" | "mentioned" | "none";
    statuses: "all" | "none" | string[];
  };
  notification_mode?: string;
  created_at?: number;
  updated_at?: number;
}

export interface GroupConversation {
  conversation_id: string;
  kind: string;
  agent_group_id?: string;
  parent_conversation_id?: string;
  title?: string;
  status?: string;
  activity_status?: string;
  last_round_error?: string;
  created_by_agent_id?: string;
  participants?: GroupConversationParticipant[];
  message_count: number;
  target_message_count?: number;
  created_at: number;
  updated_at: number;
  last_message_preview?: unknown;
}

export interface Session {
  session_id: string;
  agent_id: string;
  name: string;
  hidden?: boolean;
  purpose?: string;
  source_session_id?: string;
  source_schedule_id?: string;
  status: string;
  activity_status?: string;
  last_round_error?: string;
  created_at: number;
  last_activity_at?: number;
  completed_at?: number;
}

export interface IMStoredMessage {
  message_id: string;
  kind: string;
  participant_id: string;
  actor_type: string;
  user_id?: string;
  agent_id?: string;
  agent_name?: string;
  session_id?: string;
  role_label?: string;
  content: unknown;
  metadata?: unknown;
  created_at: number;
}

export interface NodeInfo {
  node_id: string;
  address: string;
  started_at: number;
  heartbeat_at: number;
  agent_count: number;
  max_agents: number;
  status: string;
  registry?: NodeRegistryInfo;
}

export interface NodeRegistryInfo {
  status: string;
  running_agents: number;
  max_agents: number;
  timestamp: number;
  last_seen_at: number;
  last_seen_age_ms: number;
  fresh_for_handoff: boolean;
}

export interface ClusterStats {
  active_nodes: number;
  total_nodes: number;
  total_agents: number;
  total_capacity: number;
}

export interface VFSEntry {
  path: string;
  kind: string;
  size: number;
  modified_at: number;
}

export interface SiteInfo {
  name: string;
  url?: string;
}

export interface Environment {
  device_id: string;
  connector_run_id?: string;
  tenant_id: string;
  group_id: string;
  name: string;
  description?: string;
  os: string;
  arch: string;
  node_id: string;
  status: string;
  connected_at: number;
  disconnected_at?: number;
}

export interface StreamDelta {
  content?: string;
  tool_call_index?: number;
  name?: string;
  arguments?: string;
}

export interface StreamToolEvent {
  call_id: string;
  tool_name: string;
  elapsed_ms?: number;
  error?: string;
}

export interface InteractiveLoginRequest {
  login_id: string;
  login_url: string;
  start_url?: string;
  expires_at?: number;
  tool_call_id?: string;
}

/** Options for per-turn LLM overrides when sending a message. */
export interface SendMessageOptions {
  template_id?: string;
  reasoning_effort?: string;
}

/** A content block in a multimodal message. */
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail?: string } };

/** Content can be a plain string or an array of typed content blocks. */
export type MessageContent = string | ContentBlock[];
