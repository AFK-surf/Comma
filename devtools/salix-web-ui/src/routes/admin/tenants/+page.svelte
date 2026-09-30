<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { admin } from '$lib/api';
	import type { Tenant } from '$lib/types';
	import { onMount } from 'svelte';

	let name = $state('');
	let tenants = $state<Tenant[]>([]);
	let error = $state('');

	onMount(async () => {
		try {
			tenants = await admin.listTenants($adminKey);
		} catch (e) {
			error = String(e);
		}
	});

	async function create() {
		if (!name.trim()) return;
		try {
			const t = await admin.createTenant($adminKey, name.trim());
			tenants = [t, ...tenants];
			name = '';
			error = '';
		} catch (e) {
			error = String(e);
		}
	}
</script>

<h1 class="text-xl font-bold mb-6">Tenants</h1>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

<div class="flex gap-2 mb-6">
	<input bind:value={name} placeholder="New tenant name" class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
	<button onclick={create} class="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-sm">Create</button>
</div>

<div class="space-y-2">
	{#each tenants as t}
		<a href="/admin/tenants/{t.tenant_id}" class="block bg-gray-900 rounded-lg p-3 border border-gray-800 hover:border-gray-700">
			<div class="font-medium">{t.name}</div>
			<div class="text-xs text-gray-500 font-mono">{t.tenant_id}</div>
		</a>
	{/each}
	{#if tenants.length === 0}
		<p class="text-gray-600 text-sm">No tenants yet.</p>
	{/if}
</div>
