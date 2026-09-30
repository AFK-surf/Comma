<script lang="ts">
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';
	import { admin } from '$lib/api';
	import { goto } from '$app/navigation';
	import type { AgentTemplate } from '$lib/types';
	import { geminiImageConfigExample, openAIImageConfigExample } from '$lib/image-config';
	import { seedanceVideoConfigExample } from '$lib/video-config';
	import { onMount } from 'svelte';

	let tmpl = $state<AgentTemplate | null>(null);
	let error = $state('');
	let saved = $state(false);

	let name = $state('');
	let model = $state('');
	let providerConfig = $state('');
	let requestHeaders = $state('{}');
	let imageConfig = $state('{}');
	let videoConfig = $state('{}');
	let visionDescriberConfig = $state('{}');
	let analyzeConfig = $state('{}');
	let supportsImages = $state(true);
	let maxTokens = $state(65536);
	let contextTokens = $state(0);

	onMount(async () => {
		try {
			tmpl = await admin.getTemplate($adminKey, $page.params.id!);
			name = tmpl.name;
			model = tmpl.model;
			providerConfig = JSON.stringify(tmpl.provider_config ?? {}, null, 2);
			requestHeaders = JSON.stringify(tmpl.request_headers ?? {}, null, 2);
			imageConfig = JSON.stringify(tmpl.image_config ?? {}, null, 2);
			videoConfig = JSON.stringify(tmpl.video_config ?? {}, null, 2);
			visionDescriberConfig = JSON.stringify(tmpl.vision_describer_config ?? {}, null, 2);
			analyzeConfig = JSON.stringify(tmpl.analyze_config ?? {}, null, 2);
			supportsImages = tmpl.supports_images === false ? false : true;
			maxTokens = tmpl.max_tokens;
			contextTokens = tmpl.context_tokens;
		} catch (e) {
			error = String(e);
		}
	});

	async function save() {
		error = '';
		saved = false;
		try {
			const parsedConfig = JSON.parse(providerConfig);
			const parsedHeaders = JSON.parse(requestHeaders);
			const parsedImageConfig = JSON.parse(imageConfig);
			const parsedVideoConfig = JSON.parse(videoConfig);
			const parsedVisionConfig = JSON.parse(visionDescriberConfig);
			const parsedAnalyzeConfig = JSON.parse(analyzeConfig);
			await admin.updateTemplate($adminKey, $page.params.id!, {
				name,
				model,
				provider_config: parsedConfig,
				request_headers: parsedHeaders,
				image_config: parsedImageConfig,
				video_config: parsedVideoConfig,
				vision_describer_config: parsedVisionConfig,
				analyze_config: parsedAnalyzeConfig,
				supports_images: supportsImages,
				max_tokens: maxTokens,
				context_tokens: contextTokens,
			});
			saved = true;
			setTimeout(() => saved = false, 2000);
		} catch (e) {
			error = String(e);
		}
	}

	async function deleteTemplate() {
		if (!confirm('Delete this template? Agent definitions using it will break.')) return;
		try {
			await admin.deleteTemplate($adminKey, $page.params.id!);
			goto('/admin/templates');
		} catch (e) {
			error = String(e);
		}
	}
</script>

<a href="/admin/templates" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Templates</a>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if tmpl}
	<div class="flex flex-col sm:flex-row sm:items-center justify-between mb-6 gap-3">
		<div>
			<h1 class="text-xl font-bold">{tmpl.name}</h1>
			<p class="text-xs text-gray-500 font-mono break-all">{tmpl.template_id}</p>
		</div>
		<div class="flex gap-2">
			{#if saved}
				<span class="text-green-400 text-sm self-center">Saved</span>
			{/if}
			<button onclick={save} class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">Save</button>
			<button onclick={deleteTemplate} class="bg-red-600/20 text-red-400 hover:bg-red-600/30 px-3 py-1.5 rounded text-sm">Delete</button>
		</div>
	</div>

	<div class="space-y-4 max-w-lg">
		<div>
			<label for="tmpl-name" class="block text-sm text-gray-400 mb-1">Name</label>
			<input id="tmpl-name" bind:value={name} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
		</div>
		<div>
			<label for="tmpl-model" class="block text-sm text-gray-400 mb-1">Model</label>
			<input id="tmpl-model" bind:value={model} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono" />
		</div>
		<div>
			<label for="tmpl-provider-config" class="block text-sm text-gray-400 mb-1">Provider Config (JSON)</label>
			<textarea id="tmpl-provider-config" bind:value={providerConfig} rows="6" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Contains base_url, api_key or api_key_env, plus optional flags like system_prompt_as_user_prefix. Never visible to tenants.</p>
		</div>
		<div>
			<label for="tmpl-request-headers" class="block text-sm text-gray-400 mb-1">Request Headers (JSON)</label>
			<textarea id="tmpl-request-headers" bind:value={requestHeaders} rows="4" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Extra HTTP headers sent with every LLM request. Never visible to tenants.</p>
		</div>
		<div>
			<label for="tmpl-image-config" class="block text-sm text-gray-400 mb-1">Image Config (JSON)</label>
			<textarea id="tmpl-image-config" bind:value={imageConfig} rows="7" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Separate GenerateImage settings. Never visible to tenants.</p>
			<details class="mt-2 text-xs text-gray-500">
				<summary class="cursor-pointer hover:text-gray-300">Guidelines and examples</summary>
				<ul class="list-disc pl-5 mt-2 space-y-1">
					<li>Keep image credentials separate from the main LLM provider credentials.</li>
					<li>Use <span class="font-mono">provider_config.api_key_env</span> for production keys.</li>
					<li>Supported providers are <span class="font-mono">openai</span> and <span class="font-mono">gemini</span>.</li>
					<li>Agents can pass <span class="font-mono">input_image_path</span> to GenerateImage to edit an existing VFS image.</li>
				</ul>
				<div class="grid gap-2 mt-2">
					<div>
						<div class="text-gray-400 mb-1">OpenAI</div>
						<pre class="overflow-x-auto bg-gray-950 border border-gray-800 rounded p-2 text-[11px] leading-4">{openAIImageConfigExample}</pre>
					</div>
					<div>
						<div class="text-gray-400 mb-1">Gemini / Nano Banana Pro</div>
						<pre class="overflow-x-auto bg-gray-950 border border-gray-800 rounded p-2 text-[11px] leading-4">{geminiImageConfigExample}</pre>
					</div>
				</div>
			</details>
		</div>
		<div>
			<label for="tmpl-video-config" class="block text-sm text-gray-400 mb-1">Video Config (JSON)</label>
			<textarea id="tmpl-video-config" bind:value={videoConfig} rows="7" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Separate GenerateVideo settings. Never visible to tenants.</p>
			<details class="mt-2 text-xs text-gray-500">
				<summary class="cursor-pointer hover:text-gray-300">Guidelines and examples</summary>
				<ul class="list-disc pl-5 mt-2 space-y-1">
					<li>Keep video credentials separate from the main LLM provider credentials.</li>
					<li>Use <span class="font-mono">provider_config.api_key_env</span> for production keys.</li>
					<li>Supported provider is <span class="font-mono">seedance</span> (Volcengine Ark / Doubao Seedance 2.0).</li>
					<li>Agents can pass <span class="font-mono">input_image_paths</span> to GenerateVideo (1 = first frame, 2 = first + last frame).</li>
				</ul>
				<div class="grid gap-2 mt-2">
					<div>
						<div class="text-gray-400 mb-1">Seedance 2.0 (Volcengine Ark)</div>
						<pre class="overflow-x-auto bg-gray-950 border border-gray-800 rounded p-2 text-[11px] leading-4">{seedanceVideoConfigExample}</pre>
					</div>
				</div>
			</details>
		</div>
		<div class="grid grid-cols-2 gap-3">
			<div>
				<label for="tmpl-max-tokens" class="block text-sm text-gray-400 mb-1">Max Tokens</label>
				<input id="tmpl-max-tokens" type="number" bind:value={maxTokens} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
			</div>
			<div>
				<label for="tmpl-context-tokens" class="block text-sm text-gray-400 mb-1">Context Window</label>
				<input id="tmpl-context-tokens" type="number" bind:value={contextTokens} placeholder="0 = default (128k)" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
			</div>
		</div>
		<div>
			<label class="flex items-center gap-2 text-sm text-gray-300">
				<input type="checkbox" bind:checked={supportsImages} class="rounded bg-gray-800 border-gray-700" />
				Model accepts image content blocks (multimodal)
			</label>
			<p class="text-xs text-gray-600 mt-1">Uncheck for text-only models. Inbound images will be replaced with a text placeholder; the agent can call <span class="font-mono">Read(path, vision_query="…")</span> to inspect them via the vision describer below.</p>
		</div>
		<div>
			<label for="tmpl-vision-describer-config" class="block text-sm text-gray-400 mb-1">Vision Describer Config (JSON)</label>
			<textarea id="tmpl-vision-describer-config" bind:value={visionDescriberConfig} rows="5" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Auxiliary image-to-text endpoint used by <span class="font-mono">Read(vision_query=…)</span>. Required when the primary model is non-multimodal. Empty <span class="font-mono">{'{}'}</span> disables. Shape: <span class="font-mono">{'{"endpoint":"https://api.openai.com/v1","model":"gpt-4o-mini","api_key_env":"OPENAI_API_KEY"}'}</span>.</p>
		</div>
		<div>
			<label for="tmpl-analyze-config" class="block text-sm text-gray-400 mb-1">Analyze Config (JSON)</label>
			<textarea id="tmpl-analyze-config" bind:value={analyzeConfig} rows="5" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Auxiliary chat-completions endpoint used by <span class="font-mono">Comma.analyze({'{'} prompt, data {'}'})</span> in JavaScript. Empty <span class="font-mono">{'{}'}</span> disables. Shape: <span class="font-mono">{'{"endpoint":"https://api.openai.com/v1","model":"gpt-4.1-mini","api_key_env":"OPENAI_API_KEY","max_tokens":2048}'}</span>.</p>
		</div>
	</div>
{/if}
