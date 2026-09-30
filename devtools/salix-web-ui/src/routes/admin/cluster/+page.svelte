<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { admin } from '$lib/api';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import type { ClusterStats, NodeInfo } from '$lib/types';
	import { onMount } from 'svelte';

	let stats = $state<ClusterStats | null>(null);
	let nodes = $state<NodeInfo[]>([]);
	let error = $state('');

	async function load() {
		try {
			[stats, nodes] = await Promise.all([
				admin.clusterStats($adminKey),
				admin.listNodes($adminKey)
			]);
		} catch (e) {
			error = String(e);
		}
	}

	onMount(() => {
		load();
		const interval = setInterval(load, 10000);
		return () => clearInterval(interval);
	});

	function relTime(ts: number) {
		const diff = Math.floor(Date.now() / 1000 - ts);
		if (diff < 60) return `${diff}s ago`;
		if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
		return `${Math.floor(diff / 3600)}h ago`;
	}
</script>

<h1 class="text-xl font-bold mb-6">Cluster</h1>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if stats}
	<div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<div class="text-2xl font-bold">{stats.active_nodes}</div>
			<div class="text-xs text-gray-500">Active Nodes</div>
		</div>
		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<div class="text-2xl font-bold">{stats.total_agents}</div>
			<div class="text-xs text-gray-500">Running Agents</div>
		</div>
		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<div class="text-2xl font-bold">{stats.total_capacity}</div>
			<div class="text-xs text-gray-500">Total Capacity</div>
		</div>
		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<div class="text-2xl font-bold">{stats.total_capacity ? Math.round(stats.total_agents / stats.total_capacity * 100) : 0}%</div>
			<div class="text-xs text-gray-500">Utilization</div>
		</div>
	</div>
{/if}

<h2 class="text-sm font-medium text-gray-400 mb-3">Nodes</h2>
<div class="overflow-x-auto">
<table class="w-full text-sm">
	<thead>
		<tr class="text-left text-gray-500 border-b border-gray-800">
			<th class="pb-2 font-medium">Node ID</th>
			<th class="pb-2 font-medium">Address</th>
			<th class="pb-2 font-medium">Agents</th>
			<th class="pb-2 font-medium">DB Heartbeat</th>
			<th class="pb-2 font-medium">Registry</th>
			<th class="pb-2 font-medium">Status</th>
		</tr>
	</thead>
	<tbody>
		{#each nodes as node}
			<tr class="border-b border-gray-800/50">
				<td class="py-2 font-mono text-xs">{node.node_id.slice(0, 8)}</td>
				<td class="py-2">{node.address}</td>
				<td class="py-2">{node.agent_count}/{node.max_agents}</td>
				<td class="py-2 text-gray-400">{relTime(node.heartbeat_at)}</td>
				<td class="py-2">
					{#if node.registry}
						<div class="flex items-center gap-2">
							<StatusBadge status={node.registry.status} />
							<span class="text-gray-400">{relTime(node.registry.last_seen_at)}</span>
						</div>
						<div class="text-xs text-gray-500">
							{node.registry.running_agents}/{node.registry.max_agents} agents
							{node.registry.fresh_for_handoff ? '' : ' - stale for handoff'}
						</div>
					{:else}
						<span class="text-gray-600">Not observed locally</span>
					{/if}
				</td>
				<td class="py-2"><StatusBadge status={node.status} /></td>
			</tr>
		{/each}
	</tbody>
</table>
</div>
