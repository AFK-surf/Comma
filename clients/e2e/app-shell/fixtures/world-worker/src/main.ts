// A page and a worker that answer each other on timers of their own:
// e2e/app-shell/world-worker.chromium.test.ts runs them as one world.
declare global {
  interface Window {
    worldFixture?: { start(): void; log: string[] };
  }
}

const log: string[] = [];
const list = document.createElement("ol");
document.getElementById("root")!.append(list);
const note = (line: string) => {
  log.push(line);
  const item = document.createElement("li");
  item.textContent = line;
  list.append(item);
};

const worker = new Worker(new URL("./answers.worker.ts", import.meta.url), {
  type: "module",
});
let started = 0;
// The page's time is its runtime's: what the test reads is page time.
// ast-grep-ignore: ts-test-clock
const since = () => performance.now() - started;
worker.addEventListener("message", (event) => {
  note(`${since()} ${String(event.data)}`);
});

window.worldFixture = {
  log,
  start() {
    // ast-grep-ignore: ts-test-clock
    started = performance.now();
    // Worker.postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    worker.postMessage("tasks");
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    worker.postMessage("inbox");
    // ast-grep-ignore: ts-test-timer
    setTimeout(() => note(`${since()} timer`), 20);
  },
};
