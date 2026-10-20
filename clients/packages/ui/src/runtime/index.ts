/**
 * The one runtime of UI code (packages/app, packages/ui and the renderer entry
 * points): every side effect whose timing or result can differ between runs —
 * time, motion, randomness, loading, layout observers, deferred tasks,
 * storage and event times — goes through one of its services, never through
 * the platform directly. In production each service is the platform's. A test
 * installs `createTestUiRuntime` (`./test/testing`), whose one scheduler decides
 * when and in which order every service's work runs, so a test's result
 * depends only on the code and its seed.
 *
 * The clock service is `uiClock` (`../clock`); this module adds the others and
 * installs them together.
 */
import { installUiClock, realUiClock, uiClock, type UiClock } from "../clock";

export type UiRandom = {
  /** A number in [0, 1) (`Math.random()`). */
  next(): number;
  /** A random RFC 4122 v4 id (`crypto.randomUUID()`). */
  uuid(): string;
};

export type UiTask = {
  /** Runs `run` after the current task (`queueMicrotask`). */
  microtask(run: () => void): void;
  /** Runs `run` in a task of its own, before any timer (`MessageChannel`). */
  post(run: () => void): () => void;
};

export type UiMotion = {
  /** Starts a Web Animation (`element.animate`). */
  animate(
    element: Element,
    keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
    options?: number | KeyframeAnimationOptions
  ): Animation;
};

export type UiObserve = {
  resize(callback: ResizeObserverCallback): ResizeObserver;
  intersection(
    callback: IntersectionObserverCallback,
    options?: IntersectionObserverInit
  ): IntersectionObserver;
  mutation(callback: MutationCallback): MutationObserver;
};

/**
 * Loading that finishes after a time the network or disk decides: modules
 * imported on demand, fonts, decoded images. Declare a module where the code
 * that needs it lives; a test runtime loads every declared module before the
 * fixture mounts, and a load it was not ready for fails the test.
 */
export type UiLoad = {
  /** Imports the module of `key` once, with `load`. */
  module<T>(key: string, load: () => Promise<T>): Promise<T>;
  /** The module of `key` if it is loaded already, without waiting. */
  ready<T>(key: string): T | undefined;
  /** Resolves when `image` is decoded (`image.decode()`). */
  decode(image: HTMLImageElement): Promise<void>;
  /**
   * Work that completes after a time something outside the page decides (a
   * worker, a parser that loads its grammar on demand). In a test runtime it
   * completes before time moves on, results in the order the work started.
   */
  work<T>(key: string, run: () => Promise<T>): Promise<T>;
};

export type UiStorage = {
  local(): Storage;
  session(): Storage;
};

export type UiRuntime = {
  clock: UiClock;
  random: UiRandom;
  task: UiTask;
  motion: UiMotion;
  observe: UiObserve;
  load: UiLoad;
  storage: UiStorage;
  /** The time an input event happened on the clock's monotonic scale (`event.timeStamp`). */
  eventTime(event: Event): number;
};

const loaded = new Map<string, Promise<unknown>>();
const settled = new Map<string, unknown>();

export const realUiRuntime: UiRuntime = {
  clock: realUiClock,
  random: {
    next: () => Math.random(),
    uuid: () => crypto.randomUUID(),
  },
  task: {
    microtask: (run) => queueMicrotask(run),
    post(run) {
      let live = true;
      const channel = new MessageChannel();
      channel.port1.addEventListener("message", () => {
        channel.port1.close();
        if (live) run();
      });
      channel.port1.start();
      channel.port2.postMessage(null);
      return () => {
        live = false;
        channel.port1.close();
      };
    },
  },
  motion: {
    animate: (element, keyframes, options) => element.animate(keyframes, options),
  },
  observe: {
    resize: (callback) => new ResizeObserver(callback),
    intersection: (callback, options) => new IntersectionObserver(callback, options),
    mutation: (callback) => new MutationObserver(callback),
  },
  load: {
    module<T>(key: string, load: () => Promise<T>) {
      let pending = loaded.get(key) as Promise<T> | undefined;
      if (!pending) {
        pending = load().then((value) => {
          settled.set(key, value);
          return value;
        });
        loaded.set(key, pending);
      }
      return pending;
    },
    ready: <T>(key: string) => settled.get(key) as T | undefined,
    decode: (image) => image.decode(),
    work: (_key, run) => run(),
  },
  storage: {
    local: () => localStorage,
    session: () => sessionStorage,
  },
  eventTime: (event) => event.timeStamp,
};

let current: UiRuntime = realUiRuntime;

/** The installed UI runtime. Each call goes to the runtime installed at that time. */
export const uiRuntime: UiRuntime = {
  clock: uiClock,
  random: {
    next: () => current.random.next(),
    uuid: () => current.random.uuid(),
  },
  task: {
    microtask: (run) => current.task.microtask(run),
    post: (run) => current.task.post(run),
  },
  motion: {
    animate: (element, keyframes, options) =>
      current.motion.animate(element, keyframes, options),
  },
  observe: {
    resize: (callback) => current.observe.resize(callback),
    intersection: (callback, options) =>
      current.observe.intersection(callback, options),
    mutation: (callback) => current.observe.mutation(callback),
  },
  load: {
    module: (key, load) => current.load.module(key, load),
    ready: (key) => current.load.ready(key),
    decode: (image) => current.load.decode(image),
    work: (key, run) => current.load.work(key, run),
  },
  storage: {
    local: () => current.storage.local(),
    session: () => current.storage.session(),
  },
  eventTime: (event) => current.eventTime(event),
};

const declared = new Map<string, () => Promise<unknown>>();

export type UiModule<T> = {
  /** Imports the module, once. */
  load(): Promise<T>;
  /** The module if it is loaded already. */
  ready(): T | undefined;
};

/**
 * Declares a module that UI code imports on demand, where that code lives.
 * Declaring it when the code's own module evaluates lets a test runtime load
 * it before anything renders (`declaredUiModules`).
 */
export function declareUiModule<T>(key: string, load: () => Promise<T>): UiModule<T> {
  declared.set(key, load);
  return {
    load: () => uiRuntime.load.module(key, load),
    ready: () => uiRuntime.load.ready<T>(key),
  };
}

/** Every module declared so far, by key. */
export function declaredUiModules(): ReadonlyMap<string, () => Promise<unknown>> {
  return declared;
}

/**
 * Makes `runtime` the UI runtime, its clock the UI clock. Returns a function
 * that puts the previous runtime back.
 */
export function installUiRuntime(runtime: UiRuntime): () => void {
  const previous = current;
  const restoreClock = installUiClock(runtime.clock);
  current = runtime;
  return () => {
    current = previous;
    restoreClock();
  };
}
