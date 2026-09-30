<script lang="ts">
	let { status }: { status: string } = $props();

	const colors: Record<string, string> = {
		running: 'bg-green-500/20 text-green-400',
		active: 'bg-green-500/20 text-green-400',
		queued: 'bg-yellow-500/20 text-yellow-400',
		paused: 'bg-blue-500/20 text-blue-400',
		waiting: 'bg-purple-500/20 text-purple-400',
		completed: 'bg-gray-500/20 text-gray-400',
		failed: 'bg-red-500/20 text-red-400',
		cancelled: 'bg-orange-500/20 text-orange-400',
		created: 'bg-gray-500/20 text-gray-400',
		draining: 'bg-yellow-500/20 text-yellow-400',
		dead: 'bg-red-500/20 text-red-400',
		connected: 'bg-green-500/20 text-green-400',
		disconnected: 'bg-red-500/20 text-red-400',
	};
</script>

<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium {colors[status] || 'bg-gray-500/20 text-gray-400'}">
	{status}
</span>
