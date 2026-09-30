<script lang="ts">
	import { adminKey } from '$lib/stores/auth';
	import { runtimeDebug } from '$lib/api';
	import { goto } from '$app/navigation';

	let name = $state('');
	let error = $state('');

	async function submit() {
		const trimmedName = name.trim();
		if (!trimmedName) return;
		try {
			const group = await runtimeDebug.createGroup($adminKey, { name: trimmedName });
			goto(`/admin/runtime/groups/${group.group_id}`);
		} catch (e) {
			error = String(e);
		}
	}
</script>

<a href="/admin/runtime/groups" class="text-sm text-gray-500 hover:text-gray-300 mb-4 inline-block">&larr; Groups</a>
<h1 class="text-xl font-bold mb-6">New Agent Group</h1>

{#if error}<p class="text-red-400 text-sm mb-4">{error}</p>{/if}

<div class="max-w-lg space-y-4">
	<div>
		<label for="group-name" class="block text-sm text-gray-400 mb-1">Name</label>
		<input id="group-name" bind:value={name} class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500" />
	</div>
	<button onclick={submit} disabled={!name.trim()} class="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-4 py-2 rounded text-sm">Create</button>
</div>
