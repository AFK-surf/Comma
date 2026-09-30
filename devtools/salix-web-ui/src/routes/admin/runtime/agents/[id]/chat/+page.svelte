<script lang="ts">
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';

	const agentId = $derived($page.params.id!);

	onMount(() => {
		goto(`/admin/runtime/agents/${agentId}`, { replaceState: true });
	});
</script>

<p class="text-gray-500 text-sm">Redirecting to agent...</p>
