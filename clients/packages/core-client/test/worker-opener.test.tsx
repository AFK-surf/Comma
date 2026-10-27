import { afterEach, expect, it, vi } from "vitest";
import { CoreClient, workerCoreOpener } from "../src/index";

function fakeWorker() {
  return Object.assign(new EventTarget(), {
    postMessage: vi.fn(),
    terminate: vi.fn(),
  });
}

/** What the server answers for a script's URL. */
function answer(status: number, contentType: string) {
  return async () =>
    new Response(null, { status, headers: { "content-type": contentType } });
}

afterEach(() => void vi.unstubAllGlobals());

it("tells a core worker that did not load from one that threw", () => {
  const worker = fakeWorker();
  const onFail = vi.fn();
  workerCoreOpener(() => worker as unknown as Worker)(() => undefined, onFail);

  // A script that fails to load or parse gets a plain `error` Event.
  worker.dispatchEvent(new Event("error"));
  worker.dispatchEvent(new ErrorEvent("error", { message: "Uncaught TypeError: x" }));

  expect(onFail.mock.calls).toEqual([
    ["The core's worker did not load.", "worker_load"],
    ["Uncaught TypeError: x", "worker_exception"],
  ]);
});

// A page of a build replaced since asks for its worker's script, which the release does not serve (it answers with
// its page): the page loads again, as the current build, instead of asking for that script for as long as it is open.
it("loads the page again when its worker did not load and its build is no longer served", async () => {
  const build = "https://app.example/assets/connect-core-old.js";
  const attempt = async (server: () => Promise<Response>) => {
    const fetch = vi.fn(server);
    vi.stubGlobal("fetch", fetch);
    const workers: ReturnType<typeof fakeWorker>[] = [];
    const faults: unknown[] = [];
    const retries: number[] = [];
    // The client either retires the page or schedules the next try, once.
    let decided!: () => void;
    const decision = new Promise<void>((resolve) => (decided = resolve));
    const onRetired = vi.fn(() => decided());
    const core = new CoreClient(
      workerCoreOpener(() => {
        const worker = fakeWorker();
        workers.push(worker);
        return worker as unknown as Worker;
      }, build),
      {
        onRetired,
        onFault: (error) => faults.push((error as { failure?: unknown }).failure),
        schedule: (ms) => {
          retries.push(ms);
          decided();
        },
      }
    );
    workers[0]!.dispatchEvent(new Event("error"));
    await decision;
    core.close();
    // Asked of the server, past the browser's cache.
    expect(fetch).toHaveBeenCalledWith(build, { method: "HEAD", cache: "no-store" });
    return { retired: onRetired.mock.calls.length, faults, retries };
  };

  const retired = { retired: 1, faults: [], retries: [] };
  const triedAgain = { retired: 0, faults: ["worker_load"], retries: [0] };
  // Not served: the release's page in its place, or nothing.
  expect(await attempt(answer(200, "text/html"))).toEqual(retired);
  expect(await attempt(answer(404, "text/plain"))).toEqual(retired);
  // Still served (it failed for another cause), or not known (the server failing, offline): tried again as before.
  expect(await attempt(answer(200, "text/javascript"))).toEqual(triedAgain);
  expect(await attempt(answer(503, "text/html"))).toEqual(triedAgain);
  expect(await attempt(() => Promise.reject(new TypeError("Failed to fetch")))).toEqual(
    triedAgain
  );
});
