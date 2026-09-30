<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import { goto } from '$app/navigation';
	import { agentGroupRouterSessionId } from '$lib/router-session';
	import type { AgentGroup, IMConnect, IMStoredMessage, OAuthBindingDetail, OAuthProviderApp } from '$lib/types';
	import { KNOWN_OAUTH_PROVIDERS, oauthProviderLabel, defaultOAuthScopes } from '$lib/oauth';
	import { onMount } from 'svelte';

	let group = $state<AgentGroup | null>(null);
	let error = $state('');
	let oauthError = $state('');
	let oauthMessage = $state('');
	let bindings = $state<OAuthBindingDetail[]>([]);
	let providerApps = $state<OAuthProviderApp[]>([]);
	let imConnects = $state<IMConnect[]>([]);
	let routerMessages = $state<IMStoredMessage[]>([]);
	let routerSessionId = $state('');
	let loadingBindings = $state(true);
	let loadingRouter = $state(true);
	let connectProvider = $state<string>('github');
	let connectAlias = $state('');
	let connectScopes = $state('');
	let connecting = $state(false);
	let routerError = $state('');

	const inputClass =
		'w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500';

	function appConfigured(p: string): boolean {
		const app = providerApps.find((a) => a.provider === p);
		return !!app?.client_id && !!app?.client_secret_configured;
	}

	async function loadOAuth() {
		if (!group) return;
		loadingBindings = true;
		oauthError = '';
		try {
			const [b, apps] = await Promise.all([
				runtimeDebug.listGroupOAuthBindings($adminKey, group.group_id),
				runtimeDebug.listOAuthProviderApps($adminKey),
			]);
			bindings = b;
			providerApps = apps;
		} catch (e) {
			oauthError = String(e);
		} finally {
			loadingBindings = false;
		}
	}

	async function loadRouterDebug() {
		if (!group) return;
		loadingRouter = true;
		routerError = '';
		try {
			const [connects, messages] = await Promise.all([
				runtimeDebug.listGroupIMConnects($adminKey, group.group_id),
				runtimeDebug.listGroupRouterMessages($adminKey, group.group_id),
			]);
			imConnects = connects;
			routerMessages = messages;
			routerSessionId = '';
			if (group.router_agent_id) {
				try {
					routerSessionId = await agentGroupRouterSessionId(group.router_agent_id, group.group_id);
				} catch {
					// Keep the rest of the group IM debug view usable.
				}
			}
		} catch (e) {
			routerError = String(e);
		} finally {
			loadingRouter = false;
		}
	}

	onMount(async () => {
		try {
			group = await runtimeDebug.getGroup($adminKey, $page.params.id!);
			connectScopes = defaultOAuthScopes(connectProvider);
			await Promise.all([loadOAuth(), loadRouterDebug()]);
		} catch (e) {
			error = String(e);
		}
	});

	function onProviderChange() {
		connectScopes = defaultOAuthScopes(connectProvider);
	}

	async function deleteGroup() {
		if (!confirm('Delete this group?')) return;
		try {
			await runtimeDebug.deleteGroup($adminKey, $page.params.id!);
			goto('/admin/runtime/groups');
		} catch (e) {
			error = String(e);
		}
	}

	async function startConnect() {
		if (!group) return;
		const alias = connectAlias.trim();
		if (!alias) {
			oauthError = 'Alias is required.';
			return;
		}
		const scopes = connectScopes
			.split(/[\s,]+/)
			.map((s) => s.trim())
			.filter(Boolean);
		oauthError = '';
		oauthMessage = '';
		connecting = true;
		try {
			const redirectAfter = window.location.pathname + window.location.search;
			const resp = await runtimeDebug.startOAuthAuthorization($adminKey, group.group_id, connectProvider, {
				alias,
				scopes,
				redirect_after: redirectAfter,
			});
			window.location.href = resp.authorization_url;
		} catch (e) {
			oauthError = String(e);
			connecting = false;
		}
	}

	async function renameBinding(b: OAuthBindingDetail) {
		const newAlias = prompt(`Rename ${b.provider} alias`, b.alias);
		if (!newAlias || newAlias.trim() === b.alias) return;
		try {
			await runtimeDebug.updateGroupOAuthBinding($adminKey, b.group_id, b.binding_id, {
				alias: newAlias.trim(),
			});
			oauthMessage = 'Alias updated.';
			await loadOAuth();
		} catch (e) {
			oauthError = String(e);
		}
	}

	async function revokeBinding(b: OAuthBindingDetail) {
		if (!confirm(`Revoke ${b.provider}/${b.alias}? Agents in this group will stop being able to use this credential.`)) return;
		try {
			await runtimeDebug.deleteGroupOAuthBinding($adminKey, b.group_id, b.binding_id);
			oauthMessage = `Revoked ${b.provider}/${b.alias}.`;
			await loadOAuth();
		} catch (e) {
			oauthError = String(e);
		}
	}

	function providerLabel(provider: string): string {
		switch (provider) {
			case 'slack':
				return 'Slack';
			case 'telegram':
				return 'Telegram';
			case 'wechat':
				return 'WeChat';
			case 'feishu':
				return 'Feishu';
			case 'internal':
				return 'Internal';
			default:
				return provider || '-';
		}
	}

	function connectStatus(connect: IMConnect): string {
		if (connect.disabled_at) return 'disabled';
		if (connect.status) return connect.status;
		if (connect.workspace_id || connect.connected_at || connect.oauth_completed_at) return 'connected';
		if (connect.oauth_url) return 'pending OAuth';
		return 'configured';
	}

	function connectIdentity(connect: IMConnect): string {
		return (
			connect.workspace_name ||
			connect.workspace_id ||
			connect.bot_username ||
			connect.bot_user_id ||
			connect.app_name ||
			connect.app_id ||
			connect.tenant_key ||
			'-'
		);
	}

	function timestampMs(ts?: number): number | null {
		if (!ts) return null;
		return ts > 10_000_000_000 ? ts : ts * 1000;
	}

	function formatTime(ts?: number): string {
		const ms = timestampMs(ts);
		if (!ms) return '-';
		return new Date(ms).toLocaleString();
	}

	function safeJson(value: unknown): string {
		try {
			return JSON.stringify(value);
		} catch {
			return String(value);
		}
	}

	function contentPreview(content: unknown): string {
		if (typeof content === 'string') {
			const trimmed = content.trim();
			if (!trimmed) return '-';
			try {
				const parsed = JSON.parse(trimmed);
				if (parsed !== trimmed) return contentPreview(parsed);
			} catch {
				// Plain text.
			}
			return trimmed;
		}
		if (Array.isArray(content)) {
			const text = content
				.map((block) => {
					if (typeof block === 'string') return block;
					if (block && typeof block === 'object') {
						const record = block as Record<string, unknown>;
						if (typeof record.text === 'string') return record.text;
						if (typeof record.type === 'string') return `[${record.type}]`;
					}
					return safeJson(block);
				})
				.filter(Boolean)
				.join('\n');
			return text || '-';
		}
		if (content && typeof content === 'object') {
			const record = content as Record<string, unknown>;
			if (typeof record.text === 'string') return record.text;
			return safeJson(content);
		}
		return content == null ? '-' : String(content);
	}

	function truncate(value: string, max = 220): string {
		return value.length > max ? `${value.slice(0, max)}...` : value;
	}

	function actorLabel(message: IMStoredMessage): string {
		if (message.agent_name) return message.agent_name;
		if (message.agent_id) return `agent ${message.agent_id.slice(0, 8)}`;
		if (message.user_id) return message.user_id;
		return message.actor_type || message.participant_id || '-';
	}
</script>

<a href="/admin/runtime/groups" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Groups</a>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if group}
	<div class="flex flex-col sm:flex-row sm:items-center justify-between mb-6 gap-3">
		<h1 class="text-xl font-bold">{group.name}</h1>
		<div class="flex items-center gap-2">
			<a href="/admin/runtime/groups/{group.group_id}/conversations" class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-sm">Conversations</a>
			<button onclick={deleteGroup} class="bg-red-600/20 text-red-400 hover:bg-red-600/30 px-3 py-1.5 rounded text-sm">Delete</button>
		</div>
	</div>

	<div class="space-y-4 max-w-lg">
		<div>
			<div class="block text-sm text-gray-400 mb-1">Group ID</div>
			<div class="w-full bg-gray-900 border border-gray-800 rounded px-3 py-2 text-sm font-mono">{group.group_id}</div>
		</div>
		<div>
			<div class="block text-sm text-gray-400 mb-1">Purpose</div>
			<div class="w-full bg-gray-900 border border-gray-800 rounded px-3 py-2 text-sm">{group.purpose || '-'}</div>
		</div>
		<div>
			<div class="block text-sm text-gray-400 mb-1">Created</div>
			<div class="w-full bg-gray-900 border border-gray-800 rounded px-3 py-2 text-sm">{new Date(group.created_at * 1000).toLocaleString()}</div>
		</div>
	</div>

	<section id="router-messages" class="mt-10 max-w-5xl">
		<div class="flex items-center justify-between gap-3 mb-3">
			<h2 class="text-lg font-bold">Runtime IM</h2>
			<button onclick={loadRouterDebug} class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Refresh</button>
		</div>

		{#if routerError}<p class="text-red-400 text-sm mb-3">{routerError}</p>{/if}

		{#if loadingRouter}
			<p class="text-gray-500 text-sm">Loading router data...</p>
		{:else}
			<div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-6">
				<div class="bg-gray-900 border border-gray-800 rounded p-3">
					<div class="text-gray-500 text-xs mb-1">Router agent</div>
					{#if group.router_agent_id}
						<a href="/admin/runtime/agents/{group.router_agent_id}" class="font-mono text-xs text-blue-400 hover:underline break-all">{group.router_agent_id}</a>
					{:else}
						<div class="text-sm text-gray-500">Not configured</div>
					{/if}
				</div>
				<div class="bg-gray-900 border border-gray-800 rounded p-3">
					<div class="text-gray-500 text-xs mb-1">Router session</div>
					{#if group.router_agent_id && routerSessionId}
						<a href="/admin/runtime/agents/{group.router_agent_id}/sessions/{routerSessionId}" class="font-mono text-xs text-blue-400 hover:underline break-all">{routerSessionId}</a>
					{:else}
						<div class="text-sm text-gray-500">-</div>
					{/if}
				</div>
				<div class="bg-gray-900 border border-gray-800 rounded p-3">
					<div class="text-gray-500 text-xs mb-1">Router memory</div>
					{#if group.router_agent_id}
						<a href="/admin/runtime/agents/{group.router_agent_id}/files/memory/" class="text-sm text-blue-400 hover:underline">Open agent memory</a>
					{:else}
						<div class="text-sm text-gray-500">-</div>
					{/if}
				</div>
			</div>

			<div class="mb-6">
				<h3 class="text-sm font-medium text-gray-400 mb-3">IM connects</h3>
				<div class="border border-gray-800 rounded overflow-x-auto">
					<table class="w-full text-sm">
						<thead class="text-xs uppercase text-gray-500 border-b border-gray-800">
							<tr>
								<th class="text-left px-3 py-2">Provider</th>
								<th class="text-left px-3 py-2">Connect</th>
								<th class="text-left px-3 py-2">Identity</th>
								<th class="text-left px-3 py-2">Status</th>
								<th class="text-left px-3 py-2">Updated</th>
							</tr>
						</thead>
						<tbody>
							{#each imConnects as connect}
								<tr class="border-t border-gray-800/60">
									<td class="px-3 py-2">{providerLabel(connect.provider)}</td>
									<td class="px-3 py-2 font-mono text-xs">{connect.connect_id}</td>
									<td class="px-3 py-2 text-xs text-gray-300">
										<div>{connectIdentity(connect)}</div>
										{#if connect.last_error}
											<div class="mt-1 max-w-lg whitespace-pre-wrap text-[11px] text-red-300">{connect.last_error}</div>
										{/if}
									</td>
									<td class="px-3 py-2 text-xs">{connectStatus(connect)}</td>
									<td class="px-3 py-2 text-xs text-gray-400 whitespace-nowrap">{formatTime(connect.updated_at || connect.created_at)}</td>
								</tr>
							{/each}
							{#if imConnects.length === 0}
								<tr><td colspan="5" class="px-3 py-6 text-center text-sm text-gray-600">No IM connects for this group.</td></tr>
							{/if}
						</tbody>
					</table>
				</div>
			</div>

			<div>
				<h3 class="text-sm font-medium text-gray-400 mb-3">Router messages</h3>
				<div class="border border-gray-800 rounded overflow-x-auto">
					<table class="w-full text-sm">
						<thead class="text-xs uppercase text-gray-500 border-b border-gray-800">
							<tr>
								<th class="text-left px-3 py-2">Actor</th>
								<th class="text-left px-3 py-2">Kind</th>
								<th class="text-left px-3 py-2">Content</th>
								<th class="text-left px-3 py-2">Created</th>
							</tr>
						</thead>
						<tbody>
							{#each routerMessages as message}
								<tr class="border-t border-gray-800/60 align-top">
									<td class="px-3 py-2 text-xs text-gray-300">{actorLabel(message)}</td>
									<td class="px-3 py-2 font-mono text-xs text-gray-400">{message.kind || '-'}</td>
									<td class="px-3 py-2 text-xs text-gray-200 whitespace-pre-wrap min-w-[22rem]">{truncate(contentPreview(message.content))}</td>
									<td class="px-3 py-2 text-xs text-gray-400 whitespace-nowrap">{formatTime(message.created_at)}</td>
								</tr>
							{/each}
							{#if routerMessages.length === 0}
								<tr><td colspan="4" class="px-3 py-6 text-center text-sm text-gray-600">No router messages yet.</td></tr>
							{/if}
						</tbody>
					</table>
				</div>
			</div>
		{/if}
	</section>

	<section class="mt-10 max-w-3xl">
		<div class="flex items-center justify-between mb-3">
			<h2 class="text-lg font-bold">OAuth credentials</h2>
			<a href="/admin/runtime/oauth" class="text-xs text-gray-400 hover:text-gray-200">Provider apps &rarr;</a>
		</div>
		<p class="text-sm text-gray-400 mb-4">
			Connected accounts available to agents in this group. Reference them from
			<code class="text-gray-300">Exec.credential_env</code> as <code class="text-gray-300">{`[{env_var, provider, alias, value}]`}</code>.
		</p>

		{#if oauthError}<p class="text-red-400 text-sm mb-3">{oauthError}</p>{/if}
		{#if oauthMessage}<p class="text-emerald-400 text-sm mb-3">{oauthMessage}</p>{/if}

		{#if loadingBindings}
			<p class="text-gray-500">Loading bindings...</p>
		{:else}
			{#if bindings.length === 0}
				<p class="text-sm text-gray-500 mb-4">No connected accounts yet.</p>
			{:else}
				<div class="border border-gray-800 rounded mb-6">
					<table class="w-full text-sm">
						<thead class="text-xs uppercase text-gray-500 border-b border-gray-800">
							<tr>
								<th class="text-left px-3 py-2">Provider</th>
								<th class="text-left px-3 py-2">Alias</th>
								<th class="text-left px-3 py-2">Account</th>
								<th class="text-left px-3 py-2">Scopes</th>
								<th class="text-left px-3 py-2">Status</th>
								<th class="text-right px-3 py-2"></th>
							</tr>
						</thead>
						<tbody>
							{#each bindings as b}
								<tr class="border-t border-gray-800/60">
									<td class="px-3 py-2 font-mono">{b.provider}</td>
									<td class="px-3 py-2 font-mono">{b.alias}</td>
									<td class="px-3 py-2">{b.provider_account_name || b.provider_account_id || '-'}</td>
									<td class="px-3 py-2 text-xs text-gray-400">
										{#if b.scopes && b.scopes.length > 0}{b.scopes.join(', ')}{:else}-{/if}
									</td>
									<td class="px-3 py-2 text-xs">
										<span class="px-1.5 py-0.5 rounded {b.status === 'active' ? 'bg-emerald-600/20 text-emerald-300' : 'bg-amber-600/20 text-amber-300'}">{b.status}</span>
									</td>
									<td class="px-3 py-2 text-right space-x-2">
										<button onclick={() => renameBinding(b)} class="text-xs text-gray-400 hover:text-gray-200">Rename</button>
										<button onclick={() => revokeBinding(b)} class="text-xs text-red-400 hover:text-red-300">Revoke</button>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}

			<div class="border border-gray-800 rounded p-4 bg-gray-900/50">
				<h3 class="text-sm font-semibold mb-3">Connect new account</h3>
				<div class="grid gap-3 sm:grid-cols-3">
					<label class="block text-xs text-gray-400">Provider
						<select
							class={inputClass}
							bind:value={connectProvider}
							onchange={onProviderChange}
						>
							{#each KNOWN_OAUTH_PROVIDERS as p}
								<option value={p} disabled={!appConfigured(p)}>
									{oauthProviderLabel(p)}{!appConfigured(p) ? ' (not configured)' : ''}
								</option>
							{/each}
						</select>
					</label>
					<label class="block text-xs text-gray-400">Alias
						<input
							type="text"
							class={inputClass}
							bind:value={connectAlias}
							placeholder="e.g. work"
							autocomplete="off"
						/>
					</label>
					<label class="block text-xs text-gray-400">Scopes
						<input
							type="text"
							class={inputClass}
							bind:value={connectScopes}
							placeholder="space-separated"
							autocomplete="off"
						/>
					</label>
				</div>
				<div class="mt-4 flex items-center justify-between">
					<p class="text-xs text-gray-500">
						{#if !appConfigured(connectProvider)}
							The {oauthProviderLabel(connectProvider)} OAuth app is not configured for this runtimeDebug.
							<a href="/admin/runtime/oauth" class="underline hover:text-gray-300">Configure it</a>
							before connecting.
						{:else}
							You will be redirected to {oauthProviderLabel(connectProvider)} to authorize.
						{/if}
					</p>
					<button
						type="button"
						onclick={startConnect}
						disabled={connecting || !appConfigured(connectProvider)}
						class="bg-blue-600 hover:bg-blue-500 disabled:opacity-40 px-3 py-1.5 rounded text-sm"
					>
						{connecting ? 'Redirecting...' : 'Connect'}
					</button>
				</div>
			</div>
		{/if}
	</section>
{/if}
