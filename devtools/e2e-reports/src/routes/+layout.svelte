<script lang="ts">
	import '../app.css';
	import { page } from '$app/stores';
	import { adminKey } from '$lib/stores/auth';

	let { children } = $props();
	let menuOpen = $state(false);

	const navItems = $derived.by(() => {
		if (!$adminKey) return [{ href: '/', label: 'Settings' }];
		return [
			{ href: '/e2e-reports', label: 'Overview' },
			{ href: '/e2e-reports/runs', label: 'Runs' },
			{ href: '/e2e-reports/artifacts', label: 'Artifacts' },
			{ href: '/e2e-reports/trace-viewer', label: 'Trace Viewer' }
		];
	});

	$effect(() => {
		$page.url.pathname;
		menuOpen = false;
	});
</script>

<div class="min-h-screen bg-gray-950 text-gray-100 md:flex">
	<div class="flex items-center justify-between border-b border-gray-800 bg-gray-900 px-4 py-3 md:hidden">
		<a href="/e2e-reports" class="text-lg font-bold tracking-tight text-white">comma e2e</a>
		<button onclick={() => (menuOpen = !menuOpen)} class="p-1 text-gray-400 hover:text-white">
			<span class="sr-only">Toggle navigation</span>
			{#if menuOpen}
				<span class="text-xl leading-none">x</span>
			{:else}
				<span class="text-xl leading-none">=</span>
			{/if}
		</button>
	</div>

	<nav class="{menuOpen ? 'flex' : 'hidden'} w-full shrink-0 flex-col gap-1 border-b border-gray-800 bg-gray-900 p-4 md:flex md:w-56 md:border-b-0 md:border-r">
		<a href="/e2e-reports" class="mb-4 hidden text-lg font-bold tracking-tight text-white md:block">
			comma e2e
		</a>
		{#each navItems as item}
			<a
				href={item.href}
				class="rounded px-3 py-1.5 text-sm {$page.url.pathname === item.href || $page.url.pathname.startsWith(item.href + '/') ? 'bg-gray-800 text-white' : 'text-gray-400 hover:text-gray-200'}"
			>
				{item.label}
			</a>
		{/each}
		<div class="mt-4 border-t border-gray-800 pt-4 md:mt-auto">
			<a href="/" class="text-xs text-gray-500 hover:text-gray-300">Settings</a>
		</div>
	</nav>

	<main class="flex-1 overflow-auto p-4 md:p-6">
		{@render children()}
	</main>
</div>
