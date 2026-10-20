/// <reference lib="webworker" />
// Asks the server it is told of for an echo, and tells the page the answer.
const own = self as unknown as DedicatedWorkerGlobalScope;

own.addEventListener("message", (event) => {
  void fetch(String(event.data), { method: "POST", body: "from the worker" })
    .then((response) => response.json())
    // A worker's postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    .then((body) => own.postMessage(`echo ${JSON.stringify(body)}`));
});
