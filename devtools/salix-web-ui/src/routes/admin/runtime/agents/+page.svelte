<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import { projectAgentActivityStatuses } from '$lib/agent-status';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import type { Agent, AgentActivity, AgentGroup, AgentTemplate } from '$lib/types';
	import { onMount } from 'svelte';

	let agents = $state<Agent[]>([]);
	let agentActivities = $state<AgentActivity[]>([]);
	let agentGroups = $state<AgentGroup[]>([]);
	let templates = $state<AgentTemplate[]>([]);
	let statusFilter = $state('');
	let agentGroupFilter = $state('');
	let agentsError = $state('');
	let agentGroupsError = $state('');
	let templatesError = $state('');

	const statuses = ['', 'queued', 'running', 'paused', 'waiting', 'completed', 'failed', 'cancelled'];
	const selectClass = 'w-full sm:w-80 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500';

	const sortedAgentGroups = $derived(
		[...agentGroups].sort((a, b) => a.name.localeCompare(b.name) || a.group_id.localeCompare(b.group_id))
	);
	const visibleAgents = $derived(
		projectAgentActivityStatuses(agents, agentActivities).filter(
			(agent) => !statusFilter || agent.status === statusFilter
		)
	);
	function formatAgentGroupLabel(group: AgentGroup): string {
		return `${group.name}(${group.group_id.slice(0, 7)})`;
	}

	function displayAgentGroup(groupId: string): string {
		const group = agentGroups.find((candidate) => candidate.group_id === groupId);
		return group ? formatAgentGroupLabel(group) : `unknown(${groupId.slice(0, 7)})`;
	}

	function hasAgentGroup(groupId: string): boolean {
		return !!groupId && agentGroups.some((candidate) => candidate.group_id === groupId);
	}

	function displayTemplate(templateId?: string): string {
		if (!templateId) return '-';
		const template = templates.find((candidate) => candidate.template_id === templateId);
		if (!template) return `unknown(${templateId.slice(0, 7)})`;
		return template.model ? `${template.name} (${template.model})` : template.name;
	}

	async function loadAgents() {
		try {
			[agents, agentActivities] = await Promise.all([
				runtimeDebug.listAgents($adminKey, agentGroupFilter || undefined),
				runtimeDebug.listAgentActivities($adminKey)
			]);
			agentsError = '';
		} catch (e) {
			agentsError = String(e);
		}
	}

	async function loadAgentGroups() {
		try {
			agentGroups = await runtimeDebug.listGroups($adminKey);
			agentGroupsError = '';
		} catch (e) {
			agentGroupsError = String(e);
		}
	}

	async function loadTemplates() {
		try {
			templates = await runtimeDebug.listTemplates($adminKey);
			templatesError = '';
		} catch (e) {
			templatesError = String(e);
		}
	}

	function applyStatusFilter(value: string) {
		statusFilter = value;
	}

	async function applyAgentGroupFilter(value: string) {
		agentGroupFilter = value;
		await loadAgents();
	}

	onMount(() => {
		void loadAgentGroups();
		void loadTemplates();
		void loadAgents();
		const interval = setInterval(loadAgents, 5000);
		return () => clearInterval(interval);
	});
</script>

<div class="flex items-center justify-between mb-6">
	<h1 class="text-xl font-bold">Agents</h1>
	<a href="/admin/runtime/agents/new" class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">New Agent</a>
</div>

{#if agentsError || agentGroupsError || templatesError}
	<p class="text-red-400 text-sm mb-4">{agentsError || agentGroupsError || templatesError}</p>
{/if}

<div class="flex flex-col gap-3 mb-4">
	<div class="flex gap-1 overflow-x-auto">
		{#each statuses as s}
			<button
				onclick={() => applyStatusFilter(s)}
				class="px-2.5 py-1 rounded text-xs {statusFilter === s ? 'bg-gray-700 text-white' : 'text-gray-500 hover:text-gray-300'}"
			>
				{s || 'all'}
			</button>
		{/each}
	</div>

	<div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
		<label for="agent-group-filter" class="text-xs text-gray-500">Agent group</label>
		<select
			id="agent-group-filter"
			value={agentGroupFilter}
			onchange={(event) => applyAgentGroupFilter((event.currentTarget as HTMLSelectElement).value)}
			class={selectClass}
		>
			<option value="">All agent groups</option>
			{#if agentGroupFilter && !hasAgentGroup(agentGroupFilter)}
				<option value={agentGroupFilter}>unknown({agentGroupFilter.slice(0, 7)})</option>
			{/if}
			{#each sortedAgentGroups as group}
				<option value={group.group_id}>{formatAgentGroupLabel(group)}</option>
			{/each}
		</select>
	</div>
</div>

<div class="overflow-x-auto">
<table class="w-full text-sm">
	<thead>
		<tr class="text-left text-gray-500 border-b border-gray-800">
			<th class="pb-2 font-medium">Agent ID</th>
			<th class="pb-2 font-medium">Status</th>
			<th class="pb-2 font-medium">Group</th>
			<th class="pb-2 font-medium">Template</th>
			<th class="pb-2 font-medium">Created</th>
		</tr>
	</thead>
	<tbody>
		{#if visibleAgents.length === 0}
			<tr>
				<td colspan="5" class="py-6 text-sm text-center text-gray-500">No agents found for the current filters.</td>
			</tr>
		{/if}
		{#each visibleAgents as a}
			<tr class="border-b border-gray-800/50 hover:bg-gray-900/50">
				<td class="py-2">
					<a href="/admin/runtime/agents/{a.agent_id}" class="text-blue-400 hover:underline font-mono text-xs">{a.agent_id.slice(0, 12)}</a>
				</td>
				<td class="py-2"><StatusBadge status={a.status} /></td>
				<td class="py-2 text-gray-400 text-xs break-all">{a.group_id ? displayAgentGroup(a.group_id) : '-'}</td>
				<td class="py-2 text-gray-300 text-xs break-all">{displayTemplate(a.template_id)}</td>
				<td class="py-2 text-gray-400">{new Date(a.created_at * 1000).toLocaleString()}</td>
			</tr>
		{/each}
	</tbody>
</table>
</div>
