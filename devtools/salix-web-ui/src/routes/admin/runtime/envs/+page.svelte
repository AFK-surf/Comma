<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import type { Environment } from '$lib/types';
	import { onMount } from 'svelte';

	let envs = $state<Environment[]>([]);
	let error = $state('');

	async function load() {
		try {
			envs = await runtimeDebug.listEnvironments($adminKey);
		} catch (e) {
			error = String(e);
		}
	}

	onMount(() => {
		load();
		const interval = setInterval(load, 5000);
		return () => clearInterval(interval);
	});

	async function disconnectDevice(groupId: string, deviceId: string) {
		if (!confirm("Disconnect this device's current connector?")) return;
		try {
			await runtimeDebug.deleteEnvironment($adminKey, groupId, deviceId);
			load();
		} catch (e) {
			error = String(e);
		}
	}

	function relTime(ts: number) {
		const diff = Math.floor(Date.now() / 1000 - ts);
		if (diff < 60) return `${diff}s ago`;
		if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
		return `${Math.floor(diff / 3600)}h ago`;
	}
</script>

<div class="flex items-center justify-between mb-6">
	<h1 class="text-xl font-bold">Devices</h1>
	<div class="text-sm text-gray-500">{envs.length} device{envs.length !== 1 ? 's' : ''}</div>
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if envs.length === 0}
	<div class="text-gray-500 text-sm">
		No devices yet. Connect a device to make its environments available.
	</div>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full text-sm">
			<thead>
				<tr class="text-left text-gray-500 border-b border-gray-800">
					<th class="pb-2 font-normal">Name</th>
					<th class="pb-2 font-normal">OS / Arch</th>
					<th class="pb-2 font-normal">Status</th>
					<th class="pb-2 font-normal">Connected</th>
					<th class="pb-2 font-normal">Node</th>
					<th class="pb-2 font-normal"></th>
				</tr>
			</thead>
			<tbody>
				{#each envs as env}
					<tr class="border-b border-gray-800/50 hover:bg-gray-900/50">
						<td class="py-2">
							<div class="font-mono text-xs">{env.name}</div>
							<div class="text-[10px] text-gray-600 font-mono">{env.device_id.slice(0, 12)}</div>
						</td>
						<td class="py-2 text-gray-400">
							{#if env.os || env.arch}
								{env.os}{env.arch ? `/${env.arch}` : ''}
							{:else}
								<span class="text-gray-600">-</span>
							{/if}
						</td>
						<td class="py-2">
							<StatusBadge status={env.status} />
						</td>
						<td class="py-2 text-gray-400">
							{relTime(env.connected_at)}
							{#if env.disconnected_at}
								<div class="text-[10px] text-gray-600">disconnected {relTime(env.disconnected_at)}</div>
							{/if}
						</td>
						<td class="py-2 font-mono text-xs text-gray-500">{env.node_id.slice(0, 8)}</td>
						<td class="py-2 text-right">
							{#if env.status === 'connected'}
								<button
									onclick={() => disconnectDevice(env.group_id, env.device_id)}
									class="text-xs text-red-400 hover:text-red-300"
								>Disconnect</button>
							{/if}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}
