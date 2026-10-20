// Draws once from each random source when asked, and reports the values: an
// answer to the page's message, as the app's workers answer theirs
// (e2e/app-shell/support/workers.ts holds page time until it arrives).
self.addEventListener("message", () => {
  // DedicatedWorkerGlobalScope.postMessage has no targetOrigin overload.
  // oxlint-disable unicorn/require-post-message-target-origin
  // ast-grep-ignore: ts-test-random -- the seeded draws this fixture reports.
  self.postMessage({ random: Math.random(), uuid: crypto.randomUUID() });
});
