<script lang="ts">
	import { onMount } from 'svelte';
	import { runtimeDebug } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';
	import type { BrowserRenderingProvider, TenantBrowserRenderingConfig } from '$lib/types';

	let provider = $state<BrowserRenderingProvider>('cloudflare');

	// Cloudflare fields.
	let accountId = $state('');
	let apiToken = $state('');
	let apiBaseUrl = $state('');
	let keepAliveMS = $state('');
	let showAPIToken = $state(false);

	// Tinyfish fields.
	let tinyfishApiKey = $state('');
	let tinyfishApiBaseUrl = $state('');
	let showTinyfishApiKey = $state(false);

	// Baseline snapshot of the config as loaded from the server. `buildPatch`
	// diffs against this so unrelated fields (including credentials for the
	// inactive provider) are never silently mutated by a save.
	let initialConfig = $state<TenantBrowserRenderingConfig | null>(null);

	let loading = $state(true);
	let saving = $state(false);
	let error = $state('');
	let message = $state('');

	const inputClass = 'w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500';

	function normalizeProvider(value: string | undefined | null): BrowserRenderingProvider {
		return value === 'tinyfish' ? 'tinyfish' : 'cloudflare';
	}

	function loadConfig(config: TenantBrowserRenderingConfig | null | undefined) {
		const snapshot: TenantBrowserRenderingConfig = {
			provider: normalizeProvider(config?.provider),
			account_id: config?.account_id || '',
			api_token: config?.api_token || '',
			api_base_url: config?.api_base_url || '',
			keep_alive_ms: config?.keep_alive_ms || 0,
			tinyfish_api_key: config?.tinyfish_api_key || '',
			tinyfish_api_base_url: config?.tinyfish_api_base_url || ''
		};
		initialConfig = snapshot;
		provider = snapshot.provider!;
		accountId = snapshot.account_id || '';
		apiToken = snapshot.api_token || '';
		apiBaseUrl = snapshot.api_base_url || '';
		keepAliveMS = snapshot.keep_alive_ms ? String(snapshot.keep_alive_ms) : '';
		tinyfishApiKey = snapshot.tinyfish_api_key || '';
		tinyfishApiBaseUrl = snapshot.tinyfish_api_base_url || '';
	}

	function optionalString(value: string): string | undefined {
		const trimmed = value.trim();
		return trimmed || undefined;
	}

	function parseKeepAlive(raw: string): number | null {
		const trimmed = raw.trim();
		if (!trimmed) return null;
		const parsed = Number(trimmed);
		if (!Number.isInteger(parsed) || parsed <= 0) {
			throw new Error('Keep alive must be a positive integer');
		}
		return parsed;
	}

	// isFormEmpty returns true if every user-editable field is blank, mirroring
	// the "clear the whole config" gesture (Clear → Save). When true, buildPatch
	// emits `{}` so the backend deletes the browser_rendering section.
	function isFormEmpty(): boolean {
		return (
			!accountId.trim() &&
			!apiToken.trim() &&
			!apiBaseUrl.trim() &&
			!keepAliveMS.trim() &&
			!tinyfishApiKey.trim() &&
			!tinyfishApiBaseUrl.trim()
		);
	}

	// buildPatch produces a PATCH body that only touches fields the user
	// actually changed. Provider switches additionally send `null` for the
	// previous provider's fields so the switch is atomic, never carrying stale
	// credentials across a provider change.
	function buildPatch(): Record<string, unknown> {
		if (isFormEmpty()) {
			return {};
		}
		const init = initialConfig || {};
		const prevProvider = normalizeProvider(init.provider);
		const providerChanged = provider !== prevProvider;

		const patch: Record<string, unknown> = {};

		// Always send `provider` when it changed; otherwise omit it.
		if (providerChanged) {
			patch.provider = provider;
		}

		if (provider === 'cloudflare') {
			diffString(patch, 'account_id', accountId, init.account_id);
			diffString(patch, 'api_token', apiToken, init.api_token);
			diffString(patch, 'api_base_url', apiBaseUrl, init.api_base_url);
			const nextKeepAlive = parseKeepAlive(keepAliveMS);
			const prevKeepAlive = init.keep_alive_ms || 0;
			if ((nextKeepAlive ?? 0) !== prevKeepAlive) {
				patch.keep_alive_ms = nextKeepAlive;
			}
			if (providerChanged) {
				// Atomically clear the other provider's credentials.
				patch.tinyfish_api_key = null;
				patch.tinyfish_api_base_url = null;
			}
		} else {
			diffString(patch, 'tinyfish_api_key', tinyfishApiKey, init.tinyfish_api_key);
			diffString(patch, 'tinyfish_api_base_url', tinyfishApiBaseUrl, init.tinyfish_api_base_url);
			if (providerChanged) {
				patch.account_id = null;
				patch.api_token = null;
				patch.api_base_url = null;
				patch.keep_alive_ms = null;
			}
		}
		return patch;
	}

	function diffString(
		patch: Record<string, unknown>,
		key: string,
		current: string,
		initial: string | undefined
	) {
		const next = optionalString(current) ?? null;
		const prev = initial ? initial : null;
		if ((next ?? '') !== (prev ?? '')) {
			patch[key] = next;
		}
	}

	async function load() {
		loading = true;
		error = '';
		message = '';
		try {
			loadConfig(await runtimeDebug.getBrowserRenderingConfig($adminKey));
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		} finally {
			loading = false;
		}
	}

	async function save() {
		saving = true;
		error = '';
		message = '';
		try {
			const patch = buildPatch();
			const saved = await runtimeDebug.updateBrowserRenderingConfig(
				$adminKey,
				patch as TenantBrowserRenderingConfig
			);
			loadConfig(saved);
			message = 'Saved';
			setTimeout(() => (message = ''), 2000);
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		} finally {
			saving = false;
		}
	}

	function clearForm() {
		accountId = '';
		apiToken = '';
		apiBaseUrl = '';
		keepAliveMS = '';
		tinyfishApiKey = '';
		tinyfishApiBaseUrl = '';
		error = '';
		message = '';
	}

	onMount(() => {
		void load();
	});
</script>

<div class="flex items-start justify-between gap-4 mb-6 flex-wrap">
	<div>
		<h1 class="text-xl font-bold">Interactive Login &mdash; Browser Rendering</h1>
		<p class="text-sm text-gray-500 mt-1">Credentials for the remote browser used by the RequestInteractiveLogin tool.</p>
	</div>
	<button onclick={load} class="bg-gray-800 hover:bg-gray-700 px-3 py-1.5 rounded text-sm">Refresh</button>
</div>

{#if error}
	<p class="text-red-400 text-sm mb-4">{error}</p>
{/if}

{#if loading}
	<p class="text-sm text-gray-500">Loading...</p>
{:else}
	<div class="bg-gray-900 border border-gray-800 rounded-lg p-4 space-y-4 max-w-3xl">
		<label class="block">
			<span class="text-xs text-gray-400">Provider</span>
			<select bind:value={provider} class="{inputClass} font-sans">
				<option value="cloudflare">Cloudflare Browser Rendering</option>
				<option value="tinyfish">Tinyfish Browser API</option>
			</select>
		</label>

		{#if provider === 'cloudflare'}
			<label class="block">
				<span class="text-xs text-gray-400">Account ID</span>
				<input bind:value={accountId} type="text" placeholder="Cloudflare account ID" class={inputClass} />
			</label>

			<label class="block">
				<span class="text-xs text-gray-400">API token</span>
				<div class="flex gap-2 mt-1">
					<input bind:value={apiToken} type={showAPIToken ? 'text' : 'password'} placeholder="Cloudflare API token" class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
					<button onclick={() => (showAPIToken = !showAPIToken)} class="text-xs text-gray-500 hover:text-gray-300 px-2">{showAPIToken ? 'Hide' : 'Show'}</button>
				</div>
			</label>

			<div class="grid gap-3 md:grid-cols-2">
				<label class="block">
					<span class="text-xs text-gray-400">API base URL <span class="text-gray-600">(optional)</span></span>
					<input bind:value={apiBaseUrl} type="text" placeholder="https://api.cloudflare.com/client/v4" class={inputClass} />
				</label>
				<label class="block">
					<span class="text-xs text-gray-400">Keep alive ms <span class="text-gray-600">(optional)</span></span>
					<input bind:value={keepAliveMS} type="number" min="1" step="1" placeholder="600000" class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
				</label>
			</div>
		{:else}
			<label class="block">
				<span class="text-xs text-gray-400">Tinyfish API key</span>
				<div class="flex gap-2 mt-1">
					<input bind:value={tinyfishApiKey} type={showTinyfishApiKey ? 'text' : 'password'} placeholder="tf_..." class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
					<button onclick={() => (showTinyfishApiKey = !showTinyfishApiKey)} class="text-xs text-gray-500 hover:text-gray-300 px-2">{showTinyfishApiKey ? 'Hide' : 'Show'}</button>
				</div>
				<p class="text-xs text-gray-500 mt-1">Create at <span class="font-mono">agent.tinyfish.ai/api-keys</span>.</p>
			</label>

			<label class="block">
				<span class="text-xs text-gray-400">API base URL <span class="text-gray-600">(optional)</span></span>
				<input bind:value={tinyfishApiBaseUrl} type="text" placeholder="https://api.browser.tinyfish.ai" class={inputClass} />
			</label>
		{/if}
	</div>

	<div class="flex items-center gap-3 mt-4 mb-8">
		<button onclick={save} disabled={saving} class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-1.5 rounded text-sm">
			{saving ? 'Saving...' : 'Save'}
		</button>
		<button onclick={clearForm} disabled={saving} class="bg-gray-800 hover:bg-gray-700 disabled:opacity-50 px-3 py-1.5 rounded text-sm" title="Reset all fields. Click Save after to delete the stored configuration.">Clear</button>
		{#if message}
			<span class="text-sm text-green-400">{message}</span>
		{/if}
	</div>
{/if}
