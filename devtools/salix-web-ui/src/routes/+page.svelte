<script lang="ts">
	import { adminKey, backendUrl } from '$lib/stores/auth';
	import { goto } from '$app/navigation';

	let adminInput = $state($adminKey);
	let backendInput = $state($backendUrl);

	function saveAdmin() {
		$adminKey = adminInput;
		if (adminInput) goto('/admin/cluster');
	}

	function saveBackend() {
		$backendUrl = backendInput;
	}

	function clearAll() {
		$adminKey = '';
		$backendUrl = '';
		adminInput = '';
		backendInput = '';
	}
</script>

<div class="max-w-md mx-auto mt-20">
	<h1 class="text-2xl font-bold mb-8">Comma</h1>

	<div class="space-y-6">
		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<h2 class="text-sm font-medium text-gray-400 mb-2">Backend URL</h2>
			<div class="flex gap-2">
				<input
					type="text"
					bind:value={backendInput}
					placeholder="/v1"
					class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
				/>
				<button onclick={saveBackend} class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-sm">Set</button>
			</div>
			<p class="text-xs text-gray-500 mt-1">Leave empty for default (/v1)</p>
		</div>

		<div class="bg-gray-900 rounded-lg p-4 border border-gray-800">
			<h2 class="text-sm font-medium text-gray-400 mb-2">Admin Session</h2>
			<div class="flex gap-2">
				<input
					type="password"
					bind:value={adminInput}
					placeholder="Admin bearer token or comma_sess_..."
					class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-gray-500"
				/>
				<button onclick={saveAdmin} class="bg-gray-700 hover:bg-gray-600 px-3 py-1.5 rounded text-sm">Connect</button>
			</div>
		</div>

		{#if $adminKey}
			<button onclick={clearAll} class="text-xs text-gray-500 hover:text-gray-300">Clear all keys</button>
		{/if}
	</div>
</div>
