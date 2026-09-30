<script lang="ts">
	import { renderMarkdown } from '$lib/markdown';

	let { content, streaming = false }: { content: string; streaming?: boolean } = $props();

	let rendered = $derived(renderMarkdown(content));
</script>

<div class="prose prose-invert prose-sm max-w-none
	prose-pre:bg-gray-800 prose-pre:border prose-pre:border-gray-700
	prose-code:text-pink-400 prose-code:before:content-none prose-code:after:content-none
	prose-a:text-blue-400 prose-a:no-underline hover:prose-a:underline
	prose-headings:text-gray-100
	prose-strong:text-gray-100
	prose-blockquote:border-gray-700 prose-blockquote:text-gray-300
	prose-th:text-gray-300 prose-td:text-gray-300
	prose-hr:border-gray-700">
	{@html rendered}
	{#if streaming}
		<span class="inline-block w-1.5 h-4 bg-gray-400 animate-pulse ml-0.5 align-text-bottom"></span>
	{/if}
</div>
