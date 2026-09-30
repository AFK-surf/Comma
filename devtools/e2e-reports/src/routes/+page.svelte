<script lang="ts">
	import { goto } from '$app/navigation';
	import { adminKey, backendUrl } from '$lib/stores/auth';

	let adminInput = $state($adminKey);
	let backendInput = $state($backendUrl);

	function saveBackend() {
		$backendUrl = backendInput;
	}

	function saveAdmin() {
		$adminKey = adminInput;
		if (adminInput) goto('/e2e-reports');
	}

	function clearAll() {
		$adminKey = '';
		$backendUrl = '';
		adminInput = '';
		backendInput = '';
	}
</script>

<div class="mx-auto mt-16 max-w-md">
	<h1 class="mb-8 text-2xl font-bold">Comma E2E Reports</h1>

	<div class="space-y-6">
		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<h2 class="mb-2 text-sm font-medium text-gray-400">Backend URL</h2>
			<div class="flex gap-2">
				<input
					type="text"
					bind:value={backendInput}
					placeholder="/v1"
					class="flex-1 rounded border border-gray-700 bg-gray-800 px-3 py-1.5 text-sm focus:border-gray-500 focus:outline-none"
				/>
				<button onclick={saveBackend} class="rounded bg-gray-700 px-3 py-1.5 text-sm hover:bg-gray-600">
					Set
				</button>
			</div>
			<p class="mt-1 text-xs text-gray-500">Leave empty for default (/v1)</p>
		</div>

		<div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
			<h2 class="mb-2 text-sm font-medium text-gray-400">Admin Key</h2>
			<div class="flex gap-2">
				<input
					type="password"
					bind:value={adminInput}
					placeholder="Admin API key"
					class="flex-1 rounded border border-gray-700 bg-gray-800 px-3 py-1.5 text-sm focus:border-gray-500 focus:outline-none"
				/>
				<button onclick={saveAdmin} class="rounded bg-gray-700 px-3 py-1.5 text-sm hover:bg-gray-600">
					Connect
				</button>
			</div>
		</div>

		{#if $adminKey || $backendUrl}
			<button onclick={clearAll} class="text-xs text-gray-500 hover:text-gray-300">Clear settings</button>
		{/if}
	</div>
</div>
