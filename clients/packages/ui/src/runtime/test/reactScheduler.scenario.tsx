import * as Scheduler from "scheduler";
import {
  Suspense,
  use,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useState,
  startTransition,
} from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { uiClock } from "../../clock";
import { createTestUiRuntime, realHost } from "./testing";

// One task of the host's own, outside the runtime.
const nextRealTask = () =>
  new Promise<void>((resolve) => {
    const channel = new (realHost().MessageChannel)();
    channel.port1.addEventListener("message", () => {
      channel.port1.close();
      resolve();
    });
    channel.port1.start();
    channel.port2.postMessage(null);
  });

/**
 * React on the mock scheduler, driven by a test UI runtime. Returns what
 * happened, each line stamped with the runtime's time: the same on every run
 * if React's work and its timers run only when the runtime runs them.
 */
export async function reactSchedulerScenario() {
  const runtime = createTestUiRuntime({ seed: 7, scheduler: Scheduler });
  const uninstall = runtime.install();
  const log: string[] = [];
  const at = (what: string) => log.push(`${runtime.elapsed()}ms ${what}`);
  const container = document.createElement("div");
  document.body.append(container);
  const promises = new Map<number, Promise<void>>();
  const ready = (ms: number) => {
    let promise = promises.get(ms);
    if (!promise) {
      promise = new Promise<void>((resolve) =>
        uiClock.after(ms, () => {
          at(`data ${ms} resolves`);
          resolve();
        })
      );
      promises.set(ms, promise);
    }
    return promise;
  };
  let setQuery!: (value: string) => void;
  let setDelay!: (ms: number | null) => void;
  let setCount!: (update: (count: number) => number) => void;

  function Slow({ ms }: { ms: number }) {
    use(ready(ms));
    at(`Slow ${ms} renders`);
    return <span>slow {ms}</span>;
  }
  function App() {
    const [query, setQueryState] = useState("a");
    const [delay, setDelayState] = useState<number | null>(null);
    const [count, setCountState] = useState(0);
    setQuery = setQueryState;
    setDelay = setDelayState;
    setCount = setCountState;
    const deferred = useDeferredValue(query);
    at(`App renders query=${query} deferred=${deferred} count=${count}`);
    useLayoutEffect(() => {
      at(`layout effect query=${query}`);
    }, [query]);
    useEffect(() => {
      at(`effect query=${query} deferred=${deferred}`);
    }, [query, deferred]);
    return (
      <div>
        {query}/{deferred}/{count}
        {delay !== null && (
          <Suspense fallback={<i>loading</i>}>
            <Slow ms={delay} />
          </Suspense>
        )}
      </div>
    );
  }

  try {
    const root = createRoot(container);
    root.render(<App />);
    // Real tasks pass, as many as React's own scheduler would need: none of
    // them runs React's work.
    for (let task = 0; task < 20; task += 1) await nextRealTask();
    at(
      `20 real tasks later: text="${container.textContent}" pending=${Scheduler.unstable_hasPendingWork()}`
    );
    await runtime.flush();
    at(`flushed: text="${container.textContent}"`);

    // An update outside an event, then a transition and a sync update together.
    setQuery("b");
    at(`setQuery(b): text="${container.textContent}"`);
    await runtime.flush();
    at(`flushed: text="${container.textContent}"`);
    startTransition(() => setCount((count) => count + 10));
    flushSync(() => setCount((count) => count + 1));
    at(`transition +10 and sync +1: text="${container.textContent}"`);
    await runtime.flush();
    at(`flushed: text="${container.textContent}"`);

    // Suspense: data arrives at 100 ms, React holds the reveal until its
    // fallback has shown for 300 ms (a host timer React keeps from load).
    setDelay(100);
    await runtime.flush();
    at(`suspended: text="${container.textContent}"`);
    await runtime.advance(100);
    at(`advanced 100: text="${container.textContent}"`);
    await runtime.advance(199);
    at(`advanced 299: text="${container.textContent}"`);
    await runtime.advance(1);
    at(`advanced 300: text="${container.textContent}"`);

    root.unmount();
    await runtime.flush();
  } finally {
    uninstall();
    container.remove();
  }
  return { log, stats: runtime.stats(), violations: runtime.violations() };
}
