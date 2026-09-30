<script lang="ts">
	import { onMount } from 'svelte';
	import { runtimeDebug } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';
	import { agentGroupRouterSessionId } from '$lib/router-session';
	import type { AgentGroup, IMConnect } from '$lib/types';

	type IMConnectRow = {
		group: AgentGroup;
		connect: IMConnect;
	};

	let agentGroups = $state<AgentGroup[]>([]);
	let connectRows = $state<IMConnectRow[]>([]);
	let routerSessionIds = $state<Record<string, string>>({});
	let error = $state('');
	let actionMsg = $state('');
	let actionOK = $state(false);
	let loading = $state(true);
	let actionConnectId = $state('');

	async function load() {
		loading = true;
		error = '';
		try {
			const groups = await runtimeDebug.listGroups($adminKey);
			const nextRouterSessionIds: Record<string, string> = {};
			await Promise.all(
				groups.map(async (group) => {
					if (!group.router_agent_id) return;
					try {
						nextRouterSessionIds[group.group_id] = await agentGroupRouterSessionId(group.router_agent_id, group.group_id);
					} catch {
						// The debug link is optional; keep the connects list usable.
					}
				})
			);
			const rowsByGroup = await Promise.all(
				groups.map(async (group) => {
					const connects = await runtimeDebug.listGroupIMConnects($adminKey, group.group_id);
					return connects.map((connect) => ({ group, connect }));
				})
			);
			agentGroups = groups;
			routerSessionIds = nextRouterSessionIds;
			connectRows = rowsByGroup.flat();
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		} finally {
			loading = false;
		}
	}

	onMount(() => {
		void load();
	});

	function groupLabel(group: AgentGroup): string {
		const details = [group.purpose].filter(Boolean).join(' · ');
		return details ? `${group.name} (${details})` : group.name;
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

	function statusClass(status: string): string {
		switch (status) {
			case 'connected':
			case 'configured':
				return 'border-emerald-800 text-emerald-300 bg-emerald-950/30';
			case 'pending OAuth':
				return 'border-amber-800 text-amber-300 bg-amber-950/30';
			case 'disabled':
				return 'border-gray-700 text-gray-400 bg-gray-950/30';
			case 'error':
				return 'border-red-800 text-red-300 bg-red-950/30';
			default:
				return 'border-gray-700 text-gray-300 bg-gray-950/30';
		}
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

	async function setConnectEnabled(row: IMConnectRow, enabled: boolean) {
		actionConnectId = row.connect.connect_id;
		actionMsg = '';
		actionOK = false;
		try {
			if (enabled) {
				await runtimeDebug.enableGroupIMConnect($adminKey, row.group.group_id, row.connect.connect_id);
				actionMsg = 'Connect enabled.';
			} else {
				await runtimeDebug.disableGroupIMConnect($adminKey, row.group.group_id, row.connect.connect_id);
				actionMsg = 'Connect disabled.';
			}
			actionOK = true;
			await load();
		} catch (e) {
			actionMsg = e instanceof Error ? e.message : String(e);
		} finally {
			actionConnectId = '';
		}
	}

	async function deleteConnect(row: IMConnectRow) {
		if (!confirm(`Delete ${providerLabel(row.connect.provider)} connect ${row.connect.connect_id}?`)) return;
		actionConnectId = row.connect.connect_id;
		actionMsg = '';
		actionOK = false;
		try {
			await runtimeDebug.deleteGroupIMConnect($adminKey, row.group.group_id, row.connect.connect_id);
			actionMsg = 'Connect deleted.';
			actionOK = true;
			await load();
		} catch (e) {
			actionMsg = e instanceof Error ? e.message : String(e);
		} finally {
			actionConnectId = '';
		}
	}
</script>

<div class="flex items-start justify-between gap-4 mb-6 flex-wrap">
	<div>
		<h1 class="text-xl font-bold">IM Integrations</h1>
		<p class="text-sm text-gray-500 mt-1">Group-scoped provider connects and router entry points.</p>
	</div>
	<button onclick={load} class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Refresh</button>
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}
{#if actionMsg}<p class="text-sm mb-4 {actionOK ? 'text-emerald-400' : 'text-red-400'}">{actionMsg}</p>{/if}

{#if loading}
	<p class="text-sm text-gray-500">Loading...</p>
{:else}
	<div class="grid gap-3 md:grid-cols-3 mb-6">
		<div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
			<div class="text-xs text-gray-500">Groups</div>
			<div class="text-2xl font-semibold mt-2">{agentGroups.length}</div>
		</div>
		<div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
			<div class="text-xs text-gray-500">IM connects</div>
			<div class="text-2xl font-semibold mt-2">{connectRows.length}</div>
		</div>
		<div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
			<div class="text-xs text-gray-500">Providers</div>
			<div class="text-2xl font-semibold mt-2">{new Set(connectRows.map((row) => row.connect.provider)).size}</div>
		</div>
	</div>

	<h2 class="text-sm font-medium text-gray-400 mb-3">Provider connects</h2>
	<div class="bg-gray-900 border border-gray-800 rounded-lg overflow-hidden">
		<table class="w-full text-sm">
			<thead>
				<tr class="text-left text-gray-500 border-b border-gray-800">
					<th class="px-4 py-3 font-medium">Group</th>
					<th class="px-4 py-3 font-medium">Provider</th>
					<th class="px-4 py-3 font-medium">Connect</th>
					<th class="px-4 py-3 font-medium">Identity</th>
					<th class="px-4 py-3 font-medium">Status</th>
					<th class="px-4 py-3 font-medium">Updated</th>
					<th class="px-4 py-3 font-medium">Debug</th>
					<th class="px-4 py-3 font-medium text-right">Actions</th>
				</tr>
			</thead>
			<tbody>
				{#each connectRows as row}
					{@const status = connectStatus(row.connect)}
					<tr class="border-b border-gray-800/60 last:border-0 align-top">
						<td class="px-4 py-3">
							<a href={`/admin/runtime/groups/${encodeURIComponent(row.group.group_id)}`} class="text-blue-400 hover:text-blue-300 hover:underline">{groupLabel(row.group)}</a>
							<div class="mt-1 font-mono text-[11px] text-gray-500">{row.group.group_id}</div>
						</td>
						<td class="px-4 py-3">
							<span class="inline-flex items-center rounded-full border border-gray-700 px-2 py-0.5 text-[11px] text-gray-300">{providerLabel(row.connect.provider)}</span>
						</td>
						<td class="px-4 py-3 font-mono text-xs text-gray-300">
							<div>{row.connect.connect_id}</div>
							{#if row.connect.app_id}
								<div class="mt-1 text-[11px] text-gray-500">app {row.connect.app_id}</div>
							{/if}
						</td>
						<td class="px-4 py-3 text-xs text-gray-300">
							<div>{connectIdentity(row.connect)}</div>
							{#if row.connect.last_error}
								<div class="mt-1 max-w-xs whitespace-pre-wrap text-[11px] text-red-300">{row.connect.last_error}</div>
							{/if}
						</td>
						<td class="px-4 py-3">
							<span class="inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] {statusClass(status)}">{status}</span>
						</td>
						<td class="px-4 py-3 text-xs text-gray-400 whitespace-nowrap">{formatTime(row.connect.updated_at || row.connect.created_at)}</td>
						<td class="px-4 py-3 text-xs">
							<div class="flex flex-col gap-1">
								<a href={`/admin/runtime/groups/${encodeURIComponent(row.group.group_id)}#router-messages`} class="text-blue-400 hover:text-blue-300 hover:underline">Router messages</a>
								{#if row.group.router_agent_id}
									<a href={`/admin/runtime/agents/${encodeURIComponent(row.group.router_agent_id)}`} class="text-blue-400 hover:text-blue-300 hover:underline">Router agent</a>
									<a href={`/admin/runtime/agents/${encodeURIComponent(row.group.router_agent_id)}/files/memory/`} class="text-blue-400 hover:text-blue-300 hover:underline">Router memory</a>
									{#if routerSessionIds[row.group.group_id]}
										<a href={`/admin/runtime/agents/${encodeURIComponent(row.group.router_agent_id)}/sessions/${encodeURIComponent(routerSessionIds[row.group.group_id])}`} class="text-blue-400 hover:text-blue-300 hover:underline">Router session</a>
									{/if}
								{:else}
									<span class="text-gray-600">No router agent</span>
								{/if}
							</div>
						</td>
						<td class="px-4 py-3 text-right">
							<div class="flex justify-end gap-2">
								{#if row.connect.disabled_at}
									<button
										onclick={() => setConnectEnabled(row, true)}
										disabled={actionConnectId === row.connect.connect_id}
										class="text-xs text-emerald-400 hover:text-emerald-300 disabled:opacity-50"
									>Enable</button>
								{:else}
									<button
										onclick={() => setConnectEnabled(row, false)}
										disabled={actionConnectId === row.connect.connect_id}
										class="text-xs text-gray-400 hover:text-gray-200 disabled:opacity-50"
									>Disable</button>
								{/if}
								<button
									onclick={() => deleteConnect(row)}
									disabled={actionConnectId === row.connect.connect_id}
									class="text-xs text-red-400 hover:text-red-300 disabled:opacity-50"
								>Delete</button>
							</div>
						</td>
					</tr>
				{/each}
				{#if connectRows.length === 0}
					<tr>
						<td colspan="8" class="px-4 py-6 text-center text-sm text-gray-600">No IM connects yet.</td>
					</tr>
				{/if}
			</tbody>
		</table>
	</div>
{/if}
