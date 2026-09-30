<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import type { AgentGroup } from '$lib/types';
	import { onMount } from 'svelte';

	let groups = $state<AgentGroup[]>([]);
	let error = $state('');

	onMount(async () => {
		try {
			groups = await runtimeDebug.listGroups($adminKey);
		} catch (e) {
			error = String(e);
		}
	});
</script>

<div class="flex items-center justify-between mb-6">
	<h1 class="text-xl font-bold">Agent Groups</h1>
	<a href="/admin/runtime/groups/new" class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">New Group</a>
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

<div class="overflow-x-auto">
<table class="w-full text-sm">
	<thead>
		<tr class="text-left text-gray-500 border-b border-gray-800">
			<th class="pb-2 font-medium">Name</th>
			<th class="pb-2 font-medium">Purpose</th>
			<th class="pb-2 font-medium">Group ID</th>
		</tr>
	</thead>
	<tbody>
		{#each groups as group}
			<tr class="border-b border-gray-800/50 hover:bg-gray-900/50">
				<td class="py-2"><a href="/admin/runtime/groups/{group.group_id}" class="text-blue-400 hover:underline">{group.name}</a></td>
				<td class="py-2 text-gray-400">{group.purpose || '-'}</td>
				<td class="py-2 text-gray-400 font-mono text-xs">{group.group_id}</td>
			</tr>
		{/each}
	</tbody>
</table>
</div>
