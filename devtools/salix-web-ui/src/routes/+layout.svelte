<script lang="ts">
	import '../app.css';
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';

	let { children } = $props();
	let menuOpen = $state(false);

	const navItems = $derived.by(() => {
		const items: { href: string; label: string }[] = [];
		if ($adminKey) {
			items.push({ href: '/admin/cluster', label: 'Cluster' });
			items.push({ href: '/admin/users', label: 'Users' });
			items.push({ href: '/admin/templates', label: 'Templates' });
			items.push({ href: '/admin/runtime/agents', label: 'Agents' });
			items.push({ href: '/admin/runtime/groups', label: 'Groups' });
			items.push({ href: '/admin/runtime/im', label: 'IM' });
			items.push({ href: '/admin/runtime/oauth', label: 'OAuth' });
			items.push({ href: '/admin/runtime/config', label: 'CBR' });
			items.push({ href: '/admin/runtime/envs', label: 'Environments' });
		}
		return items;
	});

	// Close menu on navigation.
	$effect(() => {
		$page.url.pathname;
		menuOpen = false;
	});
</script>

<div class="min-h-screen bg-gray-950 text-gray-100 md:flex">
	<!-- Mobile header -->
	<div class="md:hidden flex items-center justify-between bg-gray-900 border-b border-gray-800 px-4 py-3">
		<a href="/" class="text-lg font-bold tracking-tight text-white">Comma</a>
		{#if navItems.length > 0}
			<button onclick={() => menuOpen = !menuOpen} class="text-gray-400 hover:text-white p-1">
				<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
					{#if menuOpen}
						<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
					{:else}
						<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/>
					{/if}
				</svg>
			</button>
		{/if}
	</div>

	<!-- Sidebar: hidden on mobile unless menu open -->
	<nav class="{menuOpen ? 'flex' : 'hidden'} md:flex w-full md:w-56 bg-gray-900 md:border-r border-b md:border-b-0 border-gray-800 p-4 flex-col gap-1 shrink-0">
		<a href="/" class="text-lg font-bold mb-4 tracking-tight text-white hidden md:block">Comma</a>
		{#each navItems as item}
			<a
				href={item.href}
				class="px-3 py-1.5 rounded text-sm {$page.url.pathname.startsWith(item.href) ? 'bg-gray-800 text-white' : 'text-gray-400 hover:text-gray-200'}"
			>
				{item.label}
			</a>
		{/each}
		<div class="mt-4 md:mt-auto pt-4 border-t border-gray-800">
			<a href="/" class="text-xs text-gray-500 hover:text-gray-300">Settings</a>
		</div>
	</nav>
	<main class="flex-1 p-4 md:p-6 overflow-auto">
		{@render children()}
	</main>
</div>
