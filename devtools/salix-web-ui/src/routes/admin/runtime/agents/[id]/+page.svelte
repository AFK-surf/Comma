<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import { aggregateAgentStatus } from '$lib/agent-status';
	import { goto } from '$app/navigation';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import type { Agent, AgentGroup, AgentTemplate, ConnectorTokenCreateResponse, ConnectorTokenInfo, Environment, MessageSearchResult, Session, SiteInfo } from '$lib/types';
	import { onMount } from 'svelte';

	const agentId = $derived($page.params.id!);
	const selectedSessionId = $derived($page.url.searchParams.get('session') || '');

	let agent = $state<Agent | null>(null);
	let agentGroup = $state<AgentGroup | null>(null);
	let envs = $state<Environment[]>([]);
	let sessions = $state<Session[]>([]);
	let sites = $state<SiteInfo[]>([]);
	let connectorTokens = $state<ConnectorTokenInfo[]>([]);
	let templates = $state<AgentTemplate[]>([]);
	let error = $state('');
	let selectedTemplateId = $state('');
	let templateDirty = $state(false);
	let templateSaving = $state(false);
	let toolRouterEnabled = $state(false);
	let toolRouterDirty = $state(false);
	let toolRouterSaving = $state(false);
	let spritesEnabled = $state(false);
	let spritesDirty = $state(false);
	let spritesSaving = $state(false);
	let showHiddenSessions = $state(false);
	let connectorTokenName = $state('Remote Connector');
	let connectorTokenAlias = $state('remote');
	let connectorTokenTtlDays = $state('30');
	let connectorTokenCreating = $state(false);
	let connectorTokenError = $state('');
	let connectorToken = $state<ConnectorTokenCreateResponse | null>(null);
	let copiedConnectorField = $state('');
	const agentStatus = $derived(agent ? aggregateAgentStatus(agent.status, sessions) : '');

	async function load() {
		try {
			const nextAgent = await runtimeDebug.getAgent($adminKey, agentId);
			agent = nextAgent;
			if (!templateDirty && !templateSaving) {
				selectedTemplateId = nextAgent.template_id || '';
			}
			if (!toolRouterDirty && !toolRouterSaving) {
				toolRouterEnabled = !!nextAgent.runtime_debug?.tool_router_enabled;
			}
			if (!spritesDirty && !spritesSaving) {
				spritesEnabled = !!nextAgent.runtime_debug?.sprites_enabled;
			}
			if (nextAgent.group_id) {
				try {
					agentGroup = await runtimeDebug.getGroup($adminKey, nextAgent.group_id);
				} catch {
					agentGroup = null;
				}
			} else {
				agentGroup = null;
			}
			sessions = await runtimeDebug.listSessions($adminKey, agentId, {
				includeHidden: showHiddenSessions,
			});
		} catch (e) {
			error = String(e);
		}
	}

	async function loadEnvs() {
		try {
			const all = await runtimeDebug.listEnvironments($adminKey);
			envs = all;
		} catch { /* environments may not be available */ }
	}

	async function loadSites() {
		try {
			sites = await runtimeDebug.listAgentSites($adminKey, agentId);
		} catch { /* sites may not exist */ }
	}

	async function loadConnectorTokens() {
		try {
			connectorTokens = await runtimeDebug.listConnectorTokens($adminKey, agentId);
		} catch { /* connector token API may not be available */ }
	}

	async function loadTemplates() {
		try {
			templates = await runtimeDebug.listTemplates($adminKey);
		} catch (e) {
			error = String(e);
		}
	}

	onMount(() => {
		if (selectedSessionId) showHiddenSessions = true;
		load();
		loadEnvs();
		loadSites();
		loadConnectorTokens();
		loadTemplates();
		const interval = setInterval(() => {
			load();
		}, 3000);
		return () => clearInterval(interval);
	});

	async function cancel() {
		if (!confirm('Cancel this agent?')) return;
		try {
			await runtimeDebug.cancelAgent($adminKey, agentId);
			load();
		} catch (e) {
			error = String(e);
		}
	}

	async function wake() {
		try {
			await runtimeDebug.wakeAgent($adminKey, agentId);
			load();
		} catch (e) {
			error = String(e);
		}
	}

	async function deleteAgent() {
		if (!confirm('Permanently delete this agent and all its data?')) return;
		try {
			await runtimeDebug.deleteAgent($adminKey, agentId);
			goto('/admin/runtime/agents');
		} catch (e) {
			error = String(e);
		}
	}

	let searchQuery = $state('');
	let lastSearchQuery = $state('');
	let searchResults = $state<MessageSearchResult[]>([]);
	let searchArchivedNotSearched = $state(false);
	let searchLoading = $state(false);
	let searchError = $state('');
	let hasSearched = $state(false);

	async function runSearch() {
		const q = searchQuery.trim();
		if (!q) {
			searchError = 'Enter a search query.';
			hasSearched = false;
			searchResults = [];
			return;
		}

		searchLoading = true;
		searchError = '';
		lastSearchQuery = q;
		try {
			const searchResponse = await runtimeDebug.searchMessages($adminKey, agentId, q, 20);
			searchResults = searchResponse.results ?? [];
			searchArchivedNotSearched = searchResponse.archived_not_searched === true;
			hasSearched = true;
		} catch (e) {
			searchError = String(e);
			hasSearched = true;
			searchResults = [];
		} finally {
			searchLoading = false;
		}
	}

	function getVisibleSession(sessionId?: string): Session | undefined {
		if (!sessionId) return undefined;
		return sessions.find((session) => session.session_id === sessionId);
	}

	function formatSessionLabel(sessionId?: string): string {
		if (!sessionId) return 'Agent-level message';
		const session = getVisibleSession(sessionId);
		if (session) return session.name || session.session_id.slice(0, 12);
		return `History ${sessionId.slice(0, 8)}`;
	}

	interface SearchSnippetSegment {
		text: string;
		highlight: boolean;
	}

	function snippetSegments(snippet: string): SearchSnippetSegment[] {
		return snippet
			.split(/(«[^»]+»)/g)
			.filter(Boolean)
			.map((part) => part.startsWith('«') && part.endsWith('»')
				? { text: part.slice(1, -1), highlight: true }
				: { text: part, highlight: false });
	}

	function templateLabel(template: AgentTemplate): string {
		return template.model ? `${template.name} (${template.model})` : template.name;
	}

	function currentTemplateLabel(): string {
		if (!agent?.template_id) return '-';
		const template = templates.find((candidate) => candidate.template_id === agent?.template_id);
		return template ? templateLabel(template) : `unknown(${agent.template_id.slice(0, 7)})`;
	}

	function sessionRowClass(session: Session): string {
		const base = 'flex flex-col sm:flex-row sm:items-center bg-gray-900 border rounded text-sm group';
		if (selectedSessionId && session.session_id === selectedSessionId) {
			return `${base} border-blue-500/70 ring-1 ring-blue-500/30`;
		}
		return `${base} border-gray-800`;
	}

	function handleTemplateChange(event: Event) {
		selectedTemplateId = (event.currentTarget as HTMLSelectElement).value;
		templateDirty = selectedTemplateId !== (agent?.template_id || '');
	}

	async function saveTemplate() {
		if (!agent || !selectedTemplateId || selectedTemplateId === agent.template_id) return;
		templateSaving = true;
		try {
			await runtimeDebug.updateAgent($adminKey, agentId, { template_id: selectedTemplateId });
			templateDirty = false;
			await load();
		} catch (e) {
			error = String(e);
		} finally {
			templateSaving = false;
		}
	}

	function handleToolRouterChange(event: Event) {
		toolRouterEnabled = (event.currentTarget as HTMLInputElement).checked;
		toolRouterDirty = toolRouterEnabled !== !!agent?.runtime_debug?.tool_router_enabled;
	}

	async function saveToolRouter() {
		if (!agent) return;
		toolRouterSaving = true;
		try {
			await runtimeDebug.updateAgent($adminKey, agentId, { runtime_debug: { tool_router_enabled: toolRouterEnabled } });
			toolRouterDirty = false;
			await load();
		} catch (e) {
			error = String(e);
		} finally {
			toolRouterSaving = false;
		}
	}

	function handleSpritesChange(event: Event) {
		spritesEnabled = (event.currentTarget as HTMLInputElement).checked;
		spritesDirty = spritesEnabled !== !!agent?.runtime_debug?.sprites_enabled;
	}

	async function saveSprites() {
		if (!agent) return;
		spritesSaving = true;
		try {
			await runtimeDebug.updateAgent($adminKey, agentId, { runtime_debug: { sprites_enabled: spritesEnabled } });
			spritesDirty = false;
			await load();
		} catch (e) {
			error = String(e);
		} finally {
			spritesSaving = false;
		}
	}

	async function createConnectorToken() {
		connectorTokenCreating = true;
		connectorTokenError = '';
		copiedConnectorField = '';
		try {
			const days = Number(connectorTokenTtlDays);
			if (!Number.isFinite(days) || days <= 0) {
				throw new Error('TTL must be a positive number of days');
			}
			connectorToken = await runtimeDebug.createConnectorToken($adminKey, agentId, {
				name: connectorTokenName.trim() || undefined,
				alias: connectorTokenAlias.trim() || undefined,
				expires_in_seconds: Math.round(days * 24 * 60 * 60),
			});
			await loadConnectorTokens();
		} catch (e) {
			connectorTokenError = String(e);
		} finally {
			connectorTokenCreating = false;
		}
	}

	async function deleteConnectorToken(tokenHash: string, name: string) {
		if (!confirm(`Delete connector token ${name}? Connected clients using it will fail on reconnect.`)) return;
		connectorTokenError = '';
		try {
			await runtimeDebug.deleteConnectorToken($adminKey, agentId, tokenHash);
			connectorTokens = connectorTokens.filter((token) => token.token_hash !== tokenHash);
			if (connectorToken?.token_hash === tokenHash) connectorToken = null;
		} catch (e) {
			connectorTokenError = String(e);
		}
	}

	function shellQuote(value: string): string {
		return `'${value.replaceAll("'", "'\"'\"'")}'`;
	}

	function connectorCommand(): string {
		if (!connectorToken) return '';
		return [
			`SALIX_CONNECTOR_TOKEN=${shellQuote(connectorToken.token)}`,
			'salix-connect',
			'--server',
			shellQuote(connectorToken.server),
			'--name',
			shellQuote(connectorToken.name),
			'--alias',
			shellQuote(connectorToken.alias),
		].join(' ');
	}

	async function copyConnectorField(field: string, value: string) {
		await navigator.clipboard.writeText(value);
		copiedConnectorField = field;
		setTimeout(() => {
			if (copiedConnectorField === field) copiedConnectorField = '';
		}, 1500);
	}

</script>

<a href="/admin/runtime/agents" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Agents</a>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if agent}
	<div class="flex items-center gap-3 mb-2 flex-wrap">
		<h1 class="text-xl font-bold font-mono">{agent.agent_id.slice(0, 12)}</h1>
		<StatusBadge status={agentStatus} />
	</div>
	<p class="text-xs text-gray-500 font-mono mb-6">{agent.agent_id}</p>

	{#if agent.error}
		<div class="bg-red-900/20 border border-red-800 rounded p-3 mb-4 text-sm text-red-400">{agent.error}</div>
	{/if}

	<div class="flex gap-2 mb-6 flex-wrap">
		<a href="/admin/runtime/agents/{agent.agent_id}/files/" class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-sm">Files</a>
		<a href="/admin/runtime/agents/{agent.agent_id}/files/memory/" class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-sm">Memory</a>
		{#if agentStatus === 'waiting'}
			<button onclick={wake} class="bg-purple-600 hover:bg-purple-500 px-3 py-1.5 rounded text-sm">Wake</button>
		{/if}
		{#if ['queued', 'running', 'paused', 'waiting', 'created'].includes(agentStatus)}
			<button onclick={cancel} class="bg-red-600/20 text-red-400 hover:bg-red-600/30 px-3 py-1.5 rounded text-sm">Cancel</button>
		{/if}
		{#if ['completed', 'failed', 'cancelled'].includes(agentStatus)}
			<button onclick={deleteAgent} class="bg-red-600/20 text-red-400 hover:bg-red-600/30 px-3 py-1.5 rounded text-sm">Delete</button>
		{/if}
	</div>

	<div class="grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm mb-6">
		<div class="bg-gray-900 rounded p-3 border border-gray-800">
			<div class="text-gray-500 text-xs mb-1">Group</div>
			{#if agent.group_id}
				<a href="/admin/runtime/groups/{agent.group_id}" class="text-blue-400 hover:underline">
					<div class="text-sm text-gray-200">{agentGroup?.name || 'Unnamed group'}</div>
					<div class="font-mono text-xs text-blue-400 break-all mt-1">{agent.group_id}</div>
				</a>
				<a href="/admin/runtime/groups/{agent.group_id}/conversations" class="mt-2 inline-block text-xs text-blue-400 hover:underline">
					Group conversations
				</a>
			{:else}
				<div class="font-mono text-xs text-gray-500">-</div>
			{/if}
		</div>
		<div class="bg-gray-900 rounded p-3 border border-gray-800">
			<div class="text-gray-500 text-xs mb-1">Template</div>
			<div class="text-gray-200">{currentTemplateLabel()}</div>
			{#if agent.template_id}
				<div class="font-mono text-[11px] text-gray-500 mt-1 break-all">{agent.template_id}</div>
			{/if}
			{#if templates.length > 0}
				<div class="mt-3 flex flex-col sm:flex-row gap-2">
					<select
						value={selectedTemplateId}
						onchange={handleTemplateChange}
						class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
					>
						{#if agent?.template_id && !templates.some((candidate) => candidate.template_id === (agent?.template_id ?? ''))}
							<option value={agent?.template_id ?? ''}>unknown({(agent?.template_id ?? '').slice(0, 7)})</option>
						{/if}
						{#each templates as template}
							<option value={template.template_id}>{templateLabel(template)}</option>
						{/each}
					</select>
					<button
						onclick={saveTemplate}
						disabled={!selectedTemplateId || selectedTemplateId === agent.template_id || templateSaving}
						class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed px-3 py-1.5 rounded text-sm whitespace-nowrap"
					>{templateSaving ? 'Updating...' : 'Change Template'}</button>
				</div>
			{/if}
		</div>
		<div class="bg-gray-900 rounded p-3 border border-gray-800">
			<div class="text-gray-500 text-xs mb-1">Tool Router</div>
			<label class="flex items-center gap-2 text-sm text-gray-200">
				<input
					type="checkbox"
					checked={toolRouterEnabled}
					onchange={handleToolRouterChange}
					class="accent-blue-500"
				/>
				<span>Enable tool router</span>
			</label>
			<p class="text-[11px] text-gray-500 mt-1">
				Replaces this agent's tool surface with a single <span class="font-mono">Call</span> tool routed through a chat-completions LLM (configured cluster-wide as <span class="font-mono">tool_router</span>). The cluster-wide setting can disable this regardless.
			</p>
			{#if toolRouterDirty}
				<div class="mt-3">
					<button
						onclick={saveToolRouter}
						disabled={toolRouterSaving}
						class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed px-3 py-1.5 rounded text-sm whitespace-nowrap"
					>{toolRouterSaving ? 'Saving...' : 'Save'}</button>
				</div>
			{/if}
		</div>
		<div class="bg-gray-900 rounded p-3 border border-gray-800">
			<div class="text-gray-500 text-xs mb-1">Cloud VM</div>
			<label class="flex items-center gap-2 text-sm text-gray-200">
				<input
					type="checkbox"
					checked={spritesEnabled}
					onchange={handleSpritesChange}
					class="accent-blue-500"
				/>
				<span>Enable cloud VM</span>
			</label>
			<p class="text-[11px] text-gray-500 mt-1">
				Provisions a managed Sprites cloud VM exposed to this agent's group as the <span class="font-mono">cloud-vm</span> environment. Requires Sprites credentials in the tenant config; disabling keeps the VM until the agent is deleted.
			</p>
			{#if spritesDirty}
				<div class="mt-3">
					<button
						onclick={saveSprites}
						disabled={spritesSaving}
						class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed px-3 py-1.5 rounded text-sm whitespace-nowrap"
					>{spritesSaving ? 'Saving...' : 'Save'}</button>
				</div>
			{/if}
		</div>
		{#if agent.forked_from}
			<div class="bg-gray-900 rounded p-3 border border-gray-800">
				<div class="text-gray-500 text-xs mb-1">Forked From</div>
				<div class="font-mono text-xs">{agent.forked_from}</div>
			</div>
		{/if}
		{#if agent.node_id}
			<div class="bg-gray-900 rounded p-3 border border-gray-800">
				<div class="text-gray-500 text-xs mb-1">Node</div>
				<div class="font-mono text-xs">{agent.node_id.slice(0, 8)}</div>
			</div>
		{/if}
		<div class="bg-gray-900 rounded p-3 border border-gray-800">
			<div class="text-gray-500 text-xs mb-1">Created</div>
			<div>{new Date(agent.created_at * 1000).toLocaleString()}</div>
		</div>
	</div>

	<!-- Sprite VM -->
	{#if agent.sprite}
		<div class="bg-gray-900 border border-gray-800 rounded p-3 mb-6 flex items-center gap-3 text-sm">
			<span class="w-1.5 h-1.5 rounded-full {agent.sprite.status === 'ready' ? 'bg-green-500' : agent.sprite.status === 'failed' ? 'bg-red-500' : 'bg-yellow-500 animate-pulse'}"></span>
			<span class="text-gray-400">Sprite</span>
			<span class="font-mono text-xs">{agent.sprite.sprite_name}</span>
			<span class="text-xs {agent.sprite.status === 'ready' ? 'text-green-400' : agent.sprite.status === 'failed' ? 'text-red-400' : 'text-yellow-400'}">{agent.sprite.status}</span>
			{#if agent.sprite.error}
				<span class="text-xs text-red-400 truncate">{agent.sprite.error}</span>
			{:else if agent.sprite.last_error}
				<span class="text-xs text-yellow-400/80 truncate" title={agent.sprite.last_error}>last attempt: {agent.sprite.last_error}</span>
			{/if}
		</div>
	{/if}

	<!-- Connector token -->
	<div class="mb-6 bg-gray-900 border border-gray-800 rounded p-4">
		<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-3">
			<div>
				<h2 class="text-sm font-medium text-gray-200">Connector Token</h2>
				<p class="text-xs text-gray-500 mt-1">Agent-scoped credential for <span class="font-mono">salix-connect</span>.</p>
			</div>
			<span class="text-[11px] uppercase text-gray-500">agent-scoped</span>
		</div>
		<form class="grid grid-cols-1 sm:grid-cols-[1fr_0.8fr_7rem_auto] gap-2 items-end" onsubmit={(e: SubmitEvent) => { e.preventDefault(); createConnectorToken(); }}>
			<label class="block">
				<span class="text-xs text-gray-400">Name</span>
				<input
					bind:value={connectorTokenName}
					class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
					placeholder="Remote Connector"
				/>
			</label>
			<label class="block">
				<span class="text-xs text-gray-400">Alias</span>
				<input
					bind:value={connectorTokenAlias}
					class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500"
					placeholder="remote"
				/>
			</label>
			<label class="block">
				<span class="text-xs text-gray-400">TTL days</span>
				<input
					bind:value={connectorTokenTtlDays}
					type="number"
					min="1"
					step="1"
					class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
				/>
			</label>
			<button
				type="submit"
				disabled={connectorTokenCreating}
				class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed px-3 py-1.5 rounded text-sm whitespace-nowrap"
			>{connectorTokenCreating ? 'Minting...' : 'Mint Token'}</button>
		</form>

		{#if connectorTokenError}
			<p class="text-red-400 text-sm mt-3">{connectorTokenError}</p>
		{/if}

		{#if connectorToken}
			<div class="mt-4 border-t border-gray-800 pt-4 space-y-3">
				<div>
					<div class="flex items-center justify-between gap-2 mb-1">
						<span class="text-xs text-gray-400">Token</span>
						<button
							onclick={() => copyConnectorField('token', connectorToken!.token)}
							class="text-xs text-blue-400 hover:text-blue-300"
						>{copiedConnectorField === 'token' ? 'Copied' : 'Copy'}</button>
					</div>
					<input
						readonly
						value={connectorToken.token}
						class="w-full bg-gray-950 border border-gray-800 rounded px-3 py-2 text-xs font-mono text-gray-200 focus:outline-none"
					/>
				</div>
				<div>
					<div class="flex items-center justify-between gap-2 mb-1">
						<span class="text-xs text-gray-400">Command</span>
						<button
							onclick={() => copyConnectorField('command', connectorCommand())}
							class="text-xs text-blue-400 hover:text-blue-300"
						>{copiedConnectorField === 'command' ? 'Copied' : 'Copy'}</button>
					</div>
					<textarea
						readonly
						value={connectorCommand()}
						rows="3"
						class="w-full bg-gray-950 border border-gray-800 rounded px-3 py-2 text-xs font-mono text-gray-200 focus:outline-none resize-y"
					></textarea>
				</div>
				<div class="text-xs text-gray-500">
					Expires {new Date(connectorToken.expires_at * 1000).toLocaleString()}
				</div>
			</div>
		{/if}

		<div class="mt-4 border-t border-gray-800 pt-4">
			<div class="flex items-center justify-between gap-2 mb-2">
				<h3 class="text-xs font-medium text-gray-400">Existing tokens</h3>
				<button onclick={loadConnectorTokens} class="text-xs text-gray-500 hover:text-gray-300">Refresh</button>
			</div>
			{#if connectorTokens.length > 0}
				<div class="overflow-x-auto">
					<table class="w-full text-xs text-left">
						<thead class="text-gray-500">
							<tr>
								<th class="py-1 font-medium">Name</th>
								<th class="py-1 font-medium">Alias</th>
								<th class="py-1 font-medium">Created</th>
								<th class="py-1 font-medium">Expires</th>
								<th class="py-1"></th>
							</tr>
						</thead>
						<tbody>
							{#each connectorTokens as token}
								<tr class="border-t border-gray-800">
									<td class="py-2 text-gray-200">{token.name}</td>
									<td class="py-2 font-mono text-gray-400">{token.alias}</td>
									<td class="py-2 text-gray-500">{new Date(token.created_at * 1000).toLocaleDateString()}</td>
									<td class="py-2 {token.expired ? 'text-red-400' : 'text-gray-500'}">
										{new Date(token.expires_at * 1000).toLocaleDateString()}
									</td>
									<td class="py-2 text-right">
										<button
											onclick={() => deleteConnectorToken(token.token_hash, token.name)}
											class="text-red-400/70 hover:text-red-300"
										>Delete</button>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{:else}
				<p class="text-xs text-gray-600">No connector tokens minted for this agent.</p>
			{/if}
		</div>
	</div>

	<!-- Websites -->
	{#if sites.length > 0}
		<div class="mb-6">
			<h2 class="text-sm font-medium text-gray-400 mb-2">Websites</h2>
			<div class="flex flex-wrap gap-2">
				{#each sites as site}
					<a
						href={site.url}
						target="_blank"
						rel="noopener noreferrer"
						class="bg-gray-900 border border-gray-800 rounded px-3 py-1.5 text-xs flex items-center gap-2 hover:border-gray-600 transition-colors"
					>
						<span class="text-blue-400">{site.name}</span>
						{#if site.url}
							<span class="text-gray-600 font-mono truncate max-w-64">{site.url.replace('http://', '')}</span>
						{/if}
						<span class="text-gray-500">&nearr;</span>
					</a>
				{/each}
			</div>
		</div>
	{/if}

	<div class="mb-6 bg-gray-900 border border-gray-800 rounded p-4">
		<div class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-3 mb-3">
			<div>
				<h2 class="text-sm font-medium text-gray-200">Message Search</h2>
				<p class="text-xs text-gray-500 mt-1">
					Searches this agent's visible session history. Older pre-index messages are not backfilled.
				</p>
			</div>
			<form
				class="flex flex-col sm:flex-row gap-2 sm:min-w-[28rem]"
				onsubmit={(e: SubmitEvent) => { e.preventDefault(); runSearch(); }}
			>
				<input
					bind:value={searchQuery}
					type="search"
					placeholder="Search messages across sessions"
					class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-2 text-sm focus:outline-none focus:border-gray-500"
				/>
				<button
					type="submit"
					disabled={searchLoading || !searchQuery.trim()}
					class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed px-3 py-2 rounded text-sm whitespace-nowrap"
				>{searchLoading ? 'Searching...' : 'Search'}</button>
			</form>
		</div>

		{#if searchError}
			<p class="text-red-400 text-sm mb-3">{searchError}</p>
		{/if}

		{#if searchLoading}
			<p class="text-sm text-gray-400">Searching visible history…</p>
		{:else if hasSearched}
			<div class="flex items-center justify-between gap-2 mb-3">
				<p class="text-sm text-gray-400">
					{searchResults.length} result{searchResults.length === 1 ? '' : 's'}{searchArchivedNotSearched ? ' (archived history not searched)' : ''} for
					<span class="text-gray-200">"{lastSearchQuery}"</span>
				</p>
			</div>

			{#if searchResults.length > 0}
				<div class="space-y-2">
					{#each searchResults as result}
						{@const visibleSession = getVisibleSession(result.session_id)}
						<div class="bg-gray-950/60 border border-gray-800 rounded p-3">
							<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
								<div class="flex items-center gap-2 flex-wrap">
									<span class="text-[11px] uppercase tracking-wide px-2 py-0.5 rounded bg-gray-800 text-gray-300">{result.role}</span>
									<span class="text-xs text-gray-400">{formatSessionLabel(result.session_id)}</span>
									{#if visibleSession}
										<span class="text-xs text-gray-500">Session indexed</span>
									{/if}
								</div>
								<span class="text-xs text-gray-500">{new Date(result.created_at * 1000).toLocaleString()}</span>
							</div>
							<p class="text-sm text-gray-200 mt-2 leading-6 break-words">
								{#each snippetSegments(result.snippet) as segment, index (`${result.message_id}-${index}`)}
									<span class={segment.highlight ? 'bg-blue-500/15 text-blue-200 rounded px-0.5' : ''}>{segment.text}</span>
								{/each}
							</p>
						</div>
					{/each}
				</div>
			{:else}
				<p class="text-sm text-gray-500">No matches in indexed visible history.</p>
			{/if}
		{:else}
			<p class="text-sm text-gray-500">Enter a query to search across this agent's sessions.</p>
		{/if}
	</div>

	<!-- Sessions -->
	<div class="mb-6">
		<div class="flex flex-col sm:flex-row sm:items-center justify-between mb-3 gap-2">
			<div class="flex items-center gap-3">
				<h2 class="text-sm font-medium text-gray-400">Sessions</h2>
				<label class="flex items-center gap-1.5 text-xs text-gray-500 cursor-pointer">
					<input
						type="checkbox"
						bind:checked={showHiddenSessions}
						onchange={() => load()}
						class="accent-emerald-500"
					/>
					<span>Show hidden</span>
				</label>
			</div>
		</div>
		<div class="space-y-1">
			{#each sessions as s}
				<div id={`session-${s.session_id}`} class={sessionRowClass(s)}>
					<div class="flex-1 flex flex-col sm:flex-row sm:items-center sm:justify-between px-3 py-2 gap-1 sm:gap-0">
						<div class="flex items-center gap-2 min-w-0">
							<a href="/admin/runtime/agents/{agentId}/sessions/{s.session_id}" class="text-white text-sm truncate hover:text-blue-300 hover:underline">{s.name || s.session_id.slice(0, 12)}</a>
							{#if s.name}
								<span class="text-gray-600 font-mono text-xs shrink-0">{s.session_id.slice(0, 8)}</span>
							{/if}
							{#if selectedSessionId && s.session_id === selectedSessionId}
								<span class="text-[10px] uppercase px-1 py-0.5 rounded bg-blue-500/15 text-blue-300 border border-blue-500/30 shrink-0">selected</span>
							{/if}
							{#if s.hidden}
								<span class="text-[10px] uppercase px-1 py-0.5 rounded bg-gray-700/40 text-gray-400 border border-gray-700 shrink-0">hidden</span>
							{/if}
						</div>
						<div class="flex items-center gap-2 shrink-0 sm:ml-2">
							<span class="text-gray-500 text-xs">{new Date(s.created_at * 1000).toLocaleString()}</span>
							<StatusBadge status={s.activity_status || s.status} />
						</div>
					</div>
					<div class="flex items-center gap-1 px-2 py-1 sm:py-0 sm:opacity-0 group-hover:opacity-100 transition-opacity">
						<a
							href="/admin/runtime/agents/{agentId}/sessions/{s.session_id}"
							class="text-gray-500 hover:text-gray-300 text-xs px-1"
							title="Open"
						>open</a>
					</div>
				</div>
			{/each}
			{#if sessions.length === 0}
				<p class="text-gray-600 text-sm">No sessions yet.</p>
			{/if}
		</div>
	</div>

	{#if envs.length > 0}
		<div class="mt-6">
			<h2 class="text-sm font-medium text-gray-400 mb-2">Remote Environments</h2>
			<div class="flex flex-wrap gap-2">
				{#each envs as env}
					<div class="bg-gray-900 border border-gray-800 rounded px-3 py-1.5 text-xs flex items-center gap-2">
						<span class="w-1.5 h-1.5 rounded-full {env.status === 'connected' ? 'bg-green-500' : 'bg-gray-600'}"></span>
						<span class="font-mono">{env.name}</span>
						{#if env.os}
							<span class="text-gray-500">{env.os}/{env.arch}</span>
						{/if}
					</div>
				{/each}
			</div>
		</div>
	{/if}
{/if}
