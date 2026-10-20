/**
 * The test UI runtime: one scheduler owns every source of time and order a
 * UI test can meet, so the test's result depends only on the code and the
 * seed.
 *
 * - Time moves only in `advance`. Timers run at their due time in the order
 *   they were set; frames fall on multiples of `frameMs`.
 * - React's work runs after each timer, task and frame, at the runtime's
 *   time. In a browser React's own scheduler posts it on a message channel,
 *   and a message between two ports of the page is a task of the runtime; in
 *   jsdom the runtime is given React's mock scheduler
 *   (`scheduler/unstable_mock`) and runs it.
 * - A frame does, in memory and in this order, what a browser's rendering
 *   step does that pages can observe: scroll events, animation time and
 *   animation events, frame callbacks, ResizeObserver notifications and
 *   IntersectionObserver notifications. Layout is the browser's own (read
 *   synchronously); only the moment of each callback is the runtime's.
 * - CSS transitions, CSS animations and Web Animations keep playing on a
 *   timeline the runtime sets: each frame sets their time from the frame time.
 *   Events the browser would send for them on a real frame are dropped and
 *   sent by the runtime at its frame instead.
 * - Randomness comes from the seed; storage is in memory; modules loaded on
 *   demand are loaded before the fixture renders, and any request, worker or
 *   on-demand load while the test runs is recorded as a violation.
 *
 * Host functions that libraries capture when they load (`setTimeout`,
 * `requestAnimationFrame`, `Date`, `performance.now`, `Math.random`,
 * `MessageChannel`, the observers) are routed through `installTestUiHost`,
 * which must run before those libraries load.
 */
import type { CancelUiTimer, UiClock } from "../../clock";
import {
  declaredUiModules,
  installUiRuntime,
  type UiLoad,
  type UiObserve,
  type UiRuntime,
  type UiStorage,
} from "../index";

/** The subset of `scheduler/unstable_mock` the runtime drives. */
export type MockScheduler = {
  unstable_flushAllWithoutAsserting(): boolean | void;
  unstable_hasPendingWork(): boolean;
  unstable_advanceTime(ms: number): void;
  unstable_now(): number;
  reset?(): void;
};

export type TestUiRuntimeOptions = {
  seed?: number;
  /** Wall-clock time at the start, in ms since the epoch. */
  start?: number;
  frameMs?: number;
  scheduler?: MockScheduler;
  /** Run layout observers, scroll and motion against a real layout (browser). */
  layout?: boolean;
  /** Traced at the start of every frame, to find where two runs part. */
  frameProbe?: () => string;
  /**
   * Runs in every frame once its scroll containers moved, before the frame
   * reads the animations: what moved under the pointer has its hover (and
   * the transitions hover starts) at the same point of every frame.
   */
  afterScroll?: () => Promise<void>;
};

export type TestUiRuntime = UiRuntime & {
  readonly seed: number;
  /** Time since the runtime started, in ms. */
  elapsed(): number;
  /** Runs `ms` of time: every timer, task and frame due in it, in order. */
  advance(ms: number): Promise<void>;
  /** Runs `count` frames: time moves to the `count`th next frame. */
  advanceFrames(count: number): Promise<void>;
  /** Runs everything due now without moving time. */
  flush(): Promise<void>;
  /**
   * Runs a rendering step now, without moving time: what the page did since
   * its last frame (a scroll, an animation it played, finished or cancelled, a
   * size it changed) reaches its listeners and observers. Animations keep
   * their time, and frame callbacks wait for the next frame.
   */
  render(): Promise<void>;
  /** Runs up to the next timer or frame; false when nothing is scheduled or the runtime is running. */
  step(): Promise<boolean>;
  /** Whether `advance`, `flush` or `step` is running. */
  busy(): boolean;
  /**
   * The next time something is due, since the runtime started: a timer, or a
   * frame that has work. Null when nothing is.
   */
  nextDue(): number | null;
  /** Loads every declared module and every font face before a fixture renders. */
  prepare(): Promise<void>;
  /** IO started and not yet delivered, by key. */
  pendingWork(): readonly string[];
  /** Resolves when the browser sends `type` at `target`; such events reach the page only through the runtime. */
  whenBrowserSends(type: string, target: EventTarget): Promise<void>;
  /** What the test did that the runtime does not control (requests, workers, loads). */
  violations(): readonly string[];
  /** Counts of runtime work, for reports. */
  stats(): Readonly<Record<string, number>>;
  /** Real time the runtime spent, in ms, per kind of work. */
  realTime(): Readonly<Record<string, number>>;
  /** Starts recording what the runtime runs, one line per step; returns the lines so far. */
  trace(): string[];
  /** Adds a line to the trace. */
  note(line: string): void;
  /** The page changed outside the runtime (input, media emulation): check it on the next frame. */
  invalidate(): void;
  /** Makes this the active runtime of the page; returns the uninstall. */
  install(): () => void;
};

// ---------------------------------------------------------------------------
// Host routing: installed once per realm, before libraries load.

type Host = {
  setTimeout: typeof setTimeout;
  clearTimeout: typeof clearTimeout;
  setInterval: typeof setInterval;
  clearInterval: typeof clearInterval;
  requestAnimationFrame: typeof requestAnimationFrame;
  cancelAnimationFrame: typeof cancelAnimationFrame;
  now: () => number;
  Date: DateConstructor;
  random: () => number;
  randomUUID: () => `${string}-${string}-${string}-${string}-${string}`;
  fetch: typeof fetch | undefined;
  MessageChannel: typeof MessageChannel;
  ResizeObserver: typeof ResizeObserver | undefined;
  IntersectionObserver: typeof IntersectionObserver | undefined;
  Worker: typeof Worker | undefined;
};

let host: Host | undefined;
/** The global clients/vite/ui-runtime-imports.ts rewrites `import()` to call. */
const importHook = "__commaUiImport";
const this_test = () =>
  (globalThis as { commaTestTitle?: string }).commaTestTitle ?? "";
const debugRuntime = Boolean(
  (import.meta as { env?: Record<string, string> }).env?.VITE_UI_RUNTIME_DEBUG
);
/** The page's layout is real (a browser): observers are the runtime's from the start. */
let layoutHost = false;
let active: Runtime | undefined;

/** The real host functions, captured by `installTestUiHost`. */
export function realHost(): Host {
  if (!host) throw new Error("installTestUiHost has not run");
  return host;
}

const timedEvents = [
  "transitionrun",
  "transitionstart",
  "transitionend",
  "transitioncancel",
  "animationstart",
  "animationiteration",
  "animationend",
  "animationcancel",
  "scroll",
  "scrollend",
] as const;

/**
 * Routes the host functions libraries capture at load to the active test
 * runtime, and to the real ones when none is active. Call first in a test
 * setup file.
 */
export function installTestUiHost({ layout = false }: { layout?: boolean } = {}) {
  if (host) return;
  layoutHost = layout;
  const scope = globalThis as typeof globalThis & Record<string, unknown>;
  host = {
    setTimeout: globalThis.setTimeout.bind(globalThis),
    clearTimeout: globalThis.clearTimeout.bind(globalThis),
    setInterval: globalThis.setInterval.bind(globalThis),
    clearInterval: globalThis.clearInterval.bind(globalThis),
    requestAnimationFrame:
      typeof requestAnimationFrame === "function"
        ? requestAnimationFrame.bind(globalThis)
        : (((run: FrameRequestCallback) =>
            // ast-grep-ignore: ts-test-timer, ts-test-clock -- the host's own, while no test runtime is active.
            globalThis.setTimeout(() => run(performance.now()), 16)) as never),
    cancelAnimationFrame:
      typeof cancelAnimationFrame === "function"
        ? cancelAnimationFrame.bind(globalThis)
        : (((id: number) => globalThis.clearTimeout(id)) as never),
    now: performance.now.bind(performance),
    Date,
    random: Math.random.bind(Math),
    randomUUID: crypto.randomUUID.bind(crypto),
    fetch: globalThis.fetch?.bind(globalThis),
    MessageChannel,
    ResizeObserver: scope.ResizeObserver as typeof ResizeObserver | undefined,
    IntersectionObserver: scope.IntersectionObserver as
      | typeof IntersectionObserver
      | undefined,
    Worker: scope.Worker as typeof Worker | undefined,
  };
  const real = host;

  // Timers carry ids above the real ones' range so clear* can tell them apart.
  const routed = new Map<number, CancelUiTimer>();
  let nextId = 1 << 30;
  // Between tests page time does not run: what the page schedules then
  // never runs, rather than run on real time into the next test.
  const dormant = () => route(() => {});
  const route = (cancel: CancelUiTimer) => {
    const id = (nextId += 1);
    routed.set(id, cancel);
    return id;
  };
  const clear = (id: unknown, realClear: (id: never) => void) => {
    const cancel = routed.get(id as number);
    if (cancel) {
      routed.delete(id as number);
      cancel();
    } else realClear(id as never);
  };
  // How deep the running timeout is nested in timeouts (setTimeout below).
  let timerNesting = 0;
  scope.setTimeout = ((run: TimerHandler, ms?: number, ...args: unknown[]) => {
    // ast-grep-ignore: ts-test-timer -- the host's own, while no test runtime is active.
    if (!active) return layoutHost ? dormant() : real.setTimeout(run, ms, ...args);
    const fn = typeof run === "function" ? run : () => (0, eval)(run);
    // As a browser clamps it: a timeout set from a timeout nested more than
    // five deep waits at least 4 ms, so a timer loop moves time on.
    const level = timerNesting + 1;
    const delay = level > 5 ? Math.max(4, ms ?? 0) : (ms ?? 0);
    let id = 0;
    id = route(
      active.clock.after(delay, () => {
        routed.delete(id);
        const outer = timerNesting;
        timerNesting = level;
        try {
          (fn as (...a: unknown[]) => void)(...args);
        } finally {
          timerNesting = outer;
        }
      })
    );
    return id;
  }) as typeof setTimeout;
  scope.clearTimeout = ((id: unknown) => clear(id, real.clearTimeout)) as never;
  scope.setInterval = ((run: TimerHandler, ms?: number, ...args: unknown[]) => {
    // ast-grep-ignore: ts-test-timer -- the host's own, while no test runtime is active.
    if (!active) return layoutHost ? dormant() : real.setInterval(run, ms, ...args);
    const fn = run as (...a: unknown[]) => void;
    return route(active.clock.every(ms ?? 0, () => fn(...args)));
  }) as typeof setInterval;
  scope.clearInterval = ((id: unknown) => clear(id, real.clearInterval)) as never;
  if (typeof window !== "undefined") {
    scope.requestAnimationFrame = ((run: FrameRequestCallback) => {
      // ast-grep-ignore: ts-test-timer -- the host's own, while no test runtime is active.
      if (!active) return layoutHost ? dormant() : real.requestAnimationFrame(run);
      return route(active.clock.frame(run));
    }) as typeof requestAnimationFrame;
    scope.cancelAnimationFrame = ((id: number) =>
      clear(id, real.cancelAnimationFrame)) as never;
  }
  performance.now = () => (active ? active.elapsed() : real.now());
  // Idle callbacks run when the browser finds idle time, which real load
  // decides: on page time they run as the next task, with a fixed budget.
  if (typeof requestIdleCallback === "function") {
    const realIdle = requestIdleCallback.bind(globalThis);
    const realCancelIdle = cancelIdleCallback.bind(globalThis);
    scope.requestIdleCallback = ((
      run: IdleRequestCallback,
      options?: IdleRequestOptions
    ) => {
      if (!active) return layoutHost ? dormant() : realIdle(run, options);
      return route(
        active.clock.after(0, () =>
          run({ didTimeout: false, timeRemaining: () => 50 } as IdleDeadline)
        )
      );
    }) as typeof requestIdleCallback;
    scope.cancelIdleCallback = ((id: number) => clear(id, realCancelIdle)) as never;
  }
  // Modules imported on demand (rewritten by clients/vite/ui-runtime-imports.ts).
  scope[importHook] = (load: () => Promise<unknown>, key: string) =>
    active && !active.preparing
      ? active.load.work(
          debugRuntime
            ? `import ${key} from ${(new Error().stack ?? "")
                .split("\n")
                .slice(2, 14)
                .map(
                  (line) =>
                    line
                      .trim()
                      .replace(/^at /, "")
                      .replace(/ ?\(?http.*$/, "") || "?"
                )
                .join(" < ")} @${this_test()}`
            : `import ${key}`,
          load
        )
      : load();
  // A WebAssembly module compiles on other threads, done after a time the
  // machine decides: leaf IO, as a module imported on demand is.
  if (typeof WebAssembly !== "undefined") {
    const wasm = WebAssembly as unknown as Record<
      string,
      ((...args: unknown[]) => Promise<unknown>) | undefined
    >;
    for (const name of [
      "compile",
      "compileStreaming",
      "instantiate",
      "instantiateStreaming",
    ]) {
      const realWasm = wasm[name]?.bind(WebAssembly);
      if (!realWasm) continue;
      wasm[name] = (...args) =>
        active && !active.preparing
          ? active.load.work(`wasm ${name}`, () => realWasm(...args))
          : realWasm(...args);
    }
  }
  const RealDate = real.Date;
  const TestDate = function (this: unknown, ...args: unknown[]) {
    if (!(this instanceof TestDate)) return new RealDate(TestDate.now()).toString();
    return args.length === 0
      ? new RealDate(TestDate.now())
      : new (RealDate as unknown as new (...a: unknown[]) => Date)(...args);
  } as unknown as DateConstructor;
  Object.setPrototypeOf(TestDate, RealDate);
  (TestDate as { prototype: Date }).prototype = RealDate.prototype;
  (TestDate as { now: () => number }).now = () =>
    active ? active.wallClock() : RealDate.now();
  scope.Date = TestDate;
  Math.random = () => (active ? active.random.next() : real.random());
  // Defined, not assigned: a harness before this one may have defined them
  // read-only (a worker's seed).
  Object.defineProperty(crypto, "randomUUID", {
    configurable: true,
    writable: true,
    value: () => (active ? active.random.uuid() : real.randomUUID()),
  });
  // A MessageChannel the page makes for itself (React's scheduler posts its
  // work on one): a message between its ports is a task of the runtime, run
  // in the order it was posted, not when the browser delivers it.
  const RealMessageChannel = real.MessageChannel;
  scope.MessageChannel = function () {
    const channel = new RealMessageChannel();
    const first = routePort(channel.port1);
    const second = routePort(channel.port2);
    first.peer = second;
    second.peer = first;
    peerPorts.set(first, channel.port2);
    peerPorts.set(second, channel.port1);
    return channel;
  } as unknown as typeof MessageChannel;
  // A port the page hands to a frame or a worker receives there: what is
  // posted to it is no longer the page's to wait for.
  const handedOver = (argument: unknown) => {
    const list = Array.isArray(argument)
      ? argument
      : (argument as { transfer?: unknown[] } | null | undefined)?.transfer;
    if (!Array.isArray(list)) return;
    for (const item of list) {
      const state = routedPorts.get(item as MessagePort);
      if (!state) continue;
      transferredPorts.add(item as MessagePort);
      portMessagesSettled(state.pending);
      state.pending = 0;
      state.queued = 0;
    }
  };
  for (const target of [
    typeof Window === "undefined" ? undefined : Window.prototype,
    real.Worker?.prototype,
    typeof MessagePort === "undefined" ? undefined : MessagePort.prototype,
  ] as ({ postMessage: (...args: unknown[]) => void } | undefined)[]) {
    if (!target) continue;
    const post = target.postMessage;
    target.postMessage = function (this: unknown, ...args: unknown[]) {
      for (const argument of args.slice(1)) handedOver(argument);
      return post.apply(this, args);
    };
  }
  const realRandomValues = crypto.getRandomValues.bind(crypto) as (
    array: ArrayBufferView | null
  ) => ArrayBufferView | null;
  Object.defineProperty(crypto, "getRandomValues", {
    configurable: true,
    writable: true,
    value: (array: ArrayBufferView | null) => {
      if (!active || !array) return realRandomValues(array);
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
      for (let index = 0; index < bytes.length; index += 1)
        bytes[index] = Math.floor(active.random.next() * 256);
      return array;
    },
  });
  const realFetch = real.fetch;
  if (realFetch)
    scope.fetch = ((...args: Parameters<typeof fetch>) => {
      if (active) {
        active.violation(`fetch ${String(args[0])}`);
        return Promise.reject(new TypeError("A UI test runtime allows no requests"));
      }
      return realFetch(...args);
    }) as typeof fetch;
  if (real.Worker) {
    const RealWorker = real.Worker;
    scope.Worker = function (...args: ConstructorParameters<typeof Worker>) {
      if (active && !active.workerAllowed())
        active.violation(`worker ${String(args[0])}`);
      return new RealWorker(...args);
    } as unknown as typeof Worker;
  }
  if (real.ResizeObserver) {
    const RealResizeObserver = real.ResizeObserver;
    scope.ResizeObserver = function (callback: ResizeObserverCallback) {
      return layoutHost
        ? createResizeObserver(callback)
        : new RealResizeObserver(callback);
    } as unknown as typeof ResizeObserver;
  }
  if (real.IntersectionObserver) {
    const RealIntersectionObserver = real.IntersectionObserver;
    scope.IntersectionObserver = function (
      callback: IntersectionObserverCallback,
      options?: IntersectionObserverInit
    ) {
      return layoutHost
        ? createIntersectionObserver(callback, options)
        : new RealIntersectionObserver(callback, options);
    } as unknown as typeof IntersectionObserver;
  }
  if (typeof window !== "undefined") {
    for (const type of timedEvents)
      window.addEventListener(
        type,
        (event) => {
          if (layoutHost && event.isTrusted) {
            event.stopImmediatePropagation();
            active?.trustedEvent(event);
          }
        },
        { capture: true }
      );
    patchAnimations();
    patchSmoothScroll();
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get: () => (active ? active.storage.local() : realLocalStorage),
    });
    Object.defineProperty(window, "sessionStorage", {
      configurable: true,
      get: () => (active ? active.storage.session() : realSessionStorage),
    });
  }
}

type RoutedPort = {
  peer?: RoutedPort;
  started: boolean;
  /** Messages posted to this port that have not arrived at it. */
  pending: number;
  /** Messages posted to this port before it started. */
  queued: number;
};

let portMessagesInFlight = 0;
let portArrivals: (() => void)[] = [];

/** Resolves once every message the page posted between its own ports has arrived. */
function portMessagesArrived() {
  return portMessagesInFlight === 0
    ? Promise.resolve()
    : new Promise<void>((resolve) => portArrivals.push(resolve));
}

function portMessagesSettled(count: number) {
  portMessagesInFlight -= count;
  if (portMessagesInFlight > 0) return;
  const waiting = portArrivals;
  portArrivals = [];
  for (const resolve of waiting) resolve();
}

function routePort(port: MessagePort): RoutedPort {
  const state: RoutedPort = { started: false, pending: 0, queued: 0 };
  const listeners = new Map<EventListenerOrEventListenerObject, boolean>();
  let onmessage: ((event: MessageEvent) => unknown) | null = null;
  type Listen = (
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: unknown
  ) => void;
  const add = port.addEventListener.bind(port) as Listen;
  const remove = port.removeEventListener.bind(port) as Listen;
  const post = port.postMessage.bind(port) as (...args: unknown[]) => void;
  const start = port.start.bind(port);
  const close = port.close.bind(port);
  const deliver = (event: MessageEvent) => {
    onmessage?.call(port, event);
    for (const [listener, once] of listeners) {
      if (once) listeners.delete(listener);
      if (typeof listener === "function") listener.call(port, event);
      else listener.handleEvent(event);
    }
  };
  add("message", (event: Event) => {
    if (state.pending > 0) {
      state.pending -= 1;
      portMessagesSettled(1);
    }
    if (active) active.task.post(() => deliver(event as MessageEvent));
    else deliver(event as MessageEvent);
  });
  const begin = () => {
    if (state.started) return;
    state.started = true;
    state.pending += state.queued;
    portMessagesInFlight += state.queued;
    state.queued = 0;
    start();
  };
  port.addEventListener = ((
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ) => {
    if (type !== "message") return add(type, listener, options);
    if (listener)
      listeners.set(listener, typeof options === "object" && options.once === true);
  }) as typeof port.addEventListener;
  port.removeEventListener = ((
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ) => {
    if (type !== "message") return remove(type, listener, options);
    if (listener) listeners.delete(listener);
  }) as typeof port.removeEventListener;
  Object.defineProperty(port, "onmessage", {
    configurable: true,
    get: () => onmessage,
    set(handler: ((event: MessageEvent) => unknown) | null) {
      onmessage = handler;
      // Setting the handler starts the port, as the platform's does.
      begin();
    },
  });
  port.start = begin;
  port.postMessage = ((...args: unknown[]) => {
    const peer = state.peer;
    // Counted while a runtime runs the page and the other port is still the
    // page's: a port handed to a frame or a worker receives there.
    if (active && peer && !transferredPorts.has(peerPorts.get(state)!)) {
      if (peer.started) {
        peer.pending += 1;
        portMessagesInFlight += 1;
      } else peer.queued += 1;
    }
    post(...args);
  }) as typeof port.postMessage;
  port.close = () => {
    // What was on its way to a closed port never arrives.
    portMessagesSettled(state.pending);
    state.pending = 0;
    state.queued = 0;
    close();
  };
  routedPorts.set(port, state);
  return state;
}

/** The page's own ports, and for each state its peer's port, to know one that left the page. */
const routedPorts = new WeakMap<MessagePort, RoutedPort>();
const peerPorts = new WeakMap<RoutedPort, MessagePort>();
const transferredPorts = new WeakSet<MessagePort>();

// A document of an opaque origin (a sandboxed frame) has no storage: reading
// it throws.
const storageOrNone = (read: () => Storage | undefined) => {
  try {
    return read();
  } catch {
    return undefined;
  }
};
const realLocalStorage = storageOrNone(() =>
  typeof localStorage === "undefined" ? undefined : localStorage
);
const realSessionStorage = storageOrNone(() =>
  typeof sessionStorage === "undefined" ? undefined : sessionStorage
);

// Web Animations: the browser sends `finish`, `cancel` and `remove` on a real
// frame. While a layout runtime is active those trusted events are dropped and
// the runtime sends its own on its frame. `document.timeline.currentTime`,
// `startTime` and `currentTime` read and write the runtime's time.
const managedTime = new WeakMap<
  Animation,
  { start: number | null; hold: number | null }
>();

/**
 * A smooth scroll the page asks for (`scrollTo`, `scroll`, `scrollBy` or
 * `scrollIntoView` with `behavior: "smooth"`) moves on page time, frame by
 * frame, as the browser's compositor moves it on its own (and as the browser
 * project, which disables smooth scrolling, would not show at all).
 */
type ScrollTo = (this: Element, options: ScrollToOptions) => void;

// Where `scrollTo(...args)` (or `scrollBy` with `by`) takes `element`.
function scrollDestination(element: Element, args: unknown[], by: boolean) {
  const options =
    typeof args[0] === "object" && args[0] !== null
      ? (args[0] as ScrollToOptions)
      : { left: args[0] as number, top: args[1] as number };
  const left = options.left ?? (by ? 0 : element.scrollLeft);
  const top = options.top ?? (by ? 0 : element.scrollTop);
  return {
    behavior: options.behavior,
    left: by ? element.scrollLeft + left : left,
    top: by ? element.scrollTop + top : top,
  };
}

function patchSmoothScroll() {
  if (typeof Element === "undefined") return;
  const proto = Element.prototype;
  const scrollTo = proto.scrollTo as ScrollTo;
  const scrollIntoView = proto.scrollIntoView;
  const runtime = () => (active?.layout ? active : undefined);
  const route = (by: boolean) =>
    function (this: Element, ...args: unknown[]) {
      const page = runtime();
      const to = scrollDestination(this, args, by);
      if (!page || to.behavior !== "smooth")
        return scrollTo.call(this, {
          left: to.left,
          top: to.top,
          ...(to.behavior ? { behavior: to.behavior } : {}),
        });
      page.smoothScroll(this, to.left, to.top, scrollTo);
    };
  proto.scrollTo = route(false);
  proto.scroll = route(false);
  proto.scrollBy = route(true);
  proto.scrollIntoView = function (
    this: Element,
    arg?: boolean | ScrollIntoViewOptions
  ) {
    const page = runtime();
    if (!page || typeof arg !== "object" || arg.behavior !== "smooth")
      return scrollIntoView.call(this, arg);
    // Where each scroll container would land: the browser's own placement,
    // taken at once and undone, then moved to on page time.
    const containers: Element[] = [];
    for (let node = this.parentElement; node; node = node.parentElement)
      if (node.scrollHeight > node.clientHeight || node.scrollWidth > node.clientWidth)
        containers.push(node);
    const before = containers.map((node) => [node.scrollLeft, node.scrollTop] as const);
    scrollIntoView.call(this, { ...arg, behavior: "instant" });
    containers.forEach((node, index) => {
      const left = node.scrollLeft;
      const top = node.scrollTop;
      scrollTo.call(node, {
        left: before[index]![0],
        top: before[index]![1],
        behavior: "instant",
      });
      page.smoothScroll(node, left, top, scrollTo);
    });
  };
}

function patchAnimations() {
  if (typeof Animation === "undefined") return;
  const proto = Animation.prototype;
  const add = proto.addEventListener;
  const wrapped = new WeakMap<object, EventListener>();
  const wrap = (listener: EventListenerOrEventListenerObject) => {
    let fn = wrapped.get(listener);
    if (!fn) {
      fn = (event: Event) => {
        if (layoutHost && event.isTrusted) return;
        if (typeof listener === "function") listener.call(event.currentTarget, event);
        else listener.handleEvent(event);
      };
      wrapped.set(listener, fn);
    }
    return fn;
  };
  proto.addEventListener = function (
    this: Animation,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ) {
    if (!listener) return;
    add.call(this, type, wrap(listener), options);
  };
  const remove = proto.removeEventListener;
  proto.removeEventListener = function (
    this: Animation,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ) {
    if (!listener) return;
    remove.call(
      this,
      type,
      wrapped.get(listener) ?? (listener as EventListener),
      options
    );
  };
  for (const name of ["onfinish", "oncancel", "onremove"] as const) {
    const descriptor = Object.getOwnPropertyDescriptor(proto, name)!;
    const handlers = new WeakMap<Animation, EventListener | null>();
    Object.defineProperty(proto, name, {
      configurable: true,
      get(this: Animation) {
        return handlers.get(this) ?? null;
      },
      set(this: Animation, handler: EventListener | null) {
        handlers.set(this, handler);
        descriptor.set!.call(
          this,
          handler
            ? (event: Event) => {
                if (layoutHost && event.isTrusted) return;
                handler.call(this, event);
              }
            : null
        );
      },
    });
  }
  const currentTime = Object.getOwnPropertyDescriptor(proto, "currentTime")!;
  const startTime = Object.getOwnPropertyDescriptor(proto, "startTime")!;
  Object.defineProperty(proto, "currentTime", {
    configurable: true,
    get(this: Animation) {
      const runtime = active?.layout ? active : undefined;
      if (!runtime) return currentTime.get!.call(this);
      return runtime.motionCurrentTime(this, () => currentTime.get!.call(this));
    },
    set(this: Animation, value: CSSNumberish | null) {
      const runtime = active?.layout ? active : undefined;
      if (runtime) runtime.motionSetCurrentTime(this, value as number | null);
      currentTime.set!.call(this, value);
    },
  });
  Object.defineProperty(proto, "startTime", {
    configurable: true,
    get(this: Animation) {
      const runtime = active?.layout ? active : undefined;
      if (!runtime) return startTime.get!.call(this);
      return runtime.motionStartTime(this, () => startTime.get!.call(this));
    },
    set(this: Animation, value: CSSNumberish | null) {
      const runtime = active?.layout ? active : undefined;
      if (!runtime) return startTime.set!.call(this, value);
      runtime.motionSetStartTime(this, value as number | null, (time) =>
        currentTime.set!.call(this, time)
      );
    },
  });
  if (typeof document !== "undefined") {
    const timeline = document.timeline;
    const timelineTime =
      Object.getOwnPropertyDescriptor(Object.getPrototypeOf(timeline), "currentTime") ??
      Object.getOwnPropertyDescriptor(AnimationTimeline.prototype, "currentTime");
    Object.defineProperty(timeline, "currentTime", {
      configurable: true,
      get() {
        return active?.layout ? active.frameTime() : timelineTime!.get!.call(timeline);
      },
    });
  }
}

// ---------------------------------------------------------------------------
// Seeded randomness (sfc32).

function seededRandom(seed: number) {
  let a = 0x9e_37_79_b9 ^ seed;
  let b = 0x24_3f_6a_88 ^ (seed * 31);
  let c = 0xb7_e1_51_62;
  let d = seed | 0;
  const next = () => {
    a |= 0;
    b |= 0;
    c |= 0;
    d |= 0;
    const t = (((a + b) | 0) + d) | 0;
    d = (d + 1) | 0;
    a = b ^ (b >>> 9);
    b = (c + (c << 3)) | 0;
    c = (c << 21) | (c >>> 11);
    c = (c + t) | 0;
    return (t >>> 0) / 4_294_967_296;
  };
  for (let i = 0; i < 12; i += 1) next();
  const uuid = () => {
    const bytes = Array.from({ length: 16 }, () => Math.floor(next() * 256));
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  };
  return { next, uuid };
}

class MemoryStorage implements Storage {
  private values = new Map<string, string>();
  get length() {
    return this.values.size;
  }
  clear() {
    this.values.clear();
  }
  getItem(key: string) {
    return this.values.get(key) ?? null;
  }
  key(index: number) {
    return [...this.values.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.values.delete(key);
  }
  setItem(key: string, value: string) {
    this.values.set(key, String(value));
  }
}

// ---------------------------------------------------------------------------
// The runtime.

type Timer = { at: number; seq: number; run: () => void; interval: number | null };

type MotionState = {
  /** Runtime time the animation's time is measured from; null while paused or idle. */
  start: number | null;
  /** Time held while paused, or set before the animation's first frame. */
  hold: number | null;
  playState: AnimationPlayState;
  phase: string;
  iteration: number | null;
  started: boolean;
  ended: boolean;
};

type ResizeObservation = {
  target: Element;
  box: ResizeObserverBoxOptions;
  last: [number, number] | null;
};

type IntersectionObservation = {
  target: Element;
  index: number;
  intersecting: boolean;
};

class Runtime {
  readonly seed: number;
  readonly layout: boolean;
  private readonly start: number;
  private readonly frameMs: number;
  private readonly scheduler: MockScheduler | undefined;
  private readonly frameProbe: (() => string) | undefined;
  private readonly afterScroll: (() => Promise<void>) | undefined;
  private time = 0;
  private lastFrame = 0;
  private seq = 0;
  private timers = new Set<Timer>();
  private frames = new Map<number, FrameRequestCallback>();
  private posted: { seq: number; run: () => void }[] = [];
  private readonly rng: ReturnType<typeof seededRandom>;
  private readonly local = new MemoryStorage();
  private readonly session = new MemoryStorage();
  private readonly loadedModules = new Map<string, unknown>();
  private readonly problems: string[] = [];
  private readonly counts: Record<string, number> = {
    timers: 0,
    frames: 0,
    frameCallbacks: 0,
    reactFlushes: 0,
    animationEvents: 0,
    resizeNotifications: 0,
    intersectionNotifications: 0,
    scrollEvents: 0,
    droppedBrowserEvents: 0,
    work: 0,
  };
  private motion = new Map<Animation, MotionState>();
  private scrollers = new Map<Element, { top: number; left: number; moved: boolean }>();
  // Smooth scrolls in progress, by scroll container.
  private smoothScrolls = new Map<
    Element,
    {
      from: [number, number];
      to: [number, number];
      start: number;
      duration: number;
      at: [number, number];
      scrollTo: ScrollTo;
    }
  >();
  private changed = true;
  private mutationWatch?: MutationObserver;
  // Elements whose style may have started a CSS animation since the last
  // frame, and the animation names each had then (instantAnimationSteps).
  private styleChanged = new Set<Element>();
  private animationNames = new WeakMap<Element, string>();
  private log: string[] | null = null;
  private eventLabels: string[] = [];
  private inWork = 0;
  private works: {
    key: string;
    result: Promise<Settled>;
    resolve: (value: unknown) => void;
    reject: (error: unknown) => void;
  }[] = [];

  readonly clock: UiClock;
  readonly random: UiRuntime["random"];
  readonly task: UiRuntime["task"];
  readonly motionService: UiRuntime["motion"];
  readonly observe: UiObserve;
  readonly load: UiLoad;
  readonly storage: UiStorage;

  constructor(options: TestUiRuntimeOptions) {
    this.seed = options.seed ?? 1;
    this.start = options.start ?? Date.UTC(2026, 0, 15, 12);
    this.frameMs = options.frameMs ?? 16;
    this.scheduler = options.scheduler;
    this.frameProbe = options.frameProbe;
    this.afterScroll = options.afterScroll;
    this.layout = options.layout ?? false;
    this.rng = seededRandom(this.seed);
    const schedule = (ms: number, run: () => void, interval: number | null) => {
      const timer: Timer = {
        at: this.time + Math.max(0, ms || 0),
        seq: (this.seq += 1),
        run,
        interval,
      };
      this.timers.add(timer);
      return timer;
    };
    this.clock = {
      now: () => this.wallClock(),
      monotonic: () => this.time,
      after: (ms, run) => {
        const timer = schedule(ms, run, null);
        return () => this.timers.delete(timer);
      },
      every: (ms, run) => {
        const timer = schedule(Math.max(1, ms), run, Math.max(1, ms));
        return () => this.timers.delete(timer);
      },
      frame: (run) => {
        const id = (this.seq += 1);
        this.frames.set(id, run);
        return () => this.frames.delete(id);
      },
    };
    this.random = { next: () => this.rng.next(), uuid: () => this.rng.uuid() };
    this.task = {
      microtask: (run) => queueMicrotask(run),
      post: (run) => {
        const entry = { seq: (this.seq += 1), run };
        this.posted.push(entry);
        return () => {
          this.posted = this.posted.filter((each) => each !== entry);
        };
      },
    };
    this.motionService = {
      animate: (element, keyframes, timing) => element.animate(keyframes, timing),
    };
    this.observe = {
      resize: (callback) => createResizeObserver(callback),
      intersection: (callback, init) => createIntersectionObserver(callback, init),
      mutation: (callback) => new MutationObserver(callback),
    };
    this.load = {
      module: <T>(key: string, load: () => Promise<T>) => {
        if (this.loadedModules.has(key))
          return Promise.resolve(this.loadedModules.get(key) as T);
        this.violation(`load ${key} while the test runs`);
        return load().then((value) => {
          this.loadedModules.set(key, value);
          return value;
        });
      },
      ready: <T>(key: string) => this.loadedModules.get(key) as T | undefined,
      decode: () => Promise.resolve(),
      // Leaf IO (a module fetch, an image, a worker's reply) runs as it
      // would without the runtime, but its result reaches the caller only
      // when the runtime delivers it: after the step that started it, in
      // the order the IO started, before page time moves on (settleWork).
      // Compound async work (a renderer that imports chunks) is not wrapped:
      // its own IO is, so it continues at the points that IO is delivered.
      work: <T>(key: string, run: () => Promise<T>) => {
        this.counts.work! += 1;
        this.note(`work ${key}`);
        let started: Promise<T>;
        this.inWork += 1;
        try {
          started = Promise.resolve(run());
        } catch (error) {
          started = Promise.reject(error);
        } finally {
          this.inWork -= 1;
        }
        return new Promise<T>((resolve, reject) => {
          this.works.push({
            key,
            result: started.then(
              (value): Settled => ({ ok: true, value }),
              (error: unknown): Settled => ({ ok: false, error })
            ),
            resolve: resolve as (value: unknown) => void,
            reject,
          });
        });
      },
    };
    this.storage = { local: () => this.local, session: () => this.session };
  }

  wallClock() {
    return this.start + this.time;
  }
  elapsed() {
    return this.time;
  }
  frameTime() {
    return this.lastFrame;
  }
  note(line: string) {
    this.log?.push(`${this.time} ${line}`);
    if (debugRuntime) console.warn(`[ui-runtime] ${this.time} ${line}`);
  }
  trace() {
    this.log ??= [];
    return this.log;
  }
  invalidate() {
    this.changed = true;
  }
  workerAllowed() {
    return this.inWork > 0;
  }
  violation(what: string) {
    this.problems.push(`${this.time}ms: ${what}`);
  }
  violations() {
    return this.problems;
  }
  stats() {
    return { ...this.counts };
  }
  eventTime() {
    return this.time;
  }

  private trustedWaiters: { type: string; target: EventTarget; resolve: () => void }[] =
    [];

  trustedEvent(event: Event) {
    this.counts.droppedBrowserEvents! += 1;
    for (const waiter of this.trustedWaiters.filter(
      (each) => each.type === event.type && each.target === event.target
    )) {
      this.trustedWaiters.splice(this.trustedWaiters.indexOf(waiter), 1);
      waiter.resolve();
    }
    if (event.type === "scroll" && event.target instanceof Element)
      this.watchScroller(event.target, true);
  }

  /** Resolves when the browser sends `type` at `target` (it reaches the page only through the runtime). */
  whenBrowserSends(type: string, target: EventTarget) {
    return new Promise<void>((resolve) =>
      this.trustedWaiters.push({ type, target, resolve })
    );
  }

  /** True while `prepare` loads: those loads finish before the fixture renders. */
  preparing = false;

  async prepare() {
    this.preparing = true;
    try {
      for (const [key, load] of declaredUiModules())
        if (!this.loadedModules.has(key)) this.loadedModules.set(key, await load());
    } finally {
      this.preparing = false;
    }
    if (typeof document !== "undefined" && document.fonts) {
      await Promise.all([...document.fonts].map((face) => face.load().catch(() => {})));
      await document.fonts.ready;
    }
  }

  install() {
    if (active) throw new Error("A test UI runtime is already installed");
    // oxlint-disable-next-line no-this-alias -- the page's one active runtime
    active = this;
    const restore = installUiRuntime(this.runtime());
    if (this.layout && typeof document !== "undefined") {
      this.mutationWatch = new MutationObserver((records) => {
        const scanStarted = realHost().now();
        this.changed = true;
        // A page that can run CSS animations (instantAnimationSteps).
        const styled = typeof AnimationEvent === "function";
        for (const record of records) {
          if (record.type === "attributes" && record.target instanceof HTMLImageElement)
            this.awaitImage(record.target);
          if (
            styled &&
            record.type === "attributes" &&
            record.target instanceof Element
          )
            this.styleChanged.add(record.target);
          for (const node of record.addedNodes) {
            if (node instanceof Element) {
              if (styled) {
                this.styleChanged.add(node);
                for (const element of node.querySelectorAll("*"))
                  this.styleChanged.add(element);
              }
              this.findScrollers(node);
              if (node instanceof HTMLImageElement) this.awaitImage(node);
              for (const image of node.querySelectorAll("img")) this.awaitImage(image);
            }
            if (node instanceof HTMLStyleElement || node instanceof HTMLLinkElement)
              renderEveryContentVisibility();
          }
          // An attribute can make the element or one inside it a scroll
          // container (a class whose rule sets overflow on a descendant).
          if (record.type === "attributes" && record.target instanceof Element)
            this.findScrollers(record.target, true, false);
        }
        this.realMs.mutationScan =
          (this.realMs.mutationScan ?? 0) + realHost().now() - scanStarted;
      });
      this.mutationWatch.observe(document, {
        subtree: true,
        childList: true,
        attributes: true,
        characterData: true,
      });
      this.findScrollers(document.documentElement, true, false);
      renderEveryContentVisibility();
    }
    return () => {
      this.mutationWatch?.disconnect();
      for (const animation of this.motion.keys()) managedTime.delete(animation);
      restore();
      active = undefined;
    };
  }

  runtime(): UiRuntime {
    return {
      clock: this.clock,
      random: this.random,
      task: this.task,
      motion: this.motionService,
      observe: this.observe,
      load: this.load,
      storage: this.storage,
      eventTime: () => this.eventTime(),
    };
  }

  // -- scheduling -----------------------------------------------------------

  private setTime(at: number) {
    if (at < this.time) return;
    const delta = at - this.time;
    this.time = at;
    if (delta > 0) this.scheduler?.unstable_advanceTime(delta);
  }

  private nextTimer() {
    let next: Timer | null = null;
    for (const timer of this.timers)
      if (!next || timer.at < next.at || (timer.at === next.at && timer.seq < next.seq))
        next = timer;
    return next;
  }

  private nextFrameAt() {
    const at = Math.ceil(this.time / this.frameMs) * this.frameMs;
    return at > this.lastFrame ? at : this.lastFrame + this.frameMs;
  }

  /** Whether the next frame has work: callbacks, motion, observers or a changed page. */
  private frameDue() {
    if (this.frames.size > 0) return true;
    if (!this.layout) return false;
    if (this.changed) return true;
    for (const state of this.motion.values())
      if (state.playState === "running") return true;
    for (const scroller of this.scrollers.values()) if (scroller.moved) return true;
    if (this.smoothScrolls.size > 0) return true;
    return false;
  }

  /** Lets the microtasks of the work just run finish, as after a browser task. */
  /** Real time spent per kind of runtime work, in ms, for reports. */
  private readonly realMs: Record<string, number> = {};

  private timed<T>(kind: string, run: () => T): T {
    const started = realHost().now();
    try {
      return run();
    } finally {
      this.realMs[kind] = (this.realMs[kind] ?? 0) + realHost().now() - started;
    }
  }

  realTime() {
    return Object.fromEntries(
      Object.entries(this.realMs).map(([kind, ms]) => [kind, Math.round(ms)])
    );
  }

  /** Page script ran since the last task boundary: its microtasks may be pending. */
  private ranScript = false;

  private async settleMicrotasks() {
    if (this.ranScript) {
      if (debugRuntime) console.warn("[ui-runtime] settle");
      this.ranScript = false;
      const started = realHost().now();
      this.counts.realTasks = (this.counts.realTasks ?? 0) + 1;
      await nextRealTask();
      this.realMs.realTasks = (this.realMs.realTasks ?? 0) + realHost().now() - started;
    }
    // A message the page posted to a port of its own is on its way: it joins
    // the runtime's tasks when it arrives, before anything else runs.
    await portMessagesArrived();
  }

  /**
   * Runs the callbacks of one rendering step back to back, then lets their
   * microtasks and the React work they started run once. A browser checks
   * microtasks after each; a microtask of one callback here runs after the
   * next callback instead (on every run alike). One task boundary per step,
   * not per callback, is what keeps a frame cheap.
   */
  private async callAll(runs: (() => void)[]) {
    if (runs.length === 0) return;
    this.ranScript = true;
    for (const run of runs) {
      try {
        this.timed("callbacks", run);
      } catch (error) {
        reportError(error);
      }
    }
    await this.settleMicrotasks();
    await this.flushReact();
    await this.settleWork();
  }

  private async call(run: () => void) {
    this.ranScript = true;
    try {
      this.timed("callbacks", run);
    } catch (error) {
      reportError(error);
    }
    await this.settleMicrotasks();
    await this.flushReact();
    await this.settleWork();
  }

  /** Completes started work in the order it started, before time moves on. */
  /**
   * Delivers started IO in the order it started. No real-time limit: IO that
   * never completes leaves the test waiting until it fails, and the failure
   * names it (pendingWork).
   */
  private async settleWork() {
    while (this.works.length > 0) {
      const work = this.works[0]!;
      const waited = realHost().now();
      if (debugRuntime)
        console.warn(`[ui-runtime] waiting for ${work.key.slice(0, 80)}`);
      const result = await work.result;
      this.realMs.io = (this.realMs.io ?? 0) + realHost().now() - waited;
      this.works.shift();
      this.note(`work ${work.key} ${result.ok ? "done" : "failed"}`);
      this.ranScript = true;
      if (result.ok) work.resolve(result.value);
      else work.reject(result.error);
      await this.settleMicrotasks();
      await this.flushReact();
    }
  }

  /** IO started and not yet delivered, by key. */
  pendingWork() {
    return this.works.map((work) => work.key);
  }

  private async flushReact() {
    const scheduler = this.scheduler;
    if (!scheduler) return;
    for (let rounds = 0; scheduler.unstable_hasPendingWork(); rounds += 1) {
      // React work that schedules more work at the same instant forever never
      // lets page time move: fail rather than spin.
      if (rounds === 1_000)
        throw new Error("React kept scheduling work for 1000 rounds at one instant");
      this.counts.reactFlushes! += 1;
      try {
        this.ranScript = true;
        this.timed("react", () => scheduler.unstable_flushAllWithoutAsserting());
      } catch (error) {
        reportError(error);
      }
      await this.settleMicrotasks();
    }
  }

  private async runPosted() {
    while (this.posted.length > 0) {
      const entry = this.posted.shift()!;
      await this.call(entry.run);
    }
  }

  flush() {
    return this.exclusive(() => this.flushNow());
  }

  private async flushNow() {
    await this.settleMicrotasks();
    await this.flushReact();
    await this.settleWork();
    await this.runPosted();
    for (;;) {
      const timer = this.nextTimer();
      if (!timer || timer.at > this.time) break;
      await this.runTimer(timer);
    }
  }

  private async runTimer(timer: Timer) {
    this.setTime(timer.at);
    if (timer.interval === null) this.timers.delete(timer);
    else {
      timer.at += timer.interval;
      timer.seq = this.seq += 1;
    }
    this.counts.timers! += 1;
    this.note("timer");
    await this.call(timer.run);
    await this.runPosted();
  }

  private async runUntil(target: number, frameAtTarget = false) {
    await this.flushNow();
    for (;;) {
      const timer = this.nextTimer();
      const next = this.nextFrameAt();
      const frameAt =
        this.frameDue() || (frameAtTarget && next <= target) ? next : Infinity;
      if (timer && timer.at <= target && timer.at <= frameAt) {
        await this.runTimer(timer);
      } else if (frameAt <= target) {
        this.setTime(frameAt);
        await this.frame(frameAt);
      } else break;
    }
    this.setTime(target);
    await this.flushNow();
  }

  private running = 0;

  private async exclusive<T>(run: () => Promise<T>) {
    this.running += 1;
    try {
      return await run();
    } finally {
      this.running -= 1;
    }
  }

  busy() {
    return this.running > 0;
  }

  nextDue() {
    const timer = this.nextTimer();
    const frame = this.frameDue() ? this.nextFrameAt() : null;
    if (!timer) return frame;
    return frame === null ? timer.at : Math.min(timer.at, frame);
  }

  render() {
    return this.exclusive(async () => {
      await this.flushNow();
      if (!this.layout) return;
      this.note("render");
      this.changed = false;
      await this.scrollSteps();
      await this.animationSteps(this.lastFrame, true);
      await this.resizeSteps();
      await this.intersectionSteps();
      await this.runPosted();
    });
  }

  advance(ms: number) {
    return this.exclusive(() => this.runUntil(this.time + ms));
  }

  advanceFrames(count: number) {
    return this.exclusive(async () => {
      for (let i = 0; i < count; i += 1) await this.runUntil(this.nextFrameAt(), true);
    });
  }

  step() {
    return this.exclusive(async () => {
      const timer = this.nextTimer();
      const at = Math.min(
        timer?.at ?? Infinity,
        this.frameDue() ? this.nextFrameAt() : Infinity
      );
      if (at === Infinity) return false;
      await this.runUntil(Math.max(at, this.time), true);
      return true;
    });
  }

  private async frame(at: number) {
    this.lastFrame = at;
    this.counts.frames! += 1;
    this.note(
      `frame ${this.frames.size}${this.frameProbe && this.log ? ` ${this.frameProbe()}` : ""}`
    );
    if (this.layout) {
      this.changed = false;
      this.smoothScrollSteps(at);
      await this.scrollSteps();
      await this.afterScroll?.();
      await this.animationSteps(at);
    }
    const due = this.frames;
    this.frames = new Map();
    this.counts.frameCallbacks! += due.size;
    await this.callAll([...due.values()].map((run) => () => run(at)));
    if (this.layout) {
      await this.resizeSteps();
      await this.intersectionSteps();
    }
    await this.runPosted();
  }

  // -- scroll ---------------------------------------------------------------

  /**
   * An image's size arrives when the network delivers it: its load is work
   * that completes before time moves on, like any other load.
   */
  private awaitImage(image: HTMLImageElement) {
    // A lazy image loads when the browser finds it near the viewport, on its
    // own frames: under the runtime an image loads when it joins the page.
    if (image.loading === "lazy") image.loading = "eager";
    if (image.complete) return;
    void this.load.work(
      `image ${image.getAttribute("src") ?? ""}`,
      () =>
        new Promise<void>((resolve) => {
          image.addEventListener("load", () => resolve(), { once: true });
          image.addEventListener("error", () => resolve(), { once: true });
        })
    );
  }

  /**
   * Watches the scroll containers in `root`. One that just appeared or just
   * became a container starts from offset 0, so a scroll in the same task
   * still sends its event.
   */
  private findScrollers(root: Element, deep = true, fresh = true) {
    const visit = (element: Element) => {
      const inline = (element as HTMLElement).style;
      if (inline?.contentVisibility === "auto") inline.contentVisibility = "visible";
      if (this.scrollers.has(element)) return;
      const style = getComputedStyle(element);
      if (/(auto|scroll|hidden)/.test(style.overflowX + style.overflowY))
        this.watchScroller(element, false, fresh);
    };
    visit(root);
    if (deep) for (const element of root.querySelectorAll("*")) visit(element);
  }

  private watchScroller(element: Element, discovered: boolean, fresh = false) {
    if (this.scrollers.has(element)) return;
    if (discovered)
      this.violation(`scroll on ${describe(element)}, which the runtime did not watch`);
    this.scrollers.set(element, {
      top: fresh ? 0 : element.scrollTop,
      left: fresh ? 0 : element.scrollLeft,
      moved: false,
    });
  }

  /**
   * Starts a smooth scroll of `element` to (`left`, `top`): an ease-in-out
   * over sqrt(distance) / 60 s, at most 200 ms, as Chromium's delta-based
   * curve for a programmatic smooth scroll. A scroll that comes from
   * elsewhere meanwhile (input, another position set) ends it.
   */
  smoothScroll(element: Element, left: number, top: number, scrollTo: ScrollTo) {
    const maxLeft = Math.max(0, element.scrollWidth - element.clientWidth);
    const maxTop = Math.max(0, element.scrollHeight - element.clientHeight);
    const to: [number, number] = [
      Math.min(maxLeft, Math.max(0, left)),
      Math.min(maxTop, Math.max(0, top)),
    ];
    const from: [number, number] = [element.scrollLeft, element.scrollTop];
    const distance = Math.max(Math.abs(to[0] - from[0]), Math.abs(to[1] - from[1]));
    if (distance < 1) {
      this.smoothScrolls.delete(element);
      scrollTo.call(element, { left: to[0], top: to[1], behavior: "instant" });
      return;
    }
    this.findScrollers(element, false, false);
    this.smoothScrolls.set(element, {
      from,
      to,
      start: this.time,
      duration: (Math.min(Math.sqrt(distance), 12) / 60) * 1000,
      at: from,
      scrollTo,
    });
  }

  // Each frame, the smooth scrolls in progress move on.
  private smoothScrollSteps(at: number) {
    for (const [element, scroll] of this.smoothScrolls) {
      if (
        !element.isConnected ||
        Math.abs(element.scrollLeft - scroll.at[0]) > 1 ||
        Math.abs(element.scrollTop - scroll.at[1]) > 1
      ) {
        this.smoothScrolls.delete(element);
        continue;
      }
      const t = Math.min(1, (at - scroll.start) / scroll.duration);
      // cubic-bezier(0.42, 0, 0.58, 1), solved for its progress at time t.
      let lo = 0;
      let hi = 1;
      let u = t;
      for (let i = 0; i < 24; i += 1) {
        u = (lo + hi) / 2;
        const x =
          3 * u * (1 - u) * (1 - u) * 0.42 + 3 * u * u * (1 - u) * 0.58 + u * u * u;
        if (x < t) lo = u;
        else hi = u;
      }
      const eased = t >= 1 ? 1 : 3 * u * u * (1 - u) + u * u * u;
      const left = scroll.from[0] + (scroll.to[0] - scroll.from[0]) * eased;
      const top = scroll.from[1] + (scroll.to[1] - scroll.from[1]) * eased;
      scroll.scrollTo.call(element, { left, top, behavior: "instant" });
      scroll.at = [element.scrollLeft, element.scrollTop];
      if (t >= 1) this.smoothScrolls.delete(element);
    }
  }

  private async scrollSteps() {
    const scrolled: Element[] = [];
    const ended: Element[] = [];
    const root = document.scrollingElement;
    if (root) this.watchScroller(root, false);
    this.watchScroller(document.documentElement, false);
    if (document.body) this.watchScroller(document.body, false);
    const scrollStarted = realHost().now();
    for (const [element, state] of this.scrollers) {
      if (!element.isConnected) {
        this.scrollers.delete(element);
        continue;
      }
      const top = element.scrollTop;
      const left = element.scrollLeft;
      if (top !== state.top || left !== state.left) {
        state.top = top;
        state.left = left;
        state.moved = true;
        scrolled.push(element);
      } else if (state.moved) {
        state.moved = false;
        ended.push(element);
      }
    }
    this.realMs.scrollMeasure =
      (this.realMs.scrollMeasure ?? 0) + realHost().now() - scrollStarted;
    const send = (element: Element, type: string) => () => {
      if (element === root) document.dispatchEvent(new Event(type, { bubbles: true }));
      else element.dispatchEvent(new Event(type));
    };
    for (const element of scrolled) this.note(`scroll ${describe(element)}`);
    this.counts.scrollEvents! += scrolled.length;
    await this.callAll([
      ...scrolled.toSorted(documentOrder).map((element) => send(element, "scroll")),
      ...ended.toSorted(documentOrder).map((element) => send(element, "scrollend")),
    ]);
  }

  // -- motion ---------------------------------------------------------------

  motionCurrentTime(animation: Animation, real: () => CSSNumberish | null) {
    const state = this.motion.get(animation);
    if (!state) return real();
    if (state.playState === "idle") return null;
    if (state.start === null) return state.hold;
    return (this.lastFrame - state.start) * animation.playbackRate;
  }

  motionStartTime(animation: Animation, real: () => CSSNumberish | null) {
    const state = this.motion.get(animation);
    if (!state) return real();
    return state.start;
  }

  motionSetCurrentTime(animation: Animation, value: number | null) {
    const state = this.motion.get(animation);
    if (!state || value === null) return;
    if (state.start === null) state.hold = value;
    else state.start = this.lastFrame - value / (animation.playbackRate || 1);
  }

  motionSetStartTime(
    animation: Animation,
    value: number | null,
    setCurrentTime: (time: number) => void
  ) {
    let state = this.motion.get(animation);
    if (!state) state = this.track(animation);
    state.start = value;
    if (value !== null) {
      state.hold = null;
      setCurrentTime((this.lastFrame - value) * animation.playbackRate);
    }
  }

  private track(animation: Animation): MotionState {
    const state: MotionState = {
      start: null,
      hold: null,
      playState: animation.playState,
      phase: "",
      iteration: null,
      started: false,
      ended: false,
    };
    this.motion.set(animation, state);
    managedTime.set(animation, state);
    return state;
  }

  /**
   * Sets every animation's time from the frame time; with events, sends them.
   * Between frames (`held`), an animation that starts or resumes keeps its
   * time: it runs from the next frame.
   */
  private syncMotion(at: number, events: boolean, held = false) {
    const sends: (() => void)[] = [];
    const seen = new Set<Animation>();
    for (const animation of document.getAnimations()) {
      seen.add(animation);
      let state = this.motion.get(animation);
      const fresh = !state;
      if (!state) state = this.track(animation);
      const playState = animation.playState;
      // Whether the browser has resolved a pending play or pause yet depends
      // on its real frames: set the time the runtime decides in either case.
      if (playState === "paused") {
        if (state.start !== null) {
          state.hold = (at - state.start) * animation.playbackRate;
          state.start = null;
        }
        state.hold ??= Number(realCurrentTime(animation) ?? 0);
        setRealCurrentTime(animation, state.hold);
      } else if (playState === "running") {
        if (state.start === null && held) {
          state.hold ??= Number(realCurrentTime(animation) ?? 0);
          setRealCurrentTime(animation, state.hold);
        } else {
          if (state.start === null) {
            const offset = state.hold ?? Number(realCurrentTime(animation) ?? 0);
            state.start = at - offset / (animation.playbackRate || 1);
            state.hold = null;
          }
          setRealCurrentTime(animation, (at - state.start) * animation.playbackRate);
        }
      }
      state.playState = animation.playState;
      if (events) this.motionEvents(animation, state, fresh, sends);
    }
    for (const [animation, state] of this.motion) {
      if (seen.has(animation)) continue;
      if (events && !state.ended) {
        state.ended = true;
        this.eventLabels.push(`cancel:${animation.constructor.name}`);
        sends.push(() => cancelEvent(animation, state));
      }
      this.motion.delete(animation);
    }
    return sends;
  }

  private motionEvents(
    animation: Animation,
    state: MotionState,
    fresh: boolean,
    sends: (() => void)[]
  ) {
    const timing = animation.effect?.getComputedTiming();
    const target = (animation.effect as KeyframeEffect | null)?.target ?? null;
    const pseudo = (animation.effect as KeyframeEffect | null)?.pseudoElement ?? "";
    const phase = phaseOf(animation, timing);
    const iteration = timing?.currentIteration ?? null;
    const activeDuration = Number(timing?.activeDuration ?? 0);
    const delay = Number(timing?.delay ?? 0);
    const localTime = Number(timing?.localTime ?? 0);
    if (isCssTransition(animation) && target) {
      const propertyName = animation.transitionProperty;
      const send = (type: string, time: number) =>
        this.eventLabels.push(`${type}:${propertyName}@${describe(target)}`) &&
        sends.push(() =>
          target.dispatchEvent(
            new TransitionEvent(type, {
              bubbles: true,
              propertyName,
              elapsedTime: seconds(time),
              pseudoElement: pseudo,
            })
          )
        );
      if (fresh) send("transitionrun", 0);
      if (!state.started && (phase === "active" || phase === "after")) {
        state.started = true;
        send("transitionstart", 0);
      }
      if (!state.ended && phase === "after") {
        state.ended = true;
        send("transitionend", activeDuration);
      }
    } else if (isCssAnimation(animation) && target) {
      const animationName = animation.animationName;
      const send = (type: string, time: number) =>
        this.eventLabels.push(`${type}:${animationName}@${describe(target)}`) &&
        sends.push(() =>
          target.dispatchEvent(
            new AnimationEvent(type, {
              bubbles: true,
              animationName,
              elapsedTime: seconds(time),
              pseudoElement: pseudo,
            })
          )
        );
      if (!state.started && (phase === "active" || phase === "after")) {
        state.started = true;
        send("animationstart", Math.max(0, -delay));
      } else if (
        phase === "active" &&
        state.iteration !== null &&
        iteration !== null &&
        iteration !== state.iteration
      ) {
        send("animationiteration", Math.max(0, localTime - delay));
      }
      if (!state.ended && phase === "after") {
        state.ended = true;
        send("animationend", activeDuration);
      }
    } else if (!state.ended && animation.playState === "finished") {
      state.ended = true;
      this.eventLabels.push(`finish:${animation.id}`);
      sends.push(() =>
        animation.dispatchEvent(
          new AnimationPlaybackEvent("finish", {
            currentTime: animation.currentTime,
            timelineTime: this.lastFrame,
          })
        )
      );
    }
    if (
      animation.playState !== "finished" &&
      phase !== "after" &&
      isPlainAnimation(animation)
    )
      state.ended = false;
    state.iteration = iteration;
    state.phase = phase;
  }

  /**
   * A CSS animation of no duration (as reduced motion makes them) starts and
   * ends in the style update that creates it: it is never among the
   * document's running animations at a frame, and the browser's own events
   * for it are dropped like every timed event. Its element's style says it
   * started: each new animation name with no active time sends
   * `animationstart` and `animationend` on the frame after it appeared, once,
   * as a browser does.
   */
  private instantAnimationSteps(): (() => void)[] {
    const sends: (() => void)[] = [];
    const changed = [...this.styleChanged];
    this.styleChanged.clear();
    for (const element of changed) {
      if (!element.isConnected) continue;
      const style = getComputedStyle(element);
      const names = style.animationName;
      const before = this.animationNames.get(element) ?? "none";
      if (names === before) continue;
      this.animationNames.set(element, names);
      if (names === "none") continue;
      const previous = new Set(cssList(before));
      const durations = cssList(style.animationDuration);
      const delays = cssList(style.animationDelay);
      const counts = cssList(style.animationIterationCount);
      cssList(names).forEach((name, index) => {
        if (name === "" || name === "none" || previous.has(name)) return;
        const pick = (values: string[]) => values[index % values.length] ?? "0s";
        const duration = parseFloat(pick(durations)) || 0;
        const count = pick(counts) === "infinite" ? Infinity : parseFloat(pick(counts));
        const delay = parseFloat(pick(delays)) || 0;
        if (duration * count !== 0 || delay > 0) return;
        for (const type of ["animationstart", "animationend"]) {
          this.eventLabels.push(`${type}:${name}@${describe(element)}`);
          sends.push(() =>
            element.dispatchEvent(
              new AnimationEvent(type, {
                bubbles: true,
                animationName: name,
                elapsedTime: 0,
              })
            )
          );
        }
      });
    }
    return sends;
  }

  private async animationSteps(at: number, held = false) {
    const sends = this.timed("motion", () => [
      ...this.instantAnimationSteps(),
      ...this.syncMotion(at, true, held),
    ]);
    this.counts.animationEvents! += sends.length;
    await this.callAll(sends);
    if (sends.length > 0) this.note(`animation events ${this.eventLabels.join(" ")}`);
    this.eventLabels = [];
  }

  // -- ResizeObserver ---------------------------------------------------------

  private async resizeSteps() {
    let shallowest = 0;
    let depthLimit = -1;
    for (let round = 0; round < 64; round += 1) {
      const deliveries: {
        entry: ResizeEntry;
        items: ResizeObserverEntry[];
      }[] = [];
      let skipped = false;
      let nextShallowest = Infinity;
      for (const entry of layoutObservers.resize) {
        const items: ResizeObserverEntry[] = [];
        for (const observation of entry.observations) {
          const size = this.timed("resizeMeasure", () =>
            boxSize(observation.target, observation.box)
          );
          const last = observation.last;
          if (last && last[0] === size[0] && last[1] === size[1]) continue;
          if (
            !last &&
            size[0] === 0 &&
            size[1] === 0 &&
            observation.target.isConnected === false
          )
            continue;
          const depth = depthOf(observation.target);
          if (depth <= depthLimit) {
            skipped = true;
            continue;
          }
          observation.last = size;
          nextShallowest = Math.min(nextShallowest, depth);
          items.push(resizeEntry(observation.target));
        }
        if (items.length > 0) deliveries.push({ entry, items });
      }
      if (deliveries.length === 0) {
        if (skipped)
          await this.call(() =>
            window.dispatchEvent(
              new ErrorEvent("error", {
                message:
                  "ResizeObserver loop completed with undelivered notifications.",
              })
            )
          );
        return;
      }
      for (const { items } of deliveries)
        this.note(`resize ${items.map((item) => describe(item.target)).join(",")}`);
      this.counts.resizeNotifications! += deliveries.length;
      await this.callAll(
        deliveries.map(
          ({ entry, items }) =>
            () =>
              entry.callback(items, entry.observer)
        )
      );
      shallowest = nextShallowest;
      depthLimit = shallowest;
    }
  }

  // -- IntersectionObserver ---------------------------------------------------

  private async intersectionSteps() {
    const deliveries: {
      entry: IntersectionEntry;
      items: IntersectionObserverEntry[];
    }[] = [];
    for (const entry of layoutObservers.intersection) {
      const items: IntersectionObserverEntry[] = [];
      for (const observation of entry.observations) {
        const result = this.timed("intersectionMeasure", () =>
          intersect(observation.target, entry.root, entry.margin)
        );
        const ratio = result.ratio;
        let index = 0;
        while (index < entry.thresholds.length && entry.thresholds[index]! <= ratio)
          index += 1;
        const intersecting = result.intersecting;
        if (index === observation.index && intersecting === observation.intersecting)
          continue;
        observation.index = index;
        observation.intersecting = intersecting;
        items.push({
          time: this.time,
          target: observation.target,
          rootBounds: result.rootBounds,
          boundingClientRect: result.bounds,
          intersectionRect: result.intersection,
          intersectionRatio: ratio,
          isIntersecting: intersecting,
        } as IntersectionObserverEntry);
      }
      if (items.length > 0) deliveries.push({ entry, items });
    }
    for (const { items } of deliveries)
      this.note(
        `intersection ${items.map((item) => `${describe(item.target)}:${item.intersectionRatio.toFixed(3)}`).join(",")}`
      );
    this.counts.intersectionNotifications! += deliveries.length;
    await this.callAll(
      deliveries.map(
        ({ entry, items }) =>
          () =>
            entry.callback(items, entry.observer)
      )
    );
  }
}

function cssList(value: string) {
  return value.split(",").map((part) => part.trim());
}

function describe(element: Element) {
  const id = element.id ? `#${element.id}` : "";
  const slot = element.getAttribute("data-slot");
  const classes = [...element.classList]
    .slice(0, 2)
    .map((name) => `.${name}`)
    .join("");
  return `${element.localName}${id}${classes}${slot ? `[${slot}]` : ""}`;
}

type ResizeEntry = {
  callback: ResizeObserverCallback;
  observer: ResizeObserver;
  observations: ResizeObservation[];
};
type IntersectionEntry = {
  callback: IntersectionObserverCallback;
  observer: IntersectionObserver;
  root: Element | Document | null;
  margin: [number, number, number, number];
  thresholds: number[];
  observations: IntersectionObservation[];
};

// Observers belong to the page, not to one runtime: a module keeps the one it
// made while an earlier test ran. The active runtime notifies all of them.
const layoutObservers = {
  resize: [] as ResizeEntry[],
  intersection: [] as IntersectionEntry[],
};

function createResizeObserver(callback: ResizeObserverCallback): ResizeObserver {
  const entry: ResizeEntry = {
    callback,
    observations: [],
    observer: null as unknown as ResizeObserver,
  };
  entry.observer = {
    observe: (target: Element, options?: ResizeObserverOptions) => {
      entry.observations = entry.observations.filter((each) => each.target !== target);
      entry.observations.push({
        target,
        box: options?.box ?? "content-box",
        last: null,
      });
      active?.invalidate();
    },
    unobserve: (target: Element) => {
      entry.observations = entry.observations.filter((each) => each.target !== target);
    },
    disconnect: () => {
      entry.observations = [];
    },
  } as ResizeObserver;
  layoutObservers.resize.push(entry);
  return entry.observer;
}

function createIntersectionObserver(
  callback: IntersectionObserverCallback,
  options: IntersectionObserverInit = {}
): IntersectionObserver {
  const threshold = options.threshold ?? 0;
  const thresholds = (Array.isArray(threshold) ? threshold : [threshold]).toSorted(
    (a, b) => a - b
  );
  const entry: IntersectionEntry = {
    callback,
    root: options.root ?? null,
    margin: parseMargin(options.rootMargin ?? "0px"),
    thresholds,
    observations: [],
    observer: null as unknown as IntersectionObserver,
  };
  entry.observer = {
    root: entry.root,
    rootMargin: options.rootMargin ?? "0px",
    scrollMargin: "0px",
    thresholds,
    observe: (target: Element) => {
      if (entry.observations.some((each) => each.target === target)) return;
      entry.observations.push({ target, index: -1, intersecting: false });
      active?.invalidate();
    },
    unobserve: (target: Element) => {
      entry.observations = entry.observations.filter((each) => each.target !== target);
    },
    disconnect: () => {
      entry.observations = [];
    },
    takeRecords: () => [],
  } as unknown as IntersectionObserver;
  layoutObservers.intersection.push(entry);
  return entry.observer;
}

/**
 * Which `content-visibility: auto` subtrees a browser skips is decided on its
 * own rendering steps, and those run whenever the test waits: a read of the
 * page could see either layout. Under the test runtime every such subtree
 * renders (`visible`); an inline `auto` is the same (see findScrollers).
 */
function renderContentVisibilityRules(rules: CSSRuleList) {
  for (const rule of rules) {
    if (rule instanceof CSSStyleRule && rule.style.contentVisibility === "auto")
      rule.style.contentVisibility = "visible";
    if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules)
      renderContentVisibilityRules((rule as CSSGroupingRule).cssRules);
  }
}

function renderEveryContentVisibility() {
  for (const sheet of document.styleSheets) {
    try {
      renderContentVisibilityRules(sheet.cssRules);
    } catch {
      // A cross-origin sheet: the fixtures load none.
    }
  }
}

type Settled = { ok: true; value: unknown } | { ok: false; error: unknown };

// One channel for every task boundary the runtime waits for: the microtasks
// of the work just run have all finished when its message arrives.
let taskChannel: MessageChannel | undefined;
const taskWaiters: (() => void)[] = [];

function nextRealTask() {
  if (!taskChannel) {
    taskChannel = new (realHost().MessageChannel)();
    taskChannel.port1.addEventListener("message", () => taskWaiters.shift()?.());
    taskChannel.port1.start();
  }
  const channel = taskChannel;
  return new Promise<void>((resolve) => {
    taskWaiters.push(resolve);
    channel.port2.postMessage(null);
  });
}

function documentOrder(a: Element, b: Element) {
  if (a === b) return 0;
  return a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
}

function realCurrentTime(animation: Animation) {
  const descriptor = realDescriptors().currentTime;
  return descriptor.get!.call(animation) as number | null;
}
function setRealCurrentTime(animation: Animation, time: number) {
  realDescriptors().currentTime.set!.call(animation, time);
}
let descriptors: { currentTime: PropertyDescriptor } | undefined;
function realDescriptors() {
  if (!descriptors) {
    // The patched accessors call through to the platform's; keep those.
    descriptors = { currentTime: platformCurrentTime! };
  }
  return descriptors;
}
const platformCurrentTime =
  typeof Animation === "undefined"
    ? undefined
    : Object.getOwnPropertyDescriptor(Animation.prototype, "currentTime");

function isCssTransition(animation: Animation): animation is CSSTransition {
  return typeof CSSTransition !== "undefined" && animation instanceof CSSTransition;
}
function isCssAnimation(animation: Animation): animation is CSSAnimation {
  return typeof CSSAnimation !== "undefined" && animation instanceof CSSAnimation;
}
function isPlainAnimation(animation: Animation) {
  return !isCssTransition(animation) && !isCssAnimation(animation);
}

function phaseOf(animation: Animation, timing: ComputedEffectTiming | undefined) {
  if (!timing || timing.localTime === null || timing.localTime === undefined)
    return "idle";
  const local = Number(timing.localTime);
  const delay = Number(timing.delay ?? 0);
  const activeDuration = Number(timing.activeDuration ?? 0);
  const rate = animation.playbackRate;
  if (local < delay || (rate < 0 && local === delay)) return "before";
  const end = delay + activeDuration;
  if (local > end || (rate >= 0 && local === end && activeDuration !== Infinity))
    return "after";
  return "active";
}

function cancelEvent(animation: Animation, _state: MotionState) {
  const target = (animation.effect as KeyframeEffect | null)?.target;
  if (isCssTransition(animation) && target)
    target.dispatchEvent(
      new TransitionEvent("transitioncancel", {
        bubbles: true,
        propertyName: animation.transitionProperty,
      })
    );
  else if (isCssAnimation(animation) && target)
    target.dispatchEvent(
      new AnimationEvent("animationcancel", {
        bubbles: true,
        animationName: animation.animationName,
      })
    );
}

function depthOf(element: Element) {
  let depth = 0;
  for (let node: Node | null = element; node; node = node.parentNode) depth += 1;
  return depth;
}

const seconds = (ms: number) => Math.max(0, ms) / 1000;
const px = (value: string) => parseFloat(value) || 0;

function boxSize(element: Element, box: ResizeObserverBoxOptions): [number, number] {
  if (!element.isConnected) return [0, 0];
  if (element instanceof SVGGraphicsElement && !(element instanceof SVGSVGElement)) {
    const bbox = element.getBBox();
    return [bbox.width, bbox.height];
  }
  const style = getComputedStyle(element);
  if (style.display === "none" || style.display === "contents") return [0, 0];
  if (style.display === "inline" && !isReplaced(element)) return [0, 0];
  const width = parseFloat(style.width) || 0;
  const height = parseFloat(style.height) || 0;
  const horizontal =
    px(style.paddingLeft) +
    px(style.paddingRight) +
    px(style.borderLeftWidth) +
    px(style.borderRightWidth);
  const vertical =
    px(style.paddingTop) +
    px(style.paddingBottom) +
    px(style.borderTopWidth) +
    px(style.borderBottomWidth);
  const borderBox = style.boxSizing === "border-box";
  if (box === "border-box")
    return borderBox ? [width, height] : [width + horizontal, height + vertical];
  return borderBox ? [width - horizontal, height - vertical] : [width, height];
}

function isReplaced(element: Element) {
  return /^(IMG|VIDEO|CANVAS|IFRAME|EMBED|OBJECT|INPUT|TEXTAREA|SELECT|svg)$/i.test(
    element.tagName
  );
}

function resizeEntry(target: Element): ResizeObserverEntry {
  const [contentWidth, contentHeight] = boxSize(target, "content-box");
  const [borderWidth, borderHeight] = boxSize(target, "border-box");
  const style = target.isConnected ? getComputedStyle(target) : null;
  const left = style ? parseFloat(style.paddingLeft) || 0 : 0;
  const top = style ? parseFloat(style.paddingTop) || 0 : 0;
  const ratio = window.devicePixelRatio;
  return {
    target,
    contentRect: new DOMRectReadOnly(left, top, contentWidth, contentHeight),
    contentBoxSize: [{ inlineSize: contentWidth, blockSize: contentHeight }],
    borderBoxSize: [{ inlineSize: borderWidth, blockSize: borderHeight }],
    devicePixelContentBoxSize: [
      {
        inlineSize: Math.round(contentWidth * ratio),
        blockSize: Math.round(contentHeight * ratio),
      },
    ],
  } as ResizeObserverEntry;
}

function parseMargin(margin: string): [number, number, number, number] {
  const parts = margin
    .trim()
    .split(/\s+/)
    .map((part) => parseFloat(part) || 0);
  const [top = 0, right = top, bottom = top, left = right] = parts;
  return [top, right, bottom, left];
}

function intersect(
  target: Element,
  root: Element | Document | null,
  margin: [number, number, number, number]
) {
  const bounds = target.getBoundingClientRect();
  const rootElement = root instanceof Element ? root : null;
  let rootRect: DOMRect;
  if (rootElement) {
    const rect = rootElement.getBoundingClientRect();
    rootRect = new DOMRect(
      rect.x + rootElement.clientLeft,
      rect.y + rootElement.clientTop,
      rootElement.clientWidth,
      rootElement.clientHeight
    );
  } else {
    rootRect = new DOMRect(
      0,
      0,
      document.documentElement.clientWidth,
      window.innerHeight
    );
  }
  const [mt, mr, mb, ml] = margin;
  rootRect = new DOMRect(
    rootRect.x - ml,
    rootRect.y - mt,
    rootRect.width + ml + mr,
    rootRect.height + mt + mb
  );
  const connected =
    target.isConnected && (!rootElement || rootElement.contains(target));
  let x1 = bounds.left;
  let y1 = bounds.top;
  let x2 = bounds.right;
  let y2 = bounds.bottom;
  if (connected)
    for (
      let parent = target.parentElement;
      parent && parent !== rootElement;
      parent = parent.parentElement
    ) {
      const style = getComputedStyle(parent);
      if (style.overflowX === "visible" && style.overflowY === "visible") continue;
      const rect = parent.getBoundingClientRect();
      const left = rect.left + parent.clientLeft;
      const top = rect.top + parent.clientTop;
      if (style.overflowX !== "visible") {
        x1 = Math.max(x1, left);
        x2 = Math.min(x2, left + parent.clientWidth);
      }
      if (style.overflowY !== "visible") {
        y1 = Math.max(y1, top);
        y2 = Math.min(y2, top + parent.clientHeight);
      }
    }
  x1 = Math.max(x1, rootRect.left);
  y1 = Math.max(y1, rootRect.top);
  x2 = Math.min(x2, rootRect.right);
  y2 = Math.min(y2, rootRect.bottom);
  const intersecting = connected && x2 >= x1 && y2 >= y1;
  const intersection = intersecting
    ? new DOMRect(x1, y1, x2 - x1, y2 - y1)
    : new DOMRect();
  const area = bounds.width * bounds.height;
  const ratio = !intersecting
    ? 0
    : area > 0
      ? (intersection.width * intersection.height) / area
      : 1;
  return { bounds, rootBounds: rootRect, intersection, intersecting, ratio };
}

export function createTestUiRuntime(options: TestUiRuntimeOptions = {}): TestUiRuntime {
  const runtime = new Runtime(options);
  const service = runtime.runtime();
  return {
    ...service,
    seed: runtime.seed,
    elapsed: () => runtime.elapsed(),
    advance: (ms) => runtime.advance(ms),
    advanceFrames: (count) => runtime.advanceFrames(count),
    flush: () => runtime.flush(),
    render: () => runtime.render(),
    step: () => runtime.step(),
    busy: () => runtime.busy(),
    nextDue: () => runtime.nextDue(),
    prepare: () => runtime.prepare(),
    violations: () => runtime.violations(),
    pendingWork: () => runtime.pendingWork(),
    whenBrowserSends: (type, target) => runtime.whenBrowserSends(type, target),
    stats: () => runtime.stats(),
    realTime: () => runtime.realTime(),
    trace: () => runtime.trace(),
    note: (line) => runtime.note(line),
    invalidate: () => runtime.invalidate(),
    install: () => runtime.install(),
  };
}

/** The active test runtime, if any. */
export function activeTestUiRuntime(): boolean {
  return active !== undefined;
}
