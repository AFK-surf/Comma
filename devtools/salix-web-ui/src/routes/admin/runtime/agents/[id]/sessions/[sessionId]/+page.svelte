<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Markdown from '$lib/components/Markdown.svelte';
	import type { RuntimeMessage, RuntimeSessionMessages, Session } from '$lib/types';
	import { onMount } from 'svelte';

	const agentId = $derived($page.params.id!);
	const sessionId = $derived($page.params.sessionId!);

	let sessionInfo = $state<Session | null>(null);
	let messageState = $state<RuntimeSessionMessages | null>(null);
	let traceText = $state('');
	let loading = $state(true);
	let traceLoading = $state(false);
	let error = $state('');
	let draft = $state('');
	let sending = $state(false);
	let sendError = $state('');

	async function load() {
		loading = true;
		error = '';
		try {
			const [session, messages] = await Promise.all([
				runtimeDebug.getSession($adminKey, agentId, sessionId),
				runtimeDebug.listSessionMessages($adminKey, agentId, sessionId),
			]);
			sessionInfo = session;
			messageState = messages;
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	onMount(() => {
		void load();
	});

	function formatTime(ts?: number): string {
		if (!ts) return '-';
		return new Date(ts * 1000).toLocaleString();
	}

	function messageText(message: RuntimeMessage): string {
		if (typeof message.content === 'string') return message.content;
		if (message.content == null) return '';
		return JSON.stringify(message.content, null, 2);
	}

	function roleClass(role: string): string {
		switch (role) {
			case 'assistant':
				return 'border-emerald-700 text-emerald-300 bg-emerald-950/20';
			case 'user':
				return 'border-blue-700 text-blue-300 bg-blue-950/20';
			case 'tool':
				return 'border-amber-700 text-amber-300 bg-amber-950/20';
			case 'system':
				return 'border-purple-700 text-purple-300 bg-purple-950/20';
			default:
				return 'border-gray-700 text-gray-300 bg-gray-950/20';
		}
	}

	async function loadTrace() {
		traceLoading = true;
		error = '';
		try {
			const trace = await runtimeDebug.getSessionTrace($adminKey, agentId, sessionId);
			traceText = JSON.stringify(trace, null, 2);
		} catch (e) {
			error = String(e);
		} finally {
			traceLoading = false;
		}
	}

	async function downloadTrace() {
		traceLoading = true;
		error = '';
		try {
			const trace = await runtimeDebug.getSessionTrace($adminKey, agentId, sessionId);
			const blob = new Blob([JSON.stringify(trace, null, 2)], { type: 'application/json' });
			const url = URL.createObjectURL(blob);
			const link = document.createElement('a');
			link.href = url;
			link.download = `${sessionId}-runtime-trace.json`;
			link.click();
			setTimeout(() => URL.revokeObjectURL(url), 60_000);
		} catch (e) {
			error = String(e);
		} finally {
			traceLoading = false;
		}
	}

	// Stable per-submit identity: minted once per retained draft and reused on
	// every retry of that draft, so a commit whose response was lost dedupes on
	// the server instead of creating a second message. Cleared only when the
	// draft is replaced (successful send empties the composer).
	let draftSourceMessageId = '';

	async function sendRuntimeMessage() {
		const text = draft.trim();
		if (!text || sending) return;
		if (!draftSourceMessageId) draftSourceMessageId = `salix-web-ui:${crypto.randomUUID()}`;
		sending = true;
		sendError = '';
		try {
			await runtimeDebug.sendSessionMessage(
				$adminKey,
				agentId,
				text,
				sessionId,
				draftSourceMessageId
			);
			draft = '';
			draftSourceMessageId = '';
			await load();
		} catch (e) {
			sendError = String(e);
		} finally {
			sending = false;
		}
	}

	function onComposerKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendRuntimeMessage();
		}
	}
</script>

<div class="space-y-6">
	<a href="/admin/runtime/agents/{agentId}?session={encodeURIComponent(sessionId)}" class="text-sm text-gray-500 hover:text-gray-300">&larr; Agent</a>

	{#if error}<p class="text-red-400 text-sm">{error}</p>{/if}

	{#if loading}
		<p class="text-sm text-gray-500">Loading...</p>
	{:else if sessionInfo}
		<div class="flex flex-col md:flex-row md:items-start md:justify-between gap-4">
			<div>
				<div class="flex items-center gap-2 flex-wrap">
					<h1 class="text-lg font-bold">{sessionInfo.name || sessionId.slice(0, 12)}</h1>
					<StatusBadge status={sessionInfo.activity_status || sessionInfo.status} />
					{#if sessionInfo.hidden}
						<span class="text-[10px] uppercase px-1.5 py-0.5 rounded bg-gray-700/40 text-gray-400 border border-gray-700">hidden</span>
					{/if}
					{#if sessionInfo.purpose}
						<span class="text-[10px] uppercase px-1.5 py-0.5 rounded bg-gray-800 text-gray-400 border border-gray-700">{sessionInfo.purpose}</span>
					{/if}
				</div>
				<p class="mt-1 font-mono text-xs text-gray-500 break-all">{sessionId}</p>
			</div>
			<div class="flex gap-2 flex-wrap">
				<button onclick={load} class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Refresh</button>
				<button onclick={loadTrace} disabled={traceLoading} class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-1.5 rounded text-sm">
					{traceLoading ? 'Loading...' : 'Load trace'}
				</button>
				<button onclick={downloadTrace} disabled={traceLoading} class="bg-gray-800 hover:bg-gray-700 disabled:opacity-50 px-3 py-1.5 rounded text-sm">Download trace</button>
				<a href="/admin/runtime/agents/{agentId}/files/memory/" class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Agent memory</a>
			</div>
		</div>

		<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
			<div class="bg-gray-900 border border-gray-800 rounded p-3">
				<div class="text-gray-500 text-xs mb-1">Agent</div>
				<a href="/admin/runtime/agents/{agentId}" class="font-mono text-xs text-blue-400 hover:underline break-all">{agentId}</a>
			</div>
			<div class="bg-gray-900 border border-gray-800 rounded p-3">
				<div class="text-gray-500 text-xs mb-1">Created</div>
				<div>{formatTime(sessionInfo.created_at)}</div>
			</div>
			<div class="bg-gray-900 border border-gray-800 rounded p-3">
				<div class="text-gray-500 text-xs mb-1">Last activity</div>
				<div>{formatTime(sessionInfo.last_activity_at)}</div>
			</div>
			<div class="bg-gray-900 border border-gray-800 rounded p-3">
				<div class="text-gray-500 text-xs mb-1">Source</div>
				<div class="font-mono text-xs text-gray-300 break-all">{sessionInfo.source_session_id || sessionInfo.source_schedule_id || '-'}</div>
			</div>
		</div>

		{#if sessionInfo.last_round_error}
			<div class="bg-red-950/20 border border-red-900 rounded p-3 text-sm text-red-300 whitespace-pre-wrap">{sessionInfo.last_round_error}</div>
		{/if}

		{#if traceText}
			<section class="bg-gray-950 border border-gray-800 rounded p-4">
				<div class="flex items-center justify-between gap-2 mb-3">
					<h2 class="text-sm font-medium text-gray-300">Runtime trace</h2>
					<button onclick={() => (traceText = '')} class="text-xs text-gray-500 hover:text-gray-300">Hide</button>
				</div>
				<pre class="max-h-[32rem] overflow-auto text-xs whitespace-pre-wrap font-mono text-gray-200">{traceText}</pre>
			</section>
		{/if}

		<section class="bg-gray-900 border border-gray-800 rounded p-4">
			<div class="flex items-center justify-between gap-2 mb-4">
				<h2 class="text-sm font-medium text-gray-300">Runtime transcript</h2>
				<span class="text-xs text-gray-500">{messageState?.messages.length || 0} messages</span>
			</div>
			{#if messageState && messageState.messages.length > 0}
				<div class="space-y-3">
					{#each messageState.messages as message, index (`${message.id ?? 'message'}-${index}`)}
						<div class="bg-gray-950/70 border border-gray-800 rounded p-3">
							<div class="flex items-center gap-2 flex-wrap mb-2">
								<span class="inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] {roleClass(message.role)}">{message.role || 'message'}</span>
								{#if message.id != null}<span class="font-mono text-[11px] text-gray-600">#{message.id}</span>{/if}
								{#if message.tool_call_id}<span class="font-mono text-[11px] text-gray-500">tool_call {message.tool_call_id}</span>{/if}
								{#if message.tool_calls?.length}<span class="text-[11px] text-amber-300">{message.tool_calls.length} tool calls</span>{/if}
							</div>
							<div class="text-sm">
								<Markdown content={messageText(message)} />
							</div>
							{#if message.tool_calls?.length}
								<pre class="mt-3 max-h-64 overflow-auto rounded bg-gray-900 border border-gray-800 p-2 text-[11px] text-gray-300">{JSON.stringify(message.tool_calls, null, 2)}</pre>
							{/if}
						</div>
					{/each}
				</div>
				{#if messageState?.history_truncated}
					<p class="mt-2 text-xs text-gray-500">
						Showing the live window only — {messageState.archived_through} earlier records are archived.
					</p>
				{/if}
			{:else}
				<p class="text-sm text-gray-500">
					{messageState?.history_truncated
						? 'Live window is empty — earlier messages are archived and not shown here.'
						: 'No runtime messages for this session.'}
				</p>
			{/if}

			<form
				class="mt-4 flex flex-col sm:flex-row sm:items-end gap-2"
				onsubmit={(e: SubmitEvent) => { e.preventDefault(); sendRuntimeMessage(); }}
			>
				<textarea
					bind:value={draft}
					onkeydown={onComposerKeydown}
					rows="2"
					placeholder="Send a runtime message to this session"
					class="flex-1 bg-gray-950 border border-gray-800 rounded px-3 py-2 text-sm focus:outline-none focus:border-gray-600 resize-none"
				></textarea>
				<button
					type="submit"
					disabled={sending || !draft.trim()}
					class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-2 rounded text-sm"
				>{sending ? 'Sending...' : 'Send'}</button>
			</form>
			{#if sendError}<p class="mt-2 text-sm text-red-400">{sendError}</p>{/if}
		</section>
	{:else}
		<p class="text-sm text-gray-500">Session not found.</p>
	{/if}
</div>
