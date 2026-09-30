<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/stores';
	import { e2eReports, resolveBackendUrl } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';

	let src = $state('');
	let loading = $state(false);
	let error = $state('');

	const runId = $derived($page.params.runId ?? '');
	const attempt = $derived($page.params.attempt ?? '');
	const target = $derived($page.params.target ?? '');

	async function load() {
		if (!$adminKey) return;
		loading = true;
		error = '';
		try {
			const session = await e2eReports.createReportSession($adminKey, runId, attempt, target);
			src = resolveBackendUrl(session.url);
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		} finally {
			loading = false;
		}
	}

	onMount(load);
</script>

<div class="mb-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
	<div>
		<h1 class="text-xl font-semibold">{target} report</h1>
		<p class="mt-1 text-sm text-gray-500">Run {runId}/{attempt}</p>
	</div>
	<div class="flex gap-2">
		<a href={`/e2e-reports/runs/${runId}/${attempt}`} class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">
			Back
		</a>
		{#if src}
			<a href={src} target="_blank" rel="noreferrer" class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">
				New tab
			</a>
		{/if}
	</div>
</div>

{#if error}
	<div class="rounded border border-red-900 bg-red-950/40 p-3 text-sm text-red-200">{error}</div>
{:else if loading}
	<div class="rounded border border-gray-800 bg-gray-900 p-4 text-sm text-gray-500">Creating report session...</div>
{:else if src}
	<iframe
		title="Playwright HTML report"
		src={src}
		class="h-[calc(100vh-9rem)] w-full rounded border border-gray-800 bg-white"
	></iframe>
{/if}
