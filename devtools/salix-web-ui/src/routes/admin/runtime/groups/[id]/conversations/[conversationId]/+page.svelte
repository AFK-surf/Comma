<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import type { GroupConversation, GroupConversationParticipant, IMStoredMessage } from '$lib/types';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Markdown from '$lib/components/Markdown.svelte';
	import { onDestroy, onMount, tick } from 'svelte';

	interface ContentBlock {
		type?: string;
		text?: string;
		file_name?: string;
		mime_type?: string;
		size_bytes?: number;
		url?: string;
		file_refs?: Array<Record<string, unknown>>;
	}

	const groupId = $derived($page.params.id!);
	const conversationId = $derived($page.params.conversationId!);

	let conversation = $state<GroupConversation | null>(null);
	let messages = $state<IMStoredMessage[]>([]);
	let loading = $state(true);
	let error = $state('');
	let draft = $state('');
	let sending = $state(false);
	let sendError = $state('');
	let messagesEl: HTMLDivElement | undefined = $state();
	let stickToBottom = $state(true);
	let pollHandle: ReturnType<typeof setInterval> | null = null;

	async function loadAll() {
		try {
			const [nextConversation, nextMessages] = await Promise.all([
				runtimeDebug.getGroupConversation($adminKey, groupId, conversationId),
				runtimeDebug.listGroupConversationMessages($adminKey, groupId, conversationId, { limit: 500 }),
			]);
			conversation = nextConversation;
			const wasAtBottom = stickToBottom;
			messages = [...nextMessages].sort((a, b) => a.created_at - b.created_at || a.message_id.localeCompare(b.message_id));
			error = '';
			if (wasAtBottom) {
				await tick();
				scrollToBottom();
			}
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	async function sendMessage() {
		const text = draft.trim();
		if (!text || sending) return;
		sending = true;
		sendError = '';
		try {
			await runtimeDebug.sendGroupConversationMessage($adminKey, groupId, conversationId, text, `web-${crypto.randomUUID()}`);
			draft = '';
			stickToBottom = true;
			await loadAll();
		} catch (e) {
			sendError = String(e);
		} finally {
			sending = false;
		}
	}

	function onComposerKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendMessage();
		}
	}

	function scrollToBottom() {
		if (messagesEl) messagesEl.scrollTop = messagesEl.scrollHeight;
	}

	function onScroll() {
		if (!messagesEl) return;
		const distanceFromBottom = messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight;
		stickToBottom = distanceFromBottom < 80;
	}

	onMount(async () => {
		await loadAll();
		await tick();
		scrollToBottom();
		pollHandle = setInterval(() => loadAll(), 5000);
	});

	onDestroy(() => {
		if (pollHandle) clearInterval(pollHandle);
	});

	function parseBlocks(raw: unknown): ContentBlock[] {
		if (Array.isArray(raw)) return raw as ContentBlock[];
		if (typeof raw === 'string') return [{ type: 'text', text: raw }];
		if (raw && typeof raw === 'object') return [raw as ContentBlock];
		return [];
	}

	function textFromBlocks(blocks: ContentBlock[]): string {
		return blocks
			.filter((block) => block.type === 'text' && block.text)
			.map((block) => block.text)
			.join('\n');
	}

	function attachmentBlocks(blocks: ContentBlock[]): ContentBlock[] {
		return blocks.filter((block) => block.type && block.type !== 'text');
	}

	function attachmentLabel(block: ContentBlock): string {
		if (block.file_name) return block.file_name;
		if (block.url) return block.url;
		if (block.mime_type) return block.mime_type;
		return block.type || 'attachment';
	}

	function attachmentMeta(block: ContentBlock): string {
		const parts: string[] = [];
		if (block.type) parts.push(block.type);
		if (block.size_bytes != null) parts.push(`${block.size_bytes.toLocaleString()} bytes`);
		if (block.file_refs?.length) parts.push(`${block.file_refs.length} ref${block.file_refs.length === 1 ? '' : 's'}`);
		return parts.join(' · ');
	}

	function participantById(id: string): GroupConversationParticipant | undefined {
		return conversation?.participants?.find((participant) => participant.participant_id === id);
	}

	function participantLabel(participant: GroupConversationParticipant): string {
		if (participant.agent_name) return participant.role_label ? `${participant.agent_name} · ${participant.role_label}` : participant.agent_name;
		if (participant.agent_id) return participant.role_label ? `${participant.agent_id.slice(0, 8)} · ${participant.role_label}` : participant.agent_id.slice(0, 8);
		if (participant.user_id) return participant.user_id;
		return participant.actor_type || participant.participant_id;
	}

	function agentParticipantSessionId(participant: GroupConversationParticipant): string {
		if (participant.actor_type !== 'agent') return '';
		const sessionId = participant.payload?.session_id;
		return typeof sessionId === 'string' ? sessionId : '';
	}

	function senderLabel(message: IMStoredMessage): string {
		const participant = participantById(message.participant_id);
		if (participant) return participantLabel(participant);
		if (message.agent_name) return message.agent_name;
		if (message.agent_id) return message.agent_id.slice(0, 8);
		if (message.user_id) return message.user_id;
		return message.actor_type || message.participant_id || 'unknown';
	}

	function isUserMessage(message: IMStoredMessage): boolean {
		return (participantById(message.participant_id)?.actor_type ?? message.actor_type) === 'user';
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

<div class="flex flex-col h-[calc(100vh-3.5rem)] md:h-[calc(100vh-3rem)]">
	<div class="shrink-0">
		<a href="/admin/runtime/groups/{groupId}/conversations" class="text-sm text-gray-500 hover:text-gray-300 mb-3 inline-block">&larr; Conversations</a>

		{#if error}<p class="text-red-400 text-sm mb-3">{error}</p>{/if}

		{#if loading && !conversation}
			<p class="text-gray-500 text-sm">Loading conversation...</p>
		{:else if conversation}
			<div class="bg-gray-900 border border-gray-800 rounded p-3 mb-3">
				<div class="flex items-center gap-2 flex-wrap mb-1">
					<h1 class="text-base font-semibold text-white truncate">{conversation.title || 'Untitled conversation'}</h1>
					<span class="text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded {kindBadgeClass(conversation.kind)}">{kindLabel(conversation.kind)}</span>
					{#if conversation.activity_status}
						<StatusBadge status={conversation.activity_status} />
					{:else if conversation.status}
						<StatusBadge status={conversation.status} />
					{/if}
				</div>
				<div class="font-mono text-[11px] text-gray-500 break-all">{conversation.conversation_id}</div>
				<div class="flex items-center gap-2 flex-wrap mt-2 text-xs text-gray-500">
					<span>created {formatTime(conversation.created_at)}</span>
					<span class="text-gray-700">·</span>
					<span>updated {formatTime(conversation.updated_at)}</span>
					<span class="text-gray-700">·</span>
					<span>{conversation.message_count} message{conversation.message_count === 1 ? '' : 's'}</span>
				</div>
				{#if conversation.last_round_error}
					<div class="mt-2 text-xs text-red-400">{conversation.last_round_error}</div>
				{/if}

				{#if conversation.participants && conversation.participants.length > 0}
					<div class="mt-3 border-t border-gray-800 pt-3">
						<div class="text-[11px] uppercase tracking-wide text-gray-500 mb-2">Participants</div>
						<div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2">
							{#each conversation.participants as participant (participant.participant_id)}
								<div class="text-xs bg-gray-950 border border-gray-800 rounded px-2 py-2">
									<div class="flex items-start justify-between gap-2">
										<div class="min-w-0">
											<div class="text-gray-200 truncate">{participantLabel(participant)}</div>
											<div class="mt-1 text-gray-600 font-mono truncate">{participant.participant_id}</div>
										</div>
										<span class="shrink-0 px-1.5 py-0.5 rounded bg-gray-800 text-gray-400">{participant.state || 'active'}</span>
									</div>
									<div class="mt-2 flex flex-wrap gap-2">
										{#if participant.agent_id}
											<a href="/admin/runtime/agents/{participant.agent_id}" class="text-blue-400 hover:underline">Agent</a>
										{/if}
										{#if participant.agent_id && agentParticipantSessionId(participant)}
											<a href="/admin/runtime/agents/{participant.agent_id}/sessions/{encodeURIComponent(agentParticipantSessionId(participant))}" class="text-blue-400 hover:underline">Session</a>
										{:else if participant.actor_type === 'agent'}
											<span class="text-gray-600">No session recorded</span>
										{/if}
									</div>
									{#if agentParticipantSessionId(participant)}
										<div class="mt-1 text-[11px] text-gray-600 font-mono truncate">{agentParticipantSessionId(participant)}</div>
									{/if}
								</div>
							{/each}
						</div>
					</div>
				{/if}
			</div>
		{/if}
	</div>

	<div
		bind:this={messagesEl}
		onscroll={onScroll}
		class="flex-1 overflow-y-auto bg-gray-950 border border-gray-800 rounded p-3 space-y-3"
	>
		{#each messages as message (message.message_id)}
			{@const blocks = parseBlocks(message.content)}
			{@const text = textFromBlocks(blocks)}
			{@const attachments = attachmentBlocks(blocks)}
			<div class="flex {isUserMessage(message) ? 'justify-end' : 'justify-start'}">
				<div class="max-w-[min(48rem,85%)] rounded border px-3 py-2 {isUserMessage(message) ? 'bg-blue-500/10 border-blue-500/25' : 'bg-gray-900 border-gray-800'}">
					<div class="flex items-center gap-2 mb-1 text-[11px] text-gray-500">
						<span>{senderLabel(message)}</span>
						<span>·</span>
						<span>{formatTime(message.created_at)}</span>
					</div>
					{#if text}
						<Markdown content={text} />
					{/if}
					{#if attachments.length > 0}
						<div class="mt-2 space-y-1">
							{#each attachments as attachment}
								<div class="rounded border border-gray-800 bg-gray-950/70 px-2 py-1 text-xs">
									<div class="text-gray-200">{attachmentLabel(attachment)}</div>
									{#if attachmentMeta(attachment)}
										<div class="text-gray-500">{attachmentMeta(attachment)}</div>
									{/if}
								</div>
							{/each}
						</div>
					{/if}
					{#if !text && attachments.length === 0}
						<pre class="whitespace-pre-wrap text-xs text-gray-400">{JSON.stringify(message.content, null, 2)}</pre>
					{/if}
				</div>
			</div>
		{/each}
		{#if messages.length === 0}
			<p class="text-center text-gray-600 text-sm py-6">No messages yet.</p>
		{/if}
	</div>

	<div class="shrink-0 pt-3">
		{#if sendError}<p class="text-red-400 text-sm mb-2">{sendError}</p>{/if}
		<div class="flex items-end gap-2">
			<textarea
				bind:value={draft}
				onkeydown={onComposerKeydown}
				rows="2"
				placeholder="Message this group conversation"
				class="flex-1 bg-gray-900 border border-gray-800 rounded px-3 py-2 text-sm focus:outline-none focus:border-gray-600 resize-none"
			></textarea>
			<button
				onclick={sendMessage}
				disabled={sending || !draft.trim()}
				class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-4 py-2 rounded text-sm"
			>{sending ? 'Sending...' : 'Send'}</button>
		</div>
	</div>
</div>
