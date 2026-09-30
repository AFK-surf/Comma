<script lang="ts">
	import { onMount } from 'svelte';
	import { e2eReports } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';
	import { formatBytes, formatDuration, shortSha, targetNames } from '$lib/format';
	import type { RunRecord } from '$lib/types';

	let runs = $state<RunRecord[]>([]);
	let loading = $state(false);
	let error = $state('');

	async function load() {
		if (!$adminKey) return;
		loading = true;
		error = '';
		try {
			runs = (await e2eReports.listRuns($adminKey, { days: 30, limit: 20 })).runs;
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		} finally {
			loading = false;
		}
	}

	onMount(load);
</script>

{#if !$adminKey}
	<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
		<a href="/" class="text-sm text-gray-300 hover:text-white">Set admin key</a>
	</div>
{:else}
	<div class="mb-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
		<div>
			<h1 class="text-2xl font-semibold">E2E Reports</h1>
			<p class="mt-1 text-sm text-gray-500">Recent Client Checks runs from R2.</p>
		</div>
		<a href="/e2e-reports/runs" class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">
			Open runs
		</a>
	</div>

	{#if error}
		<div class="mb-4 rounded border border-red-900 bg-red-950/40 p-3 text-sm text-red-200">{error}</div>
	{/if}

	<div class="grid gap-4 md:grid-cols-4">
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Runs</div>
			<div class="mt-2 text-2xl font-semibold">{runs.length}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Failures</div>
			<div class="mt-2 text-2xl font-semibold text-red-300">{runs.filter((r) => r.status === 'failure').length}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Artifacts</div>
			<div class="mt-2 text-2xl font-semibold">{runs.reduce((n, r) => n + (r.artifactCount ?? 0), 0)}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Bytes</div>
			<div class="mt-2 text-2xl font-semibold">{formatBytes(runs.reduce((n, r) => n + (r.artifactBytes ?? 0), 0))}</div>
		</div>
	</div>

	<div class="mt-6 overflow-hidden rounded-lg border border-gray-800">
		<table class="w-full text-left text-sm">
			<thead class="bg-gray-900 text-xs uppercase text-gray-500">
				<tr>
					<th class="px-3 py-2">Status</th>
					<th class="px-3 py-2">Run</th>
					<th class="px-3 py-2">Branch</th>
					<th class="px-3 py-2">Targets</th>
					<th class="px-3 py-2">Duration</th>
					<th class="px-3 py-2">Commit</th>
				</tr>
			</thead>
			<tbody class="divide-y divide-gray-800 bg-gray-950">
				{#each runs as run}
					<tr class="hover:bg-gray-900/60">
						<td class="px-3 py-2">{run.status}</td>
						<td class="px-3 py-2">
							<a href={`/e2e-reports/runs/${run.runId}/${run.attempt}`} class="text-gray-200 hover:text-white">
								{run.runId}/{run.attempt}
							</a>
						</td>
						<td class="px-3 py-2 text-gray-400">{run.branch}</td>
						<td class="px-3 py-2 text-gray-400">{targetNames(run.targets, run.targetOrder).join(', ')}</td>
						<td class="px-3 py-2 text-gray-400">{formatDuration(run.durationMs)}</td>
						<td class="px-3 py-2 text-gray-400">{shortSha(run.commitSha)}</td>
					</tr>
				{:else}
					<tr>
						<td colspan="6" class="px-3 py-8 text-center text-gray-500">{loading ? 'Loading...' : 'No runs found'}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}
