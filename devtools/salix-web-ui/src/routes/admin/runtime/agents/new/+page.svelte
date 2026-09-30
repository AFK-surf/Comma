<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import { goto } from '$app/navigation';
	import type { AgentGroup, AgentTemplate } from '$lib/types';
	import { onMount } from 'svelte';

	let groups = $state<AgentGroup[]>([]);
	let templates = $state<AgentTemplate[]>([]);
	let selectedGroup = $state('');
	let selectedTemplate = $state('');
	let forkFrom = $state('');
	let spritesEnabled = $state(false);
	let error = $state('');

	onMount(async () => {
		try {
			const [nextGroups, nextTemplates] = await Promise.all([
				runtimeDebug.listGroups($adminKey),
				runtimeDebug.listTemplates($adminKey),
			]);
			groups = nextGroups;
			templates = nextTemplates;
			if (groups.length > 0) selectedGroup = groups[0].group_id;
			if (templates.length > 0) selectedTemplate = templates[0].template_id;
		} catch (e) {
			error = String(e);
		}
	});

	async function create() {
		if (!selectedGroup || !selectedTemplate) return;
		try {
			const agent = await runtimeDebug.createAgent(
				$adminKey,
				selectedGroup,
				selectedTemplate,
				forkFrom || undefined,
				spritesEnabled ? { runtime_debug: { sprites_enabled: true } } : undefined,
			);
			goto(`/admin/runtime/agents/${agent.agent_id}`);
		} catch (e) {
			error = String(e);
		}
	}
</script>

<a href="/admin/runtime/agents" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Agents</a>
<h1 class="text-xl font-bold mb-6">New Agent</h1>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

<div class="max-w-lg space-y-4">
	<div>
		<label for="agent-group" class="block text-sm text-gray-400 mb-1">Agent Group</label>
		<select id="agent-group" bind:value={selectedGroup} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500">
			{#each groups as g}
				<option value={g.group_id}>{g.name}</option>
			{/each}
		</select>
	</div>
	<div>
		<label for="agent-template" class="block text-sm text-gray-400 mb-1">Template</label>
		<select id="agent-template" bind:value={selectedTemplate} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500">
			{#each templates as t}
				<option value={t.template_id}>{t.name}</option>
			{/each}
		</select>
	</div>
	<div>
		<label for="fork-from" class="block text-sm text-gray-400 mb-1">Fork from Agent ID (optional)</label>
		<input id="fork-from" bind:value={forkFrom} placeholder="agent_id to fork from" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono" />
	</div>
	<div>
		<label class="flex items-center gap-2 text-sm text-gray-200">
			<input type="checkbox" bind:checked={spritesEnabled} class="accent-blue-500" />
			<span>Cloud VM</span>
		</label>
		<p class="text-[11px] text-gray-500 mt-1">
			Provision a managed Sprites cloud VM exposed to the agent as the <span class="font-mono">cloud-vm</span> environment. Requires Sprites credentials in the tenant config.
		</p>
	</div>
	<button onclick={create} disabled={!selectedGroup || !selectedTemplate} class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-4 py-2 rounded text-sm">Create Agent</button>
</div>
