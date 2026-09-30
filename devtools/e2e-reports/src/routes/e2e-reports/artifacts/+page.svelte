<script lang="ts">
	import { onMount } from 'svelte';
	import { e2eReports } from '$lib/api';
	import { formatBytes } from '$lib/format';
	import { adminKey } from '$lib/stores/auth';
	import type { ArtifactRecord, CleanupPreview } from '$lib/types';

	let artifacts = $state<ArtifactRecord[]>([]);
	let selected = $state<Record<string, boolean>>({});
	let preview = $state<CleanupPreview | null>(null);
	let loading = $state(false);
	let error = $state('');
	let status = $state('');
	let target = $state('');
	let branch = $state('');
	let pr = $state('');
	let before = $state('');
	let limit = $state(200);

	function filters() {
		return { status, target, branch, pr, before, limit };
	}

	function selectedRuns() {
		const unique = new Map<string, { runId: string; attempt: string }>();
		for (const [key, checked] of Object.entries(selected)) {
			if (!checked) continue;
			const [runId, attempt] = key.split(':');
			unique.set(key, { runId, attempt });
		}
		return [...unique.values()];
	}

	function cleanupBody(confirm = false) {
		const runs = selectedRuns();
		if (runs.length > 0) return { confirm, runs };
		const activeFilters = Boolean(status || target || branch || pr || before);
		return activeFilters ? { ...filters(), confirm } : { retention: true, limit, confirm };
	}

	async function load() {
		if (!$adminKey) return;
		loading = true;
		error = '';
		preview = null;
		try {
			artifacts = (await e2eReports.listArtifacts($adminKey, filters())).artifacts;
			selected = {};
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		} finally {
			loading = false;
		}
	}

	async function runPreview() {
		if (!$adminKey) return;
		error = '';
		try {
			preview = await e2eReports.cleanupPreview($adminKey, cleanupBody(false));
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		}
	}

	async function confirmCleanup() {
		if (!$adminKey) return;
		error = '';
		try {
			preview = await e2eReports.cleanup($adminKey, cleanupBody(true));
			await load();
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		}
	}

	onMount(load);
</script>

<div class="mb-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
	<div>
		<h1 class="text-2xl font-semibold">Artifacts</h1>
		<p class="mt-1 text-sm text-gray-500">Preview cleanup before deleting R2 objects.</p>
	</div>
	<button onclick={load} class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">Refresh</button>
</div>

<div class="mb-4 grid gap-3 rounded-lg border border-gray-800 bg-gray-900 p-4 md:grid-cols-6">
	<label class="text-xs text-gray-400">
		Status
		<select bind:value={status} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100">
			<option value="">Any</option>
			<option value="success">success</option>
			<option value="failure">failure</option>
			<option value="cancelled">cancelled</option>
			<option value="skipped">skipped</option>
		</select>
	</label>
	<label class="text-xs text-gray-400">
		Target
		<select bind:value={target} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100">
			<option value="">Any</option>
			<option value="web">web</option>
			<option value="electron">electron</option>
		</select>
	</label>
	<label class="text-xs text-gray-400">
		Branch
		<input bind:value={branch} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100" />
	</label>
	<label class="text-xs text-gray-400">
		PR
		<input bind:value={pr} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100" />
	</label>
	<label class="text-xs text-gray-400">
		Before
		<input type="datetime-local" bind:value={before} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100" />
	</label>
	<label class="text-xs text-gray-400">
		Limit
		<input type="number" bind:value={limit} class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100" />
	</label>
</div>

<div class="mb-4 flex flex-wrap gap-2">
	<button onclick={runPreview} class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">Cleanup preview</button>
	{#if preview}
		<button onclick={confirmCleanup} class="rounded bg-red-900 px-3 py-1.5 text-sm hover:bg-red-800">
			Delete {preview.objectCount} objects
		</button>
	{/if}
</div>

{#if error}
	<div class="mb-4 rounded border border-red-900 bg-red-950/40 p-3 text-sm text-red-200">{error}</div>
{/if}

{#if preview}
	<div class="mb-4 rounded-lg border border-gray-800 bg-gray-900 p-4 text-sm">
		<div class="font-medium text-gray-200">
			Preview: {preview.runs.length} runs, {preview.objectCount} objects, {formatBytes(preview.totalBytes)}
		</div>
		<div class="mt-2 text-xs text-gray-500">
			Selection takes precedence over filters. Without selection or filters, cleanup uses success &gt; 7 days and failure/cancelled/skipped &gt; 30 days.
		</div>
	</div>
{/if}

<div class="overflow-hidden rounded-lg border border-gray-800">
	<table class="w-full text-left text-xs">
		<thead class="bg-gray-900 uppercase text-gray-500">
			<tr>
				<th class="px-3 py-2">Select</th>
				<th class="px-3 py-2">Run</th>
				<th class="px-3 py-2">Status</th>
				<th class="px-3 py-2">Target</th>
				<th class="px-3 py-2">Kind</th>
				<th class="px-3 py-2">Path</th>
				<th class="px-3 py-2">Size</th>
				<th class="px-3 py-2">Finished</th>
			</tr>
		</thead>
		<tbody class="divide-y divide-gray-800 bg-gray-950">
			{#each artifacts as artifact}
				{@const key = `${artifact.runId}:${artifact.attempt}`}
				<tr class="hover:bg-gray-900/60">
					<td class="px-3 py-2">
						<input type="checkbox" bind:checked={selected[key]} class="h-4 w-4" />
					</td>
					<td class="px-3 py-2">
						{#if artifact.runId && artifact.attempt}
							<a href={`/e2e-reports/runs/${artifact.runId}/${artifact.attempt}`} class="text-gray-300 hover:text-white">
								{artifact.runId}/{artifact.attempt}
							</a>
						{/if}
					</td>
					<td class="px-3 py-2 text-gray-400">{artifact.status}</td>
					<td class="px-3 py-2 text-gray-400">{artifact.target}</td>
					<td class="px-3 py-2 text-gray-400">{artifact.kind}</td>
					<td class="px-3 py-2 font-mono text-gray-400">{artifact.path ?? artifact.key}</td>
					<td class="px-3 py-2 text-gray-500">{formatBytes(artifact.size)}</td>
					<td class="px-3 py-2 text-gray-500">{artifact.finishedAt}</td>
				</tr>
			{:else}
				<tr>
					<td colspan="8" class="px-3 py-8 text-center text-gray-500">{loading ? 'Loading...' : 'No artifacts found'}</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>
