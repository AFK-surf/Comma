<script lang="ts">
	const traceViewerSrc = '/e2e-reports/trace-viewer/index.html';
</script>

<div class="mb-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
	<div>
		<h1 class="text-xl font-semibold">Playwright Trace Viewer</h1>
		<p class="mt-1 text-sm text-gray-500">Open a trace.zip downloaded from a report or GitHub artifact.</p>
	</div>
	<a href={traceViewerSrc} target="_blank" rel="noreferrer" class="rounded bg-gray-800 px-3 py-1.5 text-sm hover:bg-gray-700">
		New tab
	</a>
</div>

<iframe
	title="Playwright Trace Viewer"
	src={traceViewerSrc}
	class="h-[calc(100vh-9rem)] w-full rounded border border-gray-800 bg-white"
></iframe>
