import { derivedSeed, workerSeedParameter } from "./random";

// The test page's workers (./child). Each starts from the test build with its
// random seed in its URL (./worker-seed); a worker from anywhere else (a blob,
// a data URL) fails the test. What a worker sends back reaches the page only
// at a fixed point, in the order it arrived: the browser's own delivery is
// kept until then. A worker the page has sent more messages than it answered
// holds page time still until it answers (`workersIdle`).

type QueuedMessage = { worker: SeededWorker; event: MessageEvent };

const queue: QueuedMessage[] = [];
let inFlight = 0;
let idle: (() => void)[] = [];

const settleIdle = () => {
  if (inFlight > 0) return;
  const waiting = idle;
  idle = [];
  for (const resolve of waiting) resolve();
};

interface SeededWorker extends Worker {
  deliver(event: MessageEvent): void;
}

/** Seeds and holds the workers the page in `view` creates from now on. */
export function holdWorkers(view: typeof globalThis, seed: number) {
  const NativeWorker = view.Worker;
  let workers = 0;
  view.Worker = class extends NativeWorker implements SeededWorker {
    #listeners = new Set<EventListenerOrEventListenerObject>();
    #onmessage: ((event: MessageEvent) => unknown) | null = null;
    #unanswered = 0;

    constructor(url: string | URL, options?: WorkerOptions) {
      const resolved = new URL(url, view.location.href);
      if (!resolved.pathname.startsWith("/__pages/"))
        throw new Error(
          `The test page started a worker from ${resolved.href}, outside the test build: its random numbers would leave the test's seed.`
        );
      workers += 1;
      resolved.hash = `${workerSeedParameter}=${derivedSeed(seed, workers)}`;
      super(resolved, options);
      super.addEventListener("message", (event) => {
        queue.push({ worker: this as unknown as SeededWorker, event });
        if (this.#unanswered > 0) {
          this.#unanswered -= 1;
          inFlight -= 1;
          settleIdle();
        }
      });
    }

    override postMessage(
      message: unknown,
      options?: StructuredSerializeOptions | Transferable[]
    ) {
      this.#unanswered += 1;
      inFlight += 1;
      super.postMessage(message, options as StructuredSerializeOptions);
    }

    override terminate() {
      inFlight -= this.#unanswered;
      this.#unanswered = 0;
      settleIdle();
      super.terminate();
    }

    override addEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions
    ) {
      if (type === "message" && listener) this.#listeners.add(listener);
      else if (listener) super.addEventListener(type, listener, options);
    }

    override removeEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | EventListenerOptions
    ) {
      if (type === "message" && listener) this.#listeners.delete(listener);
      else if (listener) super.removeEventListener(type, listener, options);
    }

    override get onmessage() {
      return this.#onmessage;
    }

    override set onmessage(handler: ((event: MessageEvent) => unknown) | null) {
      this.#onmessage = handler;
    }

    deliver(event: MessageEvent) {
      this.#onmessage?.call(this, event);
      for (const listener of this.#listeners) {
        if (typeof listener === "function") listener.call(this, event);
        else listener.handleEvent(event);
      }
    }
  } as typeof Worker;
}

/** Delivers what the workers sent back so far, in the order it arrived. */
export function deliverWorkerMessages() {
  for (const { worker, event } of queue.splice(0)) worker.deliver(event);
}

/** Resolves once every worker answered each message the page sent it. */
export const workersIdle = () =>
  inFlight === 0
    ? Promise.resolve()
    : new Promise<void>((resolve) => idle.push(resolve));
