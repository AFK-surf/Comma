<script lang="ts">
	import { page } from '$app/stores';
	import { admin } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';
	import type { APIKeyCreateResponse, APIKeyInfo, Tenant } from '$lib/types';
	import { onMount } from 'svelte';

	let tenant = $state<Tenant | null>(null);
	let keys = $state<APIKeyInfo[]>([]);
	let error = $state('');
	let keyName = $state('default');
	let newKey = $state<APIKeyCreateResponse | null>(null);

	let faviconUrl = $state('');
	let defaultOgImageUrl = $state('');
	let spritesToken = $state('');
	let spritesBaseUrl = $state('');
	let spritesConnectorMetadataUrl = $state('');
	let configSaving = $state(false);
	let configMsg = $state('');
	let showSpritesToken = $state(false);

	const tenantId = $page.params.id!;

	function parseConfig(configStr: string): Record<string, any> {
		try {
			return JSON.parse(configStr || '{}');
		} catch {
			return {};
		}
	}

	function loadConfig(configStr: string) {
		const cfg = parseConfig(configStr);
		faviconUrl = cfg.favicon_url || '';
		defaultOgImageUrl = cfg.default_og_image_url || '';
		spritesToken = cfg.sprites?.token || '';
		spritesBaseUrl = cfg.sprites?.base_url || '';
		spritesConnectorMetadataUrl = cfg.sprites?.connector_metadata_url || '';
	}

	async function saveConfig() {
		if (!tenant) return;
		configSaving = true;
		configMsg = '';
		try {
			const cfg = parseConfig(tenant.config);
			if (faviconUrl.trim()) {
				cfg.favicon_url = faviconUrl.trim();
			} else {
				delete cfg.favicon_url;
			}
			if (defaultOgImageUrl.trim()) {
				cfg.default_og_image_url = defaultOgImageUrl.trim();
			} else {
				delete cfg.default_og_image_url;
			}

			if (spritesToken.trim() || spritesBaseUrl.trim() || spritesConnectorMetadataUrl.trim()) {
				cfg.sprites = {
					token: spritesToken.trim(),
					...(spritesBaseUrl.trim() ? { base_url: spritesBaseUrl.trim() } : {}),
					...(spritesConnectorMetadataUrl.trim()
						? { connector_metadata_url: spritesConnectorMetadataUrl.trim() }
						: {})
				};
			} else {
				delete cfg.sprites;
			}

			const nextConfig = JSON.stringify(cfg);
			await admin.updateTenant($adminKey, tenantId, nextConfig);
			tenant.config = nextConfig;
			configMsg = 'Saved';
			setTimeout(() => (configMsg = ''), 2000);
		} catch (e) {
			configMsg = String(e);
		} finally {
			configSaving = false;
		}
	}

	onMount(async () => {
		try {
			[tenant, keys] = await Promise.all([
				admin.getTenant($adminKey, tenantId),
				admin.listAPIKeys($adminKey, tenantId)
			]);
			if (tenant) loadConfig(tenant.config);
		} catch (e) {
			error = String(e);
		}
	});

	async function createKey() {
		try {
			newKey = await admin.createAPIKey($adminKey, tenantId, keyName);
			keys = await admin.listAPIKeys($adminKey, tenantId);
		} catch (e) {
			error = String(e);
		}
	}

	async function deleteKey(keyHash: string) {
		if (!confirm('Delete this API key? This cannot be undone.')) return;
		try {
			await admin.deleteAPIKey($adminKey, tenantId, keyHash);
			keys = keys.filter((k) => k.key_hash !== keyHash);
		} catch (e) {
			error = String(e);
		}
	}
</script>

<a href="/admin/tenants" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Tenants</a>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

{#if tenant}
	<h1 class="text-xl font-bold mb-1">{tenant.name}</h1>
	<p class="text-xs text-gray-500 font-mono mb-6">{tenant.tenant_id}</p>

	<h2 class="text-sm font-medium text-gray-400 mb-3">Create API Key</h2>
	<div class="flex gap-2 mb-4">
		<input bind:value={keyName} placeholder="Key name" class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
		<button onclick={createKey} class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">Create</button>
	</div>

	{#if newKey}
		<div class="bg-green-900/30 border border-green-800 rounded-lg p-3 mb-6">
			<p class="text-sm text-green-400 mb-1">Key created. Copy it now — it won't be shown again.</p>
			<code class="text-xs bg-gray-800 px-2 py-1 rounded select-all block">{newKey.key}</code>
		</div>
	{/if}

	<h2 class="text-sm font-medium text-gray-400 mb-3">API Keys</h2>
	<div class="overflow-x-auto">
		<table class="w-full text-sm">
			<thead>
				<tr class="text-left text-gray-500 border-b border-gray-800">
					<th class="pb-2 font-medium">Name</th>
					<th class="pb-2 font-medium">Key Hash</th>
					<th class="pb-2 font-medium">Created</th>
					<th class="pb-2 font-medium"></th>
				</tr>
			</thead>
			<tbody>
				{#each keys as k}
					<tr class="border-b border-gray-800/50">
						<td class="py-2">{k.name}</td>
						<td class="py-2 font-mono text-xs text-gray-400">{k.key_hash.slice(0, 16)}...</td>
						<td class="py-2 text-gray-400">{new Date(k.created_at * 1000).toLocaleDateString()}</td>
						<td class="py-2 text-right">
							<button onclick={() => deleteKey(k.key_hash)} class="text-red-400 hover:text-red-300 text-xs">Delete</button>
						</td>
					</tr>
				{/each}
				{#if keys.length === 0}
					<tr><td colspan="4" class="py-4 text-gray-600 text-center text-sm">No API keys</td></tr>
				{/if}
			</tbody>
		</table>
	</div>

	<h2 class="text-sm font-medium text-gray-400 mt-8 mb-3">Branding</h2>
	<div class="bg-gray-900 border border-gray-800 rounded-lg p-4 space-y-3">
		<label class="block">
			<span class="text-xs text-gray-400">Favicon URL <span class="text-gray-600">(injected into agent website HTML)</span></span>
			<input bind:value={faviconUrl} type="url" placeholder="https://example.com/favicon.ico" class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
		</label>
		<label class="block">
			<span class="text-xs text-gray-400">Default OG Image URL <span class="text-gray-600">(fallback when a site has no thumbnail image)</span></span>
			<input bind:value={defaultOgImageUrl} type="url" placeholder="https://example.com/og-image.png" class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
		</label>
	</div>

	<h2 class="text-sm font-medium text-gray-400 mt-8 mb-3">Integrations</h2>
	<div class="bg-gray-900 border border-gray-800 rounded-lg p-4 space-y-3">
		<div>
			<span class="text-xs text-gray-500 font-medium">Sprites (sprites.dev)</span>
		</div>
		<label class="block">
			<span class="text-xs text-gray-400">Sprites Token</span>
			<div class="flex gap-2 mt-1">
				<input bind:value={spritesToken} type={showSpritesToken ? 'text' : 'password'} placeholder="org-slug/org-id/token-id/token-value" class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
				<button onclick={() => (showSpritesToken = !showSpritesToken)} class="text-xs text-gray-500 hover:text-gray-300 px-2">{showSpritesToken ? 'Hide' : 'Show'}</button>
			</div>
		</label>
		<label class="block">
			<span class="text-xs text-gray-400">Base URL <span class="text-gray-600">(optional, defaults to https://api.sprites.dev)</span></span>
			<input bind:value={spritesBaseUrl} type="text" placeholder="https://api.sprites.dev" class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
		</label>
		<label class="block">
			<span class="text-xs text-gray-400">Connector metadata URL <span class="text-gray-600">(required for cloud-vm connector installs)</span></span>
			<input bind:value={spritesConnectorMetadataUrl} type="text" placeholder="https://release.example.com/cloud-vm/salix-connector/latest/metadata.json" class="w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500" />
		</label>
		<div class="rounded-lg border border-gray-800 bg-gray-950/60 px-3 py-2 text-xs leading-5 text-gray-400">
			Cloud VM install links also use the tenant browser rendering public base URL from <code class="font-mono text-[11px] text-gray-300">/admin/runtime/config</code>.
		</div>
	</div>

	<div class="flex items-center gap-3 mt-4">
		<button onclick={saveConfig} disabled={configSaving} class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-1.5 rounded text-sm">
			{configSaving ? 'Saving...' : 'Save'}
		</button>
		{#if configMsg}
			<span class="text-sm {configMsg === 'Saved' ? 'text-green-400' : 'text-red-400'}">{configMsg}</span>
		{/if}
	</div>

	<div class="mt-8 rounded-lg border border-gray-800 bg-gray-900/60 px-4 py-3 text-sm text-gray-400">
		Group-scoped IM provider connects are managed from <code class="font-mono text-xs text-gray-300">/admin/runtime/im</code>.
	</div>
{/if}
