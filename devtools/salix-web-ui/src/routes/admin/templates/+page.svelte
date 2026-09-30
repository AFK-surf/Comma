<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { admin } from '$lib/api';
	import type { AgentTemplate } from '$lib/types';
	import { defaultImageConfig, geminiImageConfigExample, openAIImageConfigExample } from '$lib/image-config';
	import { defaultVideoConfig, seedanceVideoConfigExample } from '$lib/video-config';
	import { onMount } from 'svelte';

	let templates = $state<AgentTemplate[]>([]);
	let error = $state('');
	let showCreate = $state(false);

	// Create form.
	let newName = $state('');
	let newModel = $state('');
	let newProviderConfig = $state('{\n  "base_url": "",\n  "api_key_env": ""\n}');
	let newRequestHeaders = $state('{}');
	let newImageConfig = $state(defaultImageConfig);
	let newVideoConfig = $state(defaultVideoConfig);
	let newMaxTokens = $state(65536);
	let newContextTokens = $state(0);
	let newSupportsImages = $state(true);
	let newVisionDescriberConfig = $state('{}');
	let newAnalyzeConfig = $state('{}');

	async function load() {
		try {
			templates = await admin.listTemplates($adminKey);
		} catch (e) {
			error = String(e);
		}
	}

	onMount(load);

	async function create() {
		try {
			const parsedConfig = JSON.parse(newProviderConfig);
			const parsedHeaders = JSON.parse(newRequestHeaders);
			const parsedImageConfig = JSON.parse(newImageConfig);
			const parsedVideoConfig = JSON.parse(newVideoConfig);
			const parsedVisionConfig = JSON.parse(newVisionDescriberConfig);
			const parsedAnalyzeConfig = JSON.parse(newAnalyzeConfig);
			await admin.createTemplate($adminKey, {
				name: newName,
				model: newModel,
				provider_config: parsedConfig,
				request_headers: parsedHeaders,
				image_config: parsedImageConfig,
				video_config: parsedVideoConfig,
				vision_describer_config: parsedVisionConfig,
				analyze_config: parsedAnalyzeConfig,
				supports_images: newSupportsImages,
				max_tokens: newMaxTokens,
				context_tokens: newContextTokens,
			});
			newName = '';
			newModel = '';
			newImageConfig = defaultImageConfig;
			newVideoConfig = defaultVideoConfig;
			newVisionDescriberConfig = '{}';
			newAnalyzeConfig = '{}';
			newSupportsImages = true;
			showCreate = false;
			load();
		} catch (e) {
			error = String(e);
		}
	}

	async function deleteTemplate(id: string) {
		if (!confirm('Delete this template?')) return;
		try {
			await admin.deleteTemplate($adminKey, id);
			load();
		} catch (e) {
			error = String(e);
		}
	}
</script>

<div class="flex items-center justify-between mb-6">
	<h1 class="text-xl font-bold">Agent Templates</h1>
	<button onclick={() => showCreate = !showCreate} class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">
		{showCreate ? 'Cancel' : 'New Template'}
	</button>
</div>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if showCreate}
	<div class="bg-gray-900 border border-gray-800 rounded p-4 mb-6 max-w-lg space-y-3">
		<div>
			<label for="new-tmpl-name" class="block text-sm text-gray-400 mb-1">Name</label>
			<input id="new-tmpl-name" bind:value={newName} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
		</div>
		<div>
			<label for="new-tmpl-model" class="block text-sm text-gray-400 mb-1">Model</label>
			<input id="new-tmpl-model" bind:value={newModel} placeholder="claude-sonnet-4-20250514" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
		</div>
		<div>
			<label for="new-tmpl-provider-config" class="block text-sm text-gray-400 mb-1">Provider Config (JSON)</label>
			<textarea id="new-tmpl-provider-config" bind:value={newProviderConfig} rows="4" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
		</div>
		<div>
			<label for="new-tmpl-request-headers" class="block text-sm text-gray-400 mb-1">Request Headers (JSON)</label>
			<textarea id="new-tmpl-request-headers" bind:value={newRequestHeaders} rows="3" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Extra HTTP headers sent with every LLM request.</p>
		</div>
		<div>
			<label for="new-tmpl-image-config" class="block text-sm text-gray-400 mb-1">Image Config (JSON)</label>
			<textarea id="new-tmpl-image-config" bind:value={newImageConfig} rows="7" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Separate GenerateImage settings. Use an empty JSON object to disable image generation.</p>
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
			<label for="new-tmpl-video-config" class="block text-sm text-gray-400 mb-1">Video Config (JSON)</label>
			<textarea id="new-tmpl-video-config" bind:value={newVideoConfig} rows="7" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Separate GenerateVideo settings. Use an empty JSON object to disable video generation.</p>
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
				<label for="new-tmpl-max-tokens" class="block text-sm text-gray-400 mb-1">Max Tokens</label>
				<input id="new-tmpl-max-tokens" type="number" bind:value={newMaxTokens} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
			</div>
			<div>
				<label for="new-tmpl-context-tokens" class="block text-sm text-gray-400 mb-1">Context Window</label>
				<input id="new-tmpl-context-tokens" type="number" bind:value={newContextTokens} placeholder="0 = default" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
			</div>
		</div>
		<div>
			<label class="flex items-center gap-2 text-sm text-gray-300">
				<input type="checkbox" bind:checked={newSupportsImages} class="rounded bg-gray-800 border-gray-700" />
				Model accepts image content blocks (multimodal)
			</label>
			<p class="text-xs text-gray-600 mt-1">Uncheck for text-only models. Inbound images will be replaced with a text placeholder; the agent can call <span class="font-mono">Read(path, vision_query="…")</span> to inspect them via the vision describer below.</p>
		</div>
		<div>
			<label for="new-tmpl-vision-describer-config" class="block text-sm text-gray-400 mb-1">Vision Describer Config (JSON)</label>
			<textarea id="new-tmpl-vision-describer-config" bind:value={newVisionDescriberConfig} rows="5" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Auxiliary image-to-text endpoint used by <span class="font-mono">Read(vision_query=…)</span>. Required when the primary model is non-multimodal. Empty <span class="font-mono">{'{}'}</span> disables. Shape: <span class="font-mono">{'{"endpoint":"https://api.openai.com/v1","model":"gpt-4o-mini","api_key_env":"OPENAI_API_KEY"}'}</span>.</p>
		</div>
		<div>
			<label for="new-tmpl-analyze-config" class="block text-sm text-gray-400 mb-1">Analyze Config (JSON)</label>
			<textarea id="new-tmpl-analyze-config" bind:value={newAnalyzeConfig} rows="5" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500 font-mono"></textarea>
			<p class="text-xs text-gray-600 mt-1">Auxiliary chat-completions endpoint used by <span class="font-mono">Comma.analyze({'{'} prompt, data {'}'})</span> in JavaScript. Empty <span class="font-mono">{'{}'}</span> disables. Shape: <span class="font-mono">{'{"endpoint":"https://api.openai.com/v1","model":"gpt-4.1-mini","api_key_env":"OPENAI_API_KEY","max_tokens":2048}'}</span>.</p>
		</div>
		<button onclick={create} class="bg-blue-600 hover:bg-blue-500 px-4 py-2 rounded text-sm">Create</button>
	</div>
{/if}

<div class="overflow-x-auto">
<table class="w-full text-sm">
	<thead>
		<tr class="text-left text-gray-500 border-b border-gray-800">
			<th class="pb-2 font-medium">Name</th>
			<th class="pb-2 font-medium">Model</th>
			<th class="pb-2 font-medium">Multimodal</th>
			<th class="pb-2 font-medium">Image Gen</th>
			<th class="pb-2 font-medium">Video Gen</th>
			<th class="pb-2 font-medium">Vision</th>
			<th class="pb-2 font-medium">Analyze</th>
			<th class="pb-2 font-medium">Max Tokens</th>
			<th class="pb-2 font-medium">Context</th>
			<th class="pb-2 font-medium"></th>
		</tr>
	</thead>
	<tbody>
		{#each templates as t}
			<tr class="border-b border-gray-800/50 hover:bg-gray-900/50">
				<td class="py-2"><a href="/admin/templates/{t.template_id}" class="text-blue-400 hover:underline">{t.name}</a></td>
				<td class="py-2 text-gray-400 font-mono text-xs">{t.model}</td>
				<td class="py-2 text-gray-400">{t.supports_images === false ? 'no' : 'yes'}</td>
				<td class="py-2 text-gray-400 font-mono text-xs">{typeof t.image_config?.model === 'string' && t.image_config.model ? t.image_config.model : 'disabled'}</td>
				<td class="py-2 text-gray-400 font-mono text-xs">{typeof t.video_config?.model === 'string' && t.video_config.model ? t.video_config.model : 'disabled'}</td>
				<td class="py-2 text-gray-400 font-mono text-xs">{typeof t.vision_describer_config?.model === 'string' && t.vision_describer_config.model ? t.vision_describer_config.model : 'disabled'}</td>
				<td class="py-2 text-gray-400 font-mono text-xs">{typeof t.analyze_config?.model === 'string' && t.analyze_config.model ? t.analyze_config.model : 'disabled'}</td>
				<td class="py-2 text-gray-400">{t.max_tokens.toLocaleString()}</td>
				<td class="py-2 text-gray-400">{t.context_tokens ? t.context_tokens.toLocaleString() : 'default'}</td>
				<td class="py-2 text-right">
					<button onclick={() => deleteTemplate(t.template_id)}
						class="text-red-500/60 hover:text-red-400 text-xs">delete</button>
				</td>
			</tr>
		{/each}
		{#if templates.length === 0}
			<tr><td colspan="10" class="py-4 text-gray-600 text-center">No templates yet.</td></tr>
		{/if}
	</tbody>
</table>
</div>
