<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/stores';
	import { e2eReports } from '$lib/api';
	import { formatBytes, formatDuration, shortSha, targetNames } from '$lib/format';
	import { adminKey } from '$lib/stores/auth';
	import type { RunRecord } from '$lib/types';

	let run = $state<RunRecord | null>(null);
	let loading = $state(false);
	let error = $state('');

	const runId = $derived($page.params.runId ?? '');
	const attempt = $derived($page.params.attempt ?? '');

	async function load() {
		if (!$adminKey) return;
		loading = true;
		error = '';
		try {
			run = await e2eReports.getRun($adminKey, runId, attempt);
		} catch (err) {
			error = err instanceof Error ? err.message : String(err);
		} finally {
			loading = false;
		}
	}

	onMount(load);
</script>

{#if error}
	<div class="mb-4 rounded border border-red-900 bg-red-950/40 p-3 text-sm text-red-200">{error}</div>
{/if}

{#if run}
	<div class="mb-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
		<div>
			<h1 class="text-2xl font-semibold">Run {run.runId}/{run.attempt}</h1>
			<p class="mt-1 text-sm text-gray-500">{run.workflowName} · {run.branch} · {shortSha(run.commitSha)}</p>
		</div>
		<div class="flex gap-2">
			{#if run.workflowUrl}
				<a href={run.workflowUrl} class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">Workflow</a>
			{/if}
			<a href="/e2e-reports/artifacts" class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">Artifacts</a>
		</div>
	</div>

	<div class="mb-6 grid gap-4 md:grid-cols-4">
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Status</div>
			<div class="mt-2 text-xl font-semibold">{run.status}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Duration</div>
			<div class="mt-2 text-xl font-semibold">{formatDuration(run.durationMs)}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Artifacts</div>
			<div class="mt-2 text-xl font-semibold">{run.artifactCount ?? 0}</div>
		</div>
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<div class="text-xs text-gray-500">Bytes</div>
			<div class="mt-2 text-xl font-semibold">{formatBytes(run.artifactBytes)}</div>
		</div>
	</div>

	<div class="space-y-4">
		{#each targetNames(run.targets, run.targetOrder) as target}
			{@const item = run.targets?.[target]}
			{#if item}
				<section class="rounded-lg border border-gray-800 bg-gray-900 p-4">
					<div class="mb-4 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
						<div>
							<h2 class="text-lg font-semibold">{target}</h2>
							<p class="text-sm text-gray-500">
								{item.status} · {formatDuration(item.durationMs)} · {item.artifactCount ?? 0} files
							</p>
						</div>
						<a
							href={`/e2e-reports/runs/${run.runId}/${run.attempt}/${target}/report`}
							class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700"
						>
							Open report
						</a>
					</div>

					<div class="grid gap-3 md:grid-cols-4">
						<div class="rounded border border-gray-800 bg-gray-950 p-3 text-sm">
							<div class="text-xs text-gray-500">Passed</div>
							<div class="mt-1 text-lg">{item.summary?.passed ?? 0}</div>
						</div>
						<div class="rounded border border-gray-800 bg-gray-950 p-3 text-sm">
							<div class="text-xs text-gray-500">Failed</div>
							<div class="mt-1 text-lg text-red-300">{item.summary?.failed ?? 0}</div>
						</div>
						<div class="rounded border border-gray-800 bg-gray-950 p-3 text-sm">
							<div class="text-xs text-gray-500">Flaky</div>
							<div class="mt-1 text-lg">{item.summary?.flaky ?? 0}</div>
						</div>
						<div class="rounded border border-gray-800 bg-gray-950 p-3 text-sm">
							<div class="text-xs text-gray-500">Skipped</div>
							<div class="mt-1 text-lg">{item.summary?.skipped ?? 0}</div>
						</div>
					</div>

					{#if item.failedTests?.length}
						<div class="mt-4">
							<h3 class="mb-2 text-sm font-medium text-gray-300">Failed tests</h3>
							<div class="space-y-2">
								{#each item.failedTests as test}
									<div class="rounded border border-gray-800 bg-gray-950 p-3 text-sm">
										<div class="font-medium text-gray-200">{test.title}</div>
										<div class="mt-1 text-xs text-gray-500">{test.project} {test.location ? `· ${test.location}` : ''}</div>
										{#if test.error}
											<pre class="mt-2 overflow-auto whitespace-pre-wrap text-xs text-red-200">{test.error}</pre>
										{/if}
									</div>
								{/each}
							</div>
						</div>
					{/if}

					{#if item.artifacts?.length}
						<div class="mt-4 overflow-hidden rounded border border-gray-800">
							<table class="w-full text-left text-xs">
								<thead class="bg-gray-950 text-gray-500">
									<tr>
										<th class="px-3 py-2">Kind</th>
										<th class="px-3 py-2">Path</th>
										<th class="px-3 py-2">Size</th>
									</tr>
								</thead>
								<tbody class="divide-y divide-gray-800">
									{#each item.artifacts as artifact}
										<tr>
											<td class="px-3 py-2 text-gray-400">{artifact.kind}</td>
											<td class="px-3 py-2 font-mono text-gray-400">{artifact.path}</td>
											<td class="px-3 py-2 text-gray-500">{formatBytes(artifact.size)}</td>
										</tr>
									{/each}
								</tbody>
							</table>
						</div>
					{/if}
				</section>
			{/if}
		{/each}
	</div>
{:else}
	<div class="rounded-lg border border-gray-800 bg-gray-900 p-4 text-sm text-gray-500">
		{loading ? 'Loading...' : 'No run loaded'}
	</div>
{/if}
