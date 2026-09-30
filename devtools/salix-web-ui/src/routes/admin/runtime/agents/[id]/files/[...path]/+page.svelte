<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import type { VFSEntry } from '$lib/types';

	let entries = $state<VFSEntry[] | null>(null);
	let content = $state<string | null>(null);
	let isDir = $state(true);
	let error = $state('');
	let downloadingPath = $state<string | null>(null);

	const agentId = $derived($page.params.id!);
	const filePath = $derived('/' + ($page.params.path || ''));

	async function load(aid: string, fp: string) {
		entries = null;
		content = null;
		error = '';
		isDir = true;
		try {
			// Try loading as directory first.
			const res = await runtimeDebug.getFiles($adminKey, aid, fp);
			if (Array.isArray(res)) {
				entries = res;
				isDir = true;
			}
		} catch {
			// Not a directory — load as file.
			try {
				content = await runtimeDebug.getFileContent($adminKey, aid, fp);
				isDir = false;
			} catch (e) {
				error = String(e);
			}
		}
	}

	$effect(() => { load(agentId, filePath); });

	// Breadcrumbs.
	const crumbs = $derived.by(() => {
		const parts = filePath.split('/').filter(Boolean);
		const result = [{ name: '/', href: `/admin/runtime/agents/${agentId}/files/` }];
		let acc = '';
		for (const p of parts) {
			acc += '/' + p;
			result.push({ name: p, href: `/admin/runtime/agents/${agentId}/files${acc}` });
		}
		return result;
	});

	function basename(path: string) {
		const parts = path.split('/');
		return parts[parts.length - 1] || path;
	}

	function formatSize(bytes: number): string {
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
		return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
	}

	async function downloadFile(path: string) {
		downloadingPath = path;
		error = '';
		try {
			const blob = await runtimeDebug.getFileBlob($adminKey, agentId, path);
			const url = URL.createObjectURL(blob);
			const link = document.createElement('a');
			link.href = url;
			link.download = basename(path) || 'download';
			document.body.appendChild(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(url), 1000);
		} catch (e) {
			error = String(e);
		} finally {
			downloadingPath = null;
		}
	}
</script>

<div class="flex items-center gap-1 mb-4 text-sm">
	<a href="/admin/runtime/agents/{agentId}" class="text-gray-500 hover:text-gray-300">&larr;</a>
	{#each crumbs as crumb, i}
		{#if i > 0}<span class="text-gray-600">/</span>{/if}
		<a href={crumb.href} class="text-gray-400 hover:text-gray-200">{crumb.name}</a>
	{/each}
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if isDir && entries}
	<table class="w-full text-sm">
		<thead>
			<tr class="text-left text-gray-500 border-b border-gray-800">
				<th class="pb-2 font-medium">Name</th>
				<th class="pb-2 font-medium">Size</th>
				<th class="pb-2 font-medium text-right">Actions</th>
			</tr>
		</thead>
		<tbody>
			{#each entries as entry}
				<tr class="border-b border-gray-800/50 hover:bg-gray-900/50">
					<td class="py-1.5">
						{#if entry.kind === 'dir'}
							<a href="/admin/runtime/agents/{agentId}/files{entry.path}" class="text-blue-400 hover:underline">{basename(entry.path)}/</a>
						{:else}
							<a href="/admin/runtime/agents/{agentId}/files{entry.path}" class="text-gray-200 hover:underline">{basename(entry.path)}</a>
						{/if}
					</td>
					<td class="py-1.5 text-gray-500">{entry.kind === 'file' ? formatSize(entry.size) : '-'}</td>
					<td class="py-1.5 text-right">
						{#if entry.kind === 'file'}
							<button
								type="button"
								onclick={() => downloadFile(entry.path)}
								disabled={downloadingPath === entry.path}
								class="text-xs text-blue-400 hover:text-blue-300 disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"
								title="Download file"
							>{downloadingPath === entry.path ? 'downloading...' : 'download'}</button>
						{:else}
							<span class="text-gray-700">-</span>
						{/if}
					</td>
				</tr>
			{/each}
			{#if entries.length === 0}
				<tr><td colspan="3" class="py-4 text-gray-600 text-center">Empty directory</td></tr>
			{/if}
		</tbody>
	</table>
{:else if !isDir && content !== null}
	<div class="flex items-center justify-between gap-3 mb-3">
		<div class="min-w-0">
			<div class="text-sm text-gray-300 truncate">{basename(filePath)}</div>
			<div class="font-mono text-xs text-gray-600 break-all">{filePath}</div>
		</div>
		<button
			type="button"
			onclick={() => downloadFile(filePath)}
			disabled={downloadingPath === filePath}
			class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed rounded px-3 py-1.5 text-sm whitespace-nowrap cursor-pointer"
		>{downloadingPath === filePath ? 'Downloading...' : 'Download'}</button>
	</div>
	<pre class="bg-gray-900 border border-gray-800 rounded p-4 text-xs whitespace-pre-wrap overflow-auto max-h-[calc(100vh-15rem)] font-mono">{content}</pre>
{/if}
