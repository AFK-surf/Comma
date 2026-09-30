<script lang="ts">
	import { onMount } from 'svelte';
	import { runtimeDebug } from '$lib/api';
	import { adminKey } from '$lib/stores/auth';
	import { KNOWN_OAUTH_PROVIDERS, oauthProviderLabel } from '$lib/oauth';
	import type { OAuthProviderApp } from '$lib/types';

	let apps = $state<OAuthProviderApp[]>([]);
	let loading = $state(true);
	let error = $state('');
	let message = $state('');

	type Draft = {
		client_id: string;
		client_secret: string;
		showSecret: boolean;
		saving: boolean;
	};

	function emptyDraft(): Draft {
		return { client_id: '', client_secret: '', showSecret: false, saving: false };
	}

	let drafts = $state<Record<string, Draft>>(
		Object.fromEntries(KNOWN_OAUTH_PROVIDERS.map((p) => [p, emptyDraft()])),
	);

	const inputClass =
		'w-full mt-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm font-mono focus:outline-none focus:border-gray-500';

	function findApp(p: string): OAuthProviderApp | undefined {
		return apps.find((a) => a.provider === p);
	}

	function syncDrafts() {
		const next: Record<string, Draft> = {};
		for (const p of KNOWN_OAUTH_PROVIDERS) {
			const existing = drafts[p];
			const app = findApp(p);
			next[p] = {
				client_id: app?.client_id || '',
				client_secret: '',
				showSecret: existing?.showSecret ?? false,
				saving: false,
			};
		}
		drafts = next;
	}

	async function loadApps() {
		loading = true;
		error = '';
		try {
			apps = await runtimeDebug.listOAuthProviderApps($adminKey);
			syncDrafts();
		} catch (e) {
			error = String(e);
		} finally {
			loading = false;
		}
	}

	onMount(loadApps);

	async function saveProvider(provider: string) {
		const draft = drafts[provider];
		if (!draft) return;
		const clientId = draft.client_id.trim();
		if (!clientId) {
			error = `${oauthProviderLabel(provider)}: client_id is required`;
			return;
		}
		drafts[provider] = { ...draft, saving: true };
		error = '';
		message = '';
		try {
			const body: { client_id: string; client_secret?: string } = { client_id: clientId };
			if (draft.client_secret.trim() !== '') {
				body.client_secret = draft.client_secret.trim();
			}
			const next = await runtimeDebug.updateOAuthProviderApp($adminKey, provider, body);
			apps = apps.filter((a) => a.provider !== provider).concat(next);
			drafts[provider] = {
				client_id: next.client_id || '',
				client_secret: '',
				showSecret: false,
				saving: false,
			};
			message = `${oauthProviderLabel(provider)} app saved.`;
		} catch (e) {
			drafts[provider] = { ...draft, saving: false };
			error = String(e);
		}
	}

	async function clearProvider(provider: string) {
		if (!confirm(`Remove ${oauthProviderLabel(provider)} OAuth client config? Existing connected accounts continue to work until refresh fails.`)) return;
		error = '';
		message = '';
		try {
			await runtimeDebug.deleteOAuthProviderApp($adminKey, provider);
			apps = apps.filter((a) => a.provider !== provider);
			drafts[provider] = emptyDraft();
			message = `${oauthProviderLabel(provider)} app removed.`;
		} catch (e) {
			error = String(e);
		}
	}
</script>

<div class="flex items-center justify-between mb-4">
	<h1 class="text-xl font-bold">OAuth providers</h1>
	<a href="/admin/runtime/groups" class="text-sm text-gray-400 hover:text-gray-200">Manage group connections &rarr;</a>
</div>

<p class="text-sm text-gray-400 mb-4 max-w-2xl">
	Configure tenant-wide OAuth client credentials. After saving an app here, connect it
	to an agent group from the group's detail page so agents can run authenticated CLI
	commands (e.g. <code class="text-gray-300">gh</code>, Linear scripts, Notion API tools)
	without ever seeing the raw token.
</p>

{#if loading}
	<p class="text-gray-500">Loading...</p>
{:else}
	{#if error}<p class="text-red-400 text-sm mb-3">{error}</p>{/if}
	{#if message}<p class="text-emerald-400 text-sm mb-3">{message}</p>{/if}

	<div class="grid gap-4 md:grid-cols-2 max-w-4xl">
		{#each KNOWN_OAUTH_PROVIDERS as provider}
			{@const app = findApp(provider)}
			{@const draft = drafts[provider]}
			<div class="border border-gray-800 rounded p-4 bg-gray-900/50">
				<div class="flex items-center justify-between mb-3">
					<div>
						<div class="font-semibold text-base">{oauthProviderLabel(provider)}</div>
						<div class="text-xs text-gray-500 font-mono">{provider}</div>
					</div>
					<span
						class="text-xs px-2 py-0.5 rounded {app?.client_secret_configured ? 'bg-emerald-600/20 text-emerald-300' : 'bg-gray-800 text-gray-500'}"
					>
						{app?.client_secret_configured ? 'Configured' : 'Not configured'}
					</span>
				</div>

				<label class="block text-xs text-gray-400">Client ID
					<input
						type="text"
						class={inputClass}
						bind:value={draft.client_id}
						placeholder="OAuth app client_id"
						autocomplete="off"
					/>
				</label>

				<label class="block text-xs text-gray-400 mt-3">Client secret
					<div class="flex gap-2 mt-1">
						<input
							type={draft.showSecret ? 'text' : 'password'}
							class={inputClass + ' mt-0'}
							bind:value={draft.client_secret}
							placeholder={app?.client_secret_configured ? '••••••••• (leave blank to keep)' : 'Enter client_secret'}
							autocomplete="off"
						/>
						<button
							type="button"
							onclick={() => (drafts[provider] = { ...draft, showSecret: !draft.showSecret })}
							class="px-2 py-1.5 rounded border border-gray-700 text-xs text-gray-400 hover:text-gray-200"
						>
							{draft.showSecret ? 'Hide' : 'Show'}
						</button>
					</div>
				</label>

				<div class="flex justify-between items-center mt-4">
					<button
						type="button"
						onclick={() => saveProvider(provider)}
						disabled={draft.saving}
						class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-3 py-1.5 rounded text-sm"
					>
						{draft.saving ? 'Saving...' : 'Save'}
					</button>
					{#if app?.client_id || app?.client_secret_configured}
						<button
							type="button"
							onclick={() => clearProvider(provider)}
							class="text-red-400 hover:text-red-300 text-xs"
						>
							Remove app
						</button>
					{/if}
				</div>
			</div>
		{/each}
	</div>
{/if}
