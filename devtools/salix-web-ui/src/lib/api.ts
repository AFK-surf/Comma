import type {
	Tenant,
	APIKeyInfo,
	APIKeyCreateResponse,
	AgentTemplate,
	AgentGroup,
	Agent,
	AgentActivity,
	IMStoredMessage,
	RuntimeSessionMessages,
	Session,
	MessageSearchResponse,
	NodeInfo,
	ClusterStats,
	VFSEntry,
	SiteInfo,
	Environment,
	TenantBrowserRenderingConfig,
	OAuthProviderApp,
	OAuthBindingDetail,
	OAuthAuthorizeResponse,
	MessageContent,
	ConnectorTokenCreateResponse,
	ConnectorTokenInfo,
	IMConnect,
	CursorPage,
	GroupConversation,
} from "./types";
import { get } from "svelte/store";
import { backendUrl } from "./stores/auth";

function getBase(): string {
	const override = get(backendUrl);
	return override ? override.replace(/\/+$/, "") : "/v1";
}

export function resolveBackendUrl(pathOrUrl: string): string {
	try {
		return new URL(pathOrUrl).toString();
	} catch {
		return new URL(pathOrUrl, new URL(getBase(), window.location.origin)).toString();
	}
}

function normalizeAgent(agent: Agent): Agent {
	const raw = agent as Agent & Record<string, unknown>;
	return {
		...agent,
		runtime_debug: {
			...agent.runtime_debug,
			...(raw.db_namespace ? { db_namespace: String(raw.db_namespace) } : {}),
			...(typeof raw.tool_router_enabled === "boolean" ? { tool_router_enabled: raw.tool_router_enabled } : {}),
			...(typeof raw.sprites_enabled === "boolean" ? { sprites_enabled: raw.sprites_enabled } : {}),
		},
	};
}

async function req<T>(
	method: string,
	path: string,
	token: string,
	body?: unknown,
): Promise<T> {
	const res = await fetch(getBase() + path, {
		method,
		headers: {
			Authorization: `Bearer ${token}`,
			...(body !== undefined ? { "Content-Type": "application/json" } : {}),
		},
		body: body !== undefined ? JSON.stringify(body) : undefined,
	});
	if (!res.ok) {
		const err = await res.json().catch(() => ({ error: res.statusText }));
		throw new Error(err.error || res.statusText);
	}
	return res.json();
}

// Admin endpoints
export const admin = {
	clusterStats: (t: string) => req<ClusterStats>("GET", "/admin/cluster/stats", t),
	listNodes: (t: string) => req<NodeInfo[]>("GET", "/admin/cluster/nodes", t),
	listTenants: (t: string) => req<Tenant[]>("GET", "/admin/tenants", t),
	createTenant: (t: string, name: string) =>
		req<Tenant>("POST", "/admin/tenants", t, { name }),
	getTenant: (t: string, id: string) => req<Tenant>("GET", `/admin/tenants/${id}`, t),
	updateTenant: (t: string, id: string, config: string) =>
		req<unknown>("PATCH", `/admin/tenants/${id}`, t, { config }),
	listAPIKeys: (t: string, tenantId: string) =>
		req<APIKeyInfo[]>("GET", `/admin/tenants/${tenantId}/api-keys`, t),
	createAPIKey: (t: string, tenantId: string, name: string) =>
		req<APIKeyCreateResponse>("POST", `/admin/tenants/${tenantId}/api-keys`, t, {
			name,
		}),
	deleteAPIKey: (t: string, tenantId: string, keyHash: string) =>
		req<unknown>("DELETE", `/admin/tenants/${tenantId}/api-keys/${keyHash}`, t),
	listTenantGroups: (t: string, tenantId: string) =>
		req<AgentGroup[]>("GET", `/admin/tenants/${tenantId}/agent-groups`, t),
	listAgentSessions: (t: string, agentId: string) =>
		req<Session[]>("GET", `/runtime/agents/${agentId}/sessions`, t),
	getAgentFiles: (t: string, agentId: string, path: string) =>
		req<VFSEntry[]>("GET", `/runtime/agents/${agentId}/files${path}`, t),
	getAgentFileContent: async (
		token: string,
		agentId: string,
		path: string,
	): Promise<string> => {
		const res = await fetch(
			`${getBase()}/runtime/agents/${agentId}/files${path}`,
			{
				headers: { Authorization: `Bearer ${token}` },
			},
		);
		if (!res.ok) {
			const err = await res.json().catch(() => ({ error: res.statusText }));
			throw new Error(err.error || res.statusText);
		}
		return res.text();
	},

	// Agent templates (admin)
	listTemplates: (t: string) =>
		req<AgentTemplate[]>("GET", "/admin/templates", t),
	createTemplate: (
		t: string,
		data: Partial<AgentTemplate> & {
			provider_config?: Record<string, unknown>;
			request_headers?: Record<string, string>;
			image_config?: Record<string, unknown>;
			video_config?: Record<string, unknown>;
			vision_describer_config?: Record<string, unknown>;
			analyze_config?: Record<string, unknown>;
			supports_images?: boolean | null;
		},
	) => req<AgentTemplate>("POST", "/admin/templates", t, data),
	getTemplate: (t: string, id: string) =>
		req<AgentTemplate>("GET", `/admin/templates/${id}`, t),
	updateTemplate: (t: string, id: string, data: Record<string, unknown>) =>
		req<unknown>("PATCH", `/admin/templates/${id}`, t, data),
	deleteTemplate: (t: string, id: string) =>
		req<unknown>("DELETE", `/admin/templates/${id}`, t),
};

// Tenant endpoints
export const runtimeDebug = {
	listTemplates: (t: string) => req<AgentTemplate[]>("GET", "/admin/templates/catalog", t),
	getBrowserRenderingConfig: (t: string) =>
		req<TenantBrowserRenderingConfig>("GET", "/browser-rendering-config", t),
	updateBrowserRenderingConfig: (
		t: string,
		data: TenantBrowserRenderingConfig,
	) => req<TenantBrowserRenderingConfig>("PATCH", "/browser-rendering-config", t, data),
	listGroups: (t: string) => req<AgentGroup[]>("GET", "/runtime/agent-groups", t),
	getGroup: (t: string, id: string) =>
		req<AgentGroup>("GET", `/runtime/agent-groups/${id}`, t),
	createGroup: (t: string, data: Partial<AgentGroup>) =>
		req<AgentGroup>("POST", "/runtime/agent-groups", t, data),
	listGroupIMConnects: (t: string, groupId: string, provider?: string) => {
		const params = new URLSearchParams();
		if (provider) params.set("provider", provider);
		const query = params.toString();
		return req<IMConnect[]>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects${query ? `?${query}` : ""}`,
			t,
		);
	},
	disableGroupIMConnect: (t: string, groupId: string, connectId: string) =>
		req<{ disabled: true }>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects/${encodeURIComponent(connectId)}/disable`,
			t,
		),
	enableGroupIMConnect: (t: string, groupId: string, connectId: string) =>
		req<{ enabled: true }>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects/${encodeURIComponent(connectId)}/enable`,
			t,
		),
	deleteGroupIMConnect: (t: string, groupId: string, connectId: string) =>
		req<{ deleted: true }>(
			"DELETE",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/im/connects/${encodeURIComponent(connectId)}`,
			t,
		),
	listGroupRouterMessages: (t: string, id: string) =>
		req<IMStoredMessage[]>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(id)}/router/messages`,
			t,
		),
	sendGroupRouterMessage: (t: string, id: string, data: { content: MessageContent[] | string; client_request_id?: string }) =>
		req<{ conversation_id: string; message_id: string; dispatch_status: string }>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(id)}/router/messages`,
			t,
			data,
		),
	listGroupConversations: (
		t: string,
		groupId: string,
		opts?: { limit?: number; cursor?: string },
	) => {
		const params = new URLSearchParams();
		if (opts?.limit) params.set("limit", String(opts.limit));
		if (opts?.cursor) params.set("cursor", opts.cursor);
		const query = params.toString();
		return req<CursorPage<GroupConversation>>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations${query ? `?${query}` : ""}`,
			t,
		);
	},
	createGroupConversation: (
		t: string,
		groupId: string,
		data: { title?: string; conversation_id?: string; participants?: unknown[] } = {},
	) =>
		req<GroupConversation>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations`,
			t,
			data,
		),
	getGroupConversation: (t: string, groupId: string, conversationId: string) =>
		req<GroupConversation>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversationId)}`,
			t,
		),
	listGroupConversationMessages: (
		t: string,
		groupId: string,
		conversationId: string,
		opts?: { limit?: number; after_id?: string },
	) => {
		const params = new URLSearchParams();
		if (opts?.limit) params.set("limit", String(opts.limit));
		if (opts?.after_id) params.set("after_id", opts.after_id);
		const query = params.toString();
		return req<IMStoredMessage[]>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversationId)}/messages${query ? `?${query}` : ""}`,
			t,
		);
	},
	sendGroupConversationMessage: (
		t: string,
		groupId: string,
		conversationId: string,
		text: string,
		clientRequestId?: string,
	) =>
		req<{ conversation_id: string; message_id: string; dispatch_status: string }>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversationId)}/messages`,
			t,
			{
				kind: "message",
				content: [{ type: "text", text }],
				...(clientRequestId ? { client_request_id: clientRequestId } : {}),
			},
		),
	deleteGroup: (t: string, id: string) =>
		req<unknown>("DELETE", `/runtime/agent-groups/${id}`, t),

	listOAuthProviderApps: (t: string) =>
		req<OAuthProviderApp[]>("GET", "/runtime/oauth/provider-apps", t),
	updateOAuthProviderApp: (
		t: string,
		provider: string,
		data: { client_id?: string; client_secret?: string },
	) =>
		req<OAuthProviderApp>(
			"PUT",
			`/runtime/oauth/provider-apps/${encodeURIComponent(provider)}`,
			t,
			data,
		),
	deleteOAuthProviderApp: (t: string, provider: string) =>
		req<unknown>(
			"DELETE",
			`/runtime/oauth/provider-apps/${encodeURIComponent(provider)}`,
			t,
		),
	listGroupOAuthBindings: (t: string, groupId: string) =>
		req<OAuthBindingDetail[]>(
			"GET",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/oauth-connections`,
			t,
		),
	startOAuthAuthorization: (
		t: string,
		groupId: string,
		provider: string,
		data: { alias: string; scopes?: string[]; redirect_after?: string; host?: string },
	) =>
		req<OAuthAuthorizeResponse>(
			"POST",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/oauth/${encodeURIComponent(provider)}/authorize`,
			t,
			data,
		),
	updateGroupOAuthBinding: (
		t: string,
		groupId: string,
		bindingId: string,
		data: { alias?: string; env_hints?: Record<string, string> },
	) =>
		req<{ binding_id: string; alias: string; provider: string }>(
			"PATCH",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/oauth-connections/${encodeURIComponent(bindingId)}`,
			t,
			data,
		),
	deleteGroupOAuthBinding: (t: string, groupId: string, bindingId: string) =>
		req<unknown>(
			"DELETE",
			`/runtime/agent-groups/${encodeURIComponent(groupId)}/oauth-connections/${encodeURIComponent(bindingId)}`,
			t,
		),

	listAgents: (t: string, groupId?: string) => {
		const params = new URLSearchParams();
		if (groupId) params.set("group_id", groupId);
		const query = params.toString();
		return req<Agent[]>("GET", `/runtime/agents${query ? `?${query}` : ""}`, t).then((agents) =>
			agents.map(normalizeAgent),
		);
	},
	listAgentActivities: (t: string) =>
		req<AgentActivity[]>("GET", "/runtime/agent-activities", t),
	getAgent: (t: string, id: string) =>
		req<Agent>("GET", `/runtime/agents/${id}`, t).then(normalizeAgent),
	updateAgent: (
		t: string,
		id: string,
		data: {
			name?: string;
			system_prompt?: string;
			template_id?: string;
			runtime_debug?: {
				tool_router_enabled?: boolean;
				sprites_enabled?: boolean;
			};
		},
	) =>
		req<unknown>("PATCH", `/runtime/agents/${id}`, t, {
			name: data.name,
			system_prompt: data.system_prompt,
			template_id: data.template_id,
			...(data.runtime_debug?.tool_router_enabled !== undefined
				? { tool_router_enabled: data.runtime_debug.tool_router_enabled }
				: {}),
			...(data.runtime_debug?.sprites_enabled !== undefined
				? { sprites_enabled: data.runtime_debug.sprites_enabled }
				: {}),
		}),
	createAgent: (
		t: string,
		group_id: string,
		template_id: string,
		fork_from?: string,
		opts?: { runtime_debug?: { sprites_enabled?: boolean } },
	) =>
		req<Agent>("POST", "/runtime/agents", t, {
			group_id,
			template_id,
			...(fork_from ? { fork_from } : {}),
			...(opts?.runtime_debug?.sprites_enabled ? { sprites_enabled: true } : {}),
		}).then(normalizeAgent),
	cancelAgent: (t: string, id: string) =>
		req<unknown>("POST", `/runtime/agents/${id}/cancel`, t),
	wakeAgent: (
		t: string,
		id: string,
		body?: { operation_id: string; result: string },
	) => req<unknown>("POST", `/runtime/agents/${id}/wake`, t, body),
	deleteAgent: (t: string, id: string) =>
		req<unknown>("DELETE", `/runtime/agents/${id}`, t),
	listConnectorTokens: (t: string, id: string) =>
		req<ConnectorTokenInfo[]>("GET", `/runtime/agents/${id}/connector-tokens`, t),
	createConnectorToken: (
		t: string,
		id: string,
		data: { name?: string; alias?: string; expires_in_seconds?: number },
	) =>
		req<ConnectorTokenCreateResponse>(
			"POST",
			`/runtime/agents/${id}/connector-tokens`,
			t,
			data,
		),
	deleteConnectorToken: (t: string, id: string, tokenHash: string) =>
		req<unknown>(
			"DELETE",
			`/runtime/agents/${id}/connector-tokens/${encodeURIComponent(tokenHash)}`,
			t,
		),
	sendSessionMessage: (
		t: string,
		agentId: string,
		content: string,
		sessionId = "main",
		// Stable per-submit identity, owned by the CALLER (minted per retained
		// draft, reused across retries of that draft): a commit whose response
		// was lost must dedupe on retry, so a per-call default here would be
		// wrong.
		sourceMessageId: string,
	) =>
		req<{ accepted: boolean; dedupe: string; session_id: string }>(
			"POST",
			`/runtime/agents/${agentId}/sessions/${sessionId}/messages`,
			t,
			{ content, source_message_id: sourceMessageId },
		),
	listSessionMessages: (t: string, agentId: string, sessionId = "main") =>
		req<RuntimeSessionMessages>(
			"GET",
			`/runtime/agents/${agentId}/sessions/${sessionId}/messages`,
			t,
		),

	searchMessages: (t: string, agentId: string, q: string, limit?: number) =>
		req<MessageSearchResponse>(
			"GET",
			`/runtime/agents/${agentId}/messages/search?q=${encodeURIComponent(q)}${limit ? `&limit=${limit}` : ""}`,
			t,
		),

	getFiles: (t: string, agentId: string, path: string) =>
		req<VFSEntry[]>("GET", `/runtime/agents/${agentId}/files${path}`, t),
	getFileContent: async (
		token: string,
		agentId: string,
		path: string,
	): Promise<string> => {
		const res = await fetch(`${getBase()}/runtime/agents/${agentId}/files${path}`, {
			headers: { Authorization: `Bearer ${token}` },
		});
		if (!res.ok) {
			const err = await res.json().catch(() => ({ error: res.statusText }));
			throw new Error(err.error || res.statusText);
		}
		return res.text();
	},
	getFileBlob: async (
		token: string,
		agentId: string,
		path: string,
	): Promise<Blob> => {
		const res = await fetch(`${getBase()}/runtime/agents/${agentId}/files${path}`, {
			headers: { Authorization: `Bearer ${token}` },
		});
		if (!res.ok) {
			const err = await res.json().catch(() => ({ error: res.statusText }));
			throw new Error(err.error || res.statusText);
		}
		return res.blob();
	},

	listAgentSites: (t: string, agentId: string) =>
		req<SiteInfo[]>("GET", `/runtime/agents/${agentId}/sites`, t),

	listEnvironments: (t: string) =>
		req<Environment[]>("GET", "/runtime/environments", t),
	getEnvironment: (t: string, groupId: string, deviceId: string) =>
		req<Environment>("GET", `/runtime/groups/${groupId}/environments/${deviceId}`, t),
	deleteEnvironment: (t: string, groupId: string, deviceId: string) =>
		req<unknown>("DELETE", `/runtime/groups/${groupId}/environments/${deviceId}`, t),

	// Sessions
	listSessions: (t: string, agentId: string, opts?: { includeHidden?: boolean }) => {
		const params = new URLSearchParams();
		if (opts?.includeHidden) params.set("include_hidden", "true");
		const query = params.toString();
		return req<Session[]>(
			"GET",
			`/runtime/agents/${agentId}/sessions${query ? `?${query}` : ""}`,
			t,
		);
	},
	getSession: (t: string, agentId: string, sessionId: string) =>
		req<Session>("GET", `/runtime/agents/${agentId}/sessions/${sessionId}`, t),
	forkSession: (
		t: string,
		agentId: string,
		sessionId: string,
		data: { name?: string; message_id: number },
	) =>
		req<Session>(
			"POST",
			`/runtime/agents/${agentId}/sessions/${sessionId}/fork`,
			t,
			data,
		),
	compactSession: (t: string, agentId: string, sessionId: string) =>
		req<{ status: string }>(
			"POST",
			`/runtime/agents/${agentId}/sessions/${sessionId}/compact`,
			t,
		),
	getSessionTrace: (t: string, agentId: string, sessionId: string) =>
		req<unknown>(
			"GET",
			`/runtime/agents/${agentId}/sessions/${encodeURIComponent(sessionId)}/trace`,
			t,
		),
};
