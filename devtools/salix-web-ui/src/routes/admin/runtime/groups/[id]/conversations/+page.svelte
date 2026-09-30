<script lang="ts">
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import type { AgentGroup, GroupConversation, GroupConversationParticipant } from '$lib/types';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import { onDestroy, onMount } from 'svelte';

	const groupId = $derived($page.params.id!);

	let group = $state<AgentGroup | null>(null);
	let conversations = $state<GroupConversation[]>([]);
	let nextCursor = $state<string | undefined>(undefined);
	let hasMore = $state(false);
	let title = $state('');
	let creating = $state(false);
	let loading = $state(false);
	let loadingMore = $state(false);
	let error = $state('');
	let pollHandle: ReturnType<typeof setInterval> | null = null;

	async function load(reset = true) {
		loading = reset;
		try {
			if (!group) group = await runtimeDebug.getGroup($adminKey, groupId);
			const result = await runtimeDebug.listGroupConversations($adminKey, groupId, {
				limit: 100,
				cursor: reset ? undefined : nextCursor,
			});
			conversations = reset ? result.data : [...conversations, ...result.data];
			nextCursor = result.next_cursor;
			hasMore = result.has_more;
			error = '';
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	async function loadMore() {
		if (!hasMore || !nextCursor || loadingMore) return;
		loadingMore = true;
		try {
			const result = await runtimeDebug.listGroupConversations($adminKey, groupId, {
				limit: 100,
				cursor: nextCursor,
			});
			conversations = [...conversations, ...result.data];
			nextCursor = result.next_cursor;
			hasMore = result.has_more;
		} catch (e) {
			error = String(e);
		} finally {
			loadingMore = false;
		}
	}

	async function createConversation() {
		if (creating) return;
		creating = true;
		try {
			const conversation = await runtimeDebug.createGroupConversation($adminKey, groupId, {
				title: title.trim(),
			});
			await goto(`/admin/runtime/groups/${groupId}/conversations/${encodeURIComponent(conversation.conversation_id)}`);
		} catch (e) {
			error = String(e);
		} finally {
			creating = false;
		}
	}

	onMount(() => {
		load();
		pollHandle = setInterval(() => load(true), 5000);
	});

	onDestroy(() => {
		if (pollHandle) clearInterval(pollHandle);
	});

	function contentPreview(content: unknown): string {
		if (typeof content === 'string') return content.trim() || '-';
		if (Array.isArray(content)) {
			return (
				content
					.map((block) => {
						if (typeof block === 'string') return block;
						if (block && typeof block === 'object') {
							const record = block as Record<string, unknown>;
							if (typeof record.text === 'string') return record.text;
							if (typeof record.type === 'string') return `[${record.type}]`;
						}
						return '';
					})
					.filter(Boolean)
					.join(' ')
					.trim() || '-'
			);
		}
		return '-';
	}

	function titleFor(conversation: GroupConversation): string {
		return conversation.title || contentPreview(conversation.last_message_preview) || conversation.conversation_id;
	}

	function participantSummary(participants?: GroupConversationParticipant[]): string {
		if (!participants || participants.length === 0) return 'no participants';
		return participants.map(participantLabel).join(' · ');
	}

	function participantLabel(participant: GroupConversationParticipant): string {
		if (participant.agent_name) return participant.role_label ? `${participant.agent_name}:${participant.role_label}` : participant.agent_name;
		if (participant.agent_id) return participant.role_label ? `${participant.agent_id.slice(0, 8)}:${participant.role_label}` : participant.agent_id.slice(0, 8);
		if (participant.user_id) return `user:${participant.user_id.slice(0, 8)}`;
		return participant.actor_type || participant.participant_id;
	}

	function kindLabel(kind: string): string {
		switch (kind) {
			case 'agent_task': return 'agent task';
			case 'user_chat': return 'user chat';
			default: return kind || '?';
		}
	}

	function kindBadgeClass(kind: string): string {
		switch (kind) {
			case 'agent_task': return 'bg-emerald-500/15 text-emerald-300 border border-emerald-500/30';
			case 'user_chat': return 'bg-blue-500/15 text-blue-300 border border-blue-500/30';
			default: return 'bg-gray-700/30 text-gray-400 border border-gray-700';
		}
	}

	function timestampMs(ts?: number): number | null {
		if (!ts) return null;
		return ts > 10_000_000_000 ? ts : ts * 1000;
	}

	function formatTime(ts?: number): string {
		const ms = timestampMs(ts);
		if (!ms) return '-';
		return new Date(ms).toLocaleString();
	}
</script>

<a href="/admin/runtime/groups/{groupId}" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Group</a>

<div class="flex items-center justify-between mb-4 flex-wrap gap-2">
	<div>
		<h1 class="text-xl font-bold">Conversations</h1>
		<p class="text-xs text-gray-500 mt-1 font-mono">{group?.name || groupId}</p>
	</div>
	<form
		class="flex items-center gap-2"
		onsubmit={(e: SubmitEvent) => { e.preventDefault(); createConversation(); }}
	>
		<input
			bind:value={title}
			placeholder="Optional title"
			class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
		/>
		<button
			type="submit"
			disabled={creating}
			class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-1.5 rounded text-sm"
		>{creating ? 'Creating...' : 'New conversation'}</button>
		<button
			type="button"
			onclick={() => load(true)}
			disabled={loading}
			class="bg-gray-700 hover:bg-gray-600 disabled:opacity-50 px-3 py-1.5 rounded text-sm"
		>{loading ? 'Refreshing...' : 'Refresh'}</button>
	</form>
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if loading && conversations.length === 0}
	<p class="text-gray-500 text-sm">Loading conversations...</p>
{:else if conversations.length === 0}
	<p class="text-gray-500 text-sm">No conversations yet for this group.</p>
{:else}
	<div class="space-y-1">
		{#each conversations as conversation (conversation.conversation_id)}
			<a
				href="/admin/runtime/groups/{groupId}/conversations/{encodeURIComponent(conversation.conversation_id)}"
				class="block bg-gray-900 border border-gray-800 rounded px-3 py-2 hover:bg-gray-800/80 hover:border-gray-700 transition-colors"
			>
				<div class="flex items-center gap-2 flex-wrap">
					<span class="text-sm text-white font-medium truncate max-w-md">{titleFor(conversation)}</span>
					<span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded {kindBadgeClass(conversation.kind)}">{kindLabel(conversation.kind)}</span>
					{#if conversation.activity_status}
						<StatusBadge status={conversation.activity_status} />
					{:else if conversation.status}
						<StatusBadge status={conversation.status} />
					{/if}
				</div>
				<div class="flex items-center gap-3 mt-1 flex-wrap">
					<span class="text-xs text-gray-500">{participantSummary(conversation.participants)}</span>
					<span class="text-xs text-gray-600">·</span>
					<span class="text-xs text-gray-500">{conversation.message_count} message{conversation.message_count === 1 ? '' : 's'}</span>
					<span class="text-xs text-gray-600">·</span>
					<span class="text-xs text-gray-500">updated {formatTime(conversation.updated_at)}</span>
				</div>
				{#if conversation.last_round_error}
					<div class="mt-1 text-xs text-red-400/80 truncate">{conversation.last_round_error}</div>
				{/if}
			</a>
		{/each}
	</div>

	{#if hasMore}
		<div class="mt-4 flex justify-center">
			<button
				onclick={loadMore}
				disabled={loadingMore}
				class="bg-gray-700 hover:bg-gray-600 disabled:opacity-50 px-4 py-1.5 rounded text-sm"
			>{loadingMore ? 'Loading...' : 'Load more'}</button>
		</div>
	{/if}
{/if}
