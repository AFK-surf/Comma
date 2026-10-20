// A page with a worker of its own: e2e/app-shell/page-random.chromium.test.ts
// reads what the worker draws.
declare global {
  interface Window {
    workerDraws?: () => Promise<unknown>;
  }
}

window.workerDraws = () =>
  new Promise((resolve) => {
    const worker = new Worker(new URL("./random.worker.ts", import.meta.url), {
      type: "module",
    });
    worker.addEventListener("message", (event) => {
      worker.terminate();
      resolve(event.data);
    });
    // Worker.postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    worker.postMessage("draw");
  });
