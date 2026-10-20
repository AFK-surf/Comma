/// <reference lib="webworker" />
// Answers each question after a delay of its own: "tasks" later than "inbox".
const scope = self as unknown as DedicatedWorkerGlobalScope;

scope.addEventListener("message", (event) => {
  const question = String(event.data);
  // ast-grep-ignore: ts-test-timer
  setTimeout(
    // A worker's postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    () => scope.postMessage(`answer to ${question}`),
    question === "tasks" ? 30 : 10
  );
});
