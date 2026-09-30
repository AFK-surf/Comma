<script lang="ts">
	import { onMount } from 'svelte';
	import { e2eReports } from '$lib/api';
	import { formatBytes, formatDuration, shortSha, targetNames } from '$lib/format';
	import { adminKey } from '$lib/stores/auth';
	import type { RunRecord } from '$lib/types';

	let runs = $state<RunRecord[]>([]);
	let loading = $state(false);
	let error = $state('');
	let days = $state(30);
	let status = $state('');
	let target = $state('');
	let branch = $state('');
	let pr = $state('');

	async function load() {
		if (!$adminKey) return;
		loading = true;
		error = '';
		try {
			runs = (
				await e2eReports.listRuns($adminKey, {
					days,
					status,
					target,
					branch,
					pr,
					limit: 200
				})
			).runs;
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		} finally {
			loading = false;
		}
	}

	onMount(load);
</script>

<div class="mb-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
	<div>
		<h1 class="text-2xl font-semibold">Runs</h1>
		<p class="mt-1 text-sm text-gray-500">Last 30 days by default.</p>
	</div>
	<button onclick={load} class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">
		Refresh
	</button>
</div>

<div class="mb-4 grid gap-3 rounded-lg border border-gray-800 bg-gray-900 p-4 md:grid-cols-5">
	<label class="text-xs text-gray-400">
		Days
		<input
			type="number"
			min="1"
			max="35"
			bind:value={days}
			class="mt-1 w-full rounded border border-gray-700 bg-gray-800 px-2 py-1 text-sm text-gray-100"
		/>
	</label>
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
</div>

{#if error}
	<div class="mb-4 rounded border border-red-900 bg-red-950/40 p-3 text-sm text-red-200">{error}</div>
{/if}

<div class="overflow-hidden rounded-lg border border-gray-800">
	<table class="w-full text-left text-sm">
		<thead class="bg-gray-900 text-xs uppercase text-gray-500">
			<tr>
				<th class="px-3 py-2">Status</th>
				<th class="px-3 py-2">Run</th>
				<th class="px-3 py-2">Branch</th>
				<th class="px-3 py-2">PR</th>
				<th class="px-3 py-2">Workflow</th>
				<th class="px-3 py-2">Targets</th>
				<th class="px-3 py-2">Duration</th>
				<th class="px-3 py-2">Artifacts</th>
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
					<td class="px-3 py-2 text-gray-400">{run.prNumber ? `#${run.prNumber}` : ''}</td>
					<td class="px-3 py-2">
						{#if run.workflowUrl}
							<a href={run.workflowUrl} class="text-gray-400 hover:text-white">Actions</a>
						{/if}
					</td>
					<td class="px-3 py-2 text-gray-400">{targetNames(run.targets, run.targetOrder).join(', ')}</td>
					<td class="px-3 py-2 text-gray-400">{formatDuration(run.durationMs)}</td>
					<td class="px-3 py-2 text-gray-400">{run.artifactCount ?? 0} / {formatBytes(run.artifactBytes)}</td>
					<td class="px-3 py-2 text-gray-400">{shortSha(run.commitSha)}</td>
				</tr>
			{:else}
				<tr>
					<td colspan="9" class="px-3 py-8 text-center text-gray-500">{loading ? 'Loading...' : 'No runs found'}</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>
