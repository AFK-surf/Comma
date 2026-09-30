<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import type { Session } from '$lib/types';
	import { onMount } from 'svelte';

	let sessionInfo = $state<Session | null>(null);
	let error = $state('');

	const agentId: string = $page.params.id!;
	const sessionId: string = $page.params.sessionId!;

	onMount(() => {
		runtimeDebug.getSession($adminKey, agentId, sessionId)
			.then((session) => {
				sessionInfo = session;
			})
			.catch((e) => {
				error = String(e);
			});
	});
</script>

<div class="space-y-4">
	<a href="/admin/runtime/agents/{agentId}" class="text-sm text-gray-500 hover:text-gray-300">&larr; Agent</a>

	<div class="bg-gray-900 border border-gray-800 rounded p-4 max-w-2xl">
		<div class="flex items-center gap-2 flex-wrap mb-2">
			<h1 class="text-base md:text-lg font-bold font-mono">{agentId.slice(0, 12)}</h1>
			<span class="text-sm text-gray-300">{sessionInfo?.name || sessionId.slice(0, 8)}</span>
			<span class="text-[10px] uppercase text-emerald-400/80 border border-emerald-500/30 rounded px-1.5 py-0.5">native IM session</span>
		</div>

		{#if error}
			<p class="text-red-400 text-sm">{error}</p>
		{:else}
			<p class="text-sm text-gray-400">
				This legacy native IM session view has been retired.
			</p>
		{/if}

		<div class="flex gap-2 mt-4 flex-wrap">
			<a href="/admin/runtime/agents/{agentId}" class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Back to agent</a>
		</div>
	</div>
</div>
