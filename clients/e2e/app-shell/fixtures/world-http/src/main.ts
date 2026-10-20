// A page and its worker that ask one server: the page for a streamed reply
// and an echo, the worker for an echo. e2e/app-shell/world-http.chromium.test.ts
// runs the three as one world.
declare global {
  interface Window {
    worldHttp?: {
      log: string[];
      start(origin: string): void;
      /** Asks for a streamed reply and aborts it after `ms`. */
      abortAfter(origin: string, ms: number): void;
      /** Asks for `count` echoes, one after the other. */
      echoes(origin: string, count: number): Promise<void>;
      /**
       * Asks for seven echoes at once. The browser sends the first one last:
       * it asks the server's leave first (a preflight), and meanwhile the six
       * after it, which need none, take every connection it opens to the server.
       */
      firstLeavesLast(origin: string): void;
      /** Asks for an echo the browser refuses to send: the server is another origin. */
      refused(origin: string): void;
    };
  }
}

const log: string[] = [];
const list = document.createElement("ol");
document.getElementById("root")!.append(list);
let started = 0;
// The page's time is its runtime's: what the test reads is page time.
// ast-grep-ignore: ts-test-clock
const since = () => performance.now() - started;
const note = (line: string) => {
  log.push(`${since()} ${line}`);
  const item = document.createElement("li");
  item.textContent = line;
  list.append(item);
};

const worker = new Worker(new URL("./asks.worker.ts", import.meta.url), {
  type: "module",
});
worker.addEventListener("message", (event) => note(`worker: ${String(event.data)}`));

async function stream(url: string, signal?: AbortSignal) {
  const response = await fetch(url, { signal: signal ?? null });
  note(`head ${response.status}`);
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    note(decoder.decode(value, { stream: true }).trim());
  }
  note("end");
}

window.worldHttp = {
  log,
  start(origin) {
    // ast-grep-ignore: ts-test-clock
    started = performance.now();
    void stream(`${origin}/reply?of=page`);
    void fetch(`${origin}/echo?after=30`, { method: "POST", body: "from the page" })
      .then((response) => response.json())
      .then((body) => note(`echo ${JSON.stringify(body)}`));
    // Worker.postMessage has no targetOrigin overload.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    worker.postMessage(`${origin}/echo?after=30`);
    // ast-grep-ignore: ts-test-timer
    setTimeout(() => note("timer"), 40);
  },
  abortAfter(origin, ms) {
    // ast-grep-ignore: ts-test-clock
    started = performance.now();
    const abort = new AbortController();
    stream(`${origin}/reply?of=aborted`, abort.signal).catch((error: Error) =>
      note(`failed ${error.name}`)
    );
    // ast-grep-ignore: ts-test-timer
    setTimeout(() => abort.abort(), ms);
  },
  firstLeavesLast(origin) {
    // ast-grep-ignore: ts-test-clock
    started = performance.now();
    const echo = (body: string, headers?: Record<string, string>) =>
      void fetch(`${origin}/echo`, {
        method: "POST",
        body,
        ...(headers && { headers }),
      })
        .then((response) => response.json())
        .then((answer: { echo: string }) => note(`echo ${answer.echo}`));
    echo("first", { "content-type": "application/json" });
    for (let later = 1; later <= 6; later += 1) echo(`later ${later}`);
  },
  refused(origin) {
    fetch(`${origin}/echo`, { mode: "same-origin" }).catch(() => {});
  },
  async echoes(origin, count) {
    for (let index = 0; index < count; index += 1)
      await (
        await fetch(`${origin}/echo`, { method: "POST", body: String(index) })
      ).json();
  },
};
