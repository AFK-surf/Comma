// The page of one browser component test on fake timers, for a spec that
// opts out of the UI runtime (../../ui-runtime/child): an iframe of its own (./virtual-time
// makes it and removes it when the test ends), loading this module first. A
// test starts from a fresh document, fresh modules and fresh storage, as a
// page load gives; nothing a test leaves reaches the next.
//
// Here, in the page's own realm, live the test clock (fake timers, frames and
// held animations), the media fakes and the fixture mount. `./page` drives
// them through `window.commaPage`.

import interItalicUrl from "../../../packages/ui/src/fonts/InterVariable-Italic.woff2?url";
import interUrl from "../../../packages/ui/src/fonts/InterVariable.woff2?url";
import { withGlobal } from "@sinonjs/fake-timers";
import { testEpoch } from "@comma/test-utils/test-epoch";
import type { HttpRoute, RealmControl } from "../../ui-runtime/realm";
import type { Exchanged } from "../../ui-runtime/scripted-peer";
import {
  driveAnimations,
  installAnimationHold,
  releaseAnimations,
} from "./animation-hold";
import { frameState } from "./digest";
import { installSeededRandom, seedNestedFrames } from "./random";
import { deliverWorkerMessages, holdWorkers, workersIdle } from "./workers";
import {
  deliverResponses,
  downloadsOfPage,
  popupsOfPage,
  holdRequests,
  keepDownloads,
  keepPopups,
  requestsIdle,
  type Download,
  type Popup,
} from "./requests";
import { hoverState, nudgeLayout, setPointer } from "./hover";
import { installFakeMedia, type FakeMediaSources } from "./fake-media";
import {
  countLayoutWatchers,
  deliverIntersections,
  scrolledSinceLastCheck,
  watchesLayout,
} from "./layout-watch";
import {
  keepNativeFrame,
  markAttached,
  runFramesOnTestClock,
  trackPageMessages,
  virtualFrameMs,
} from "../../helpers/virtual-time";

// The fixtures this page can mount, each its own chunk: in the built pages
// (vitest.config.ts, appShellPagesBuild) and from the dev server alike.
const fixtures = import.meta.glob<unknown>("../fixtures/*/src/main.{ts,tsx}");

export type AdvanceOptions = { eachFrame?: boolean; afterInput?: boolean };

export type TestPage = {
  advance(ms: number, options?: AdvanceOptions): Promise<void>;
  elapsed(): number;
  /**
   * Loads the fixture module at `moduleUrl` on `body`. A module of the shipped
   * web build (`/assets/…`) loads as its index.html loads it, after `styles`.
   */
  mount(
    moduleUrl: string,
    search: string,
    body: string,
    styles?: readonly string[]
  ): Promise<void>;
  fakeMedia(sources: FakeMediaSources): void;
  frameState(): { html: string; animations: string[]; boxes: string[] };
  /** Where the test's pointer is over this page; undefined when outside it. */
  setPointer(at: { x: number; y: number } | undefined): void;
  /** Resolves once no dynamic import is loading. */
  importsLoaded(): Promise<void>;
  /** Whether the page still draws its random numbers from the test's seed. */
  randomSeeded(): boolean;
  /** The downloads the page asked for, in order (./requests). */
  downloads(): Download[];
  /** The popups the page opened, in order (./requests). */
  popups(): Popup[];
  /** Every request the page made, in order: "<initiator> <url>". */
  resources(): string[];
  /** How many real frames the page waited for, and for how long in ms. */
  nativeFrames(): { count: number; time: number; reasons: Record<string, number> };
  /** Real time its mounts spent loading the fixture's module and rendering it. */
  mountTimes(): { load: number; render: number };
  /**
   * A page on the UI runtime (../../ui-runtime/child) sends the test's input
   * itself: it waits for what the input makes the browser send it, then runs
   * what that started.
   */
  input?<T>(name: string, args: unknown[], send: () => Promise<T>): Promise<T>;
  /**
   * Runs what is due in the page now, without moving page time: on the UI
   * runtime, React's work is the runtime's to run.
   */
  settle?(): Promise<void>;
  /**
   * Makes the page a realm of a world (./world): from now on the workers it
   * starts are realms too, and what it exchanges with them is held for the
   * world to hand over. Returns the page's realm and its workers'.
   */
  world?(options?: {
    /** No worker runs: the page's worker is a line to the player of a record (../../ui-runtime/scripted-peer.ts). */
    replay?: boolean;
  }): {
    /** What the page and its first worker exchanged so far and where the page rested, in the page's order. */
    exchanged(): Exchanged[];
    /** A step of the test on another realm, noted among what the page exchanged. */
    step(name: string, args?: readonly unknown[], result?: unknown): void;
    /** The world's time moved to `at` for a realm a view alone runs without, noted among what the page exchanged. */
    due(at: number): void;
    /** A page that replays a record: a message of the record reaches it. */
    inject(data: unknown): void;
    page: RealmControl;
    workers(): string[];
    worker(name: string): RealmControl;
    /** From now on the page's and its workers' requests to the route's origin go to the route's realm. */
    http(route: HttpRoute): Promise<void>;
  };
  /** What the page did that its UI runtime does not control. */
  violations?(): string[];
  /** IO the page started that has not reached it yet. */
  pendingWork?(): string[];
  release(): void;
};

declare global {
  interface Window {
    commaPage?: TestPage;
    commaPageReady?: Promise<void>;
  }
}

// React Aria's virtualizer skips measuring under NODE_ENV=test unless
// process.env.VIRT_ON is set. Real layout here measures as the app does.
const scope = globalThis as {
  process?: { env: Record<string, string | undefined> };
  __name?: (fn: unknown) => unknown;
};
// Functions a test evaluates here keep the names its compiler gave them.
// oxlint-disable-next-line no-underscore-dangle -- the compiler's helper name.
scope.__name = (fn) => fn;

// A task that runs as soon as the tasks before it did. The fake timers yield
// to the event loop after each timer they run, with `setImmediate` where there
// is one and `setTimeout` elsewhere, which a frame runs no sooner than its next
// frame. They read it once, when made, so it exists for that moment only: a
// page module that saw it would schedule on it (React's scheduler would).
const channel = new MessageChannel();
const yields: (() => void)[] = [];
channel.port1.addEventListener("message", () => yields.shift()?.());
channel.port1.start();
const yieldTask = (callback: () => void) => {
  yields.push(callback);
  channel.port2.postMessage(undefined);
};

// Styles are computed after every task that changes the page, before
// Chromium could render a frame of its own between tasks. A transition starts
// when a computed style changes, so which changes start one follows the code,
// not whether a real frame happened to fall between two tasks.
new MutationObserver(() => {
  document.documentElement.getBoundingClientRect();
}).observe(document, {
  attributes: true,
  characterData: true,
  childList: true,
  subtree: true,
});

keepNativeFrame();
// Real time, to report how many real frames the page waited for and how long
// (./timing).
const realNow = performance.now.bind(performance);
const nativeFrames = { count: 0, time: 0, reasons: {} as Record<string, number> };
// Why the page is waiting for a real frame, for the count by reason.
let frameReason = "load";
{
  const request = window.commaNativeFrame!;
  window.commaNativeFrame = (callback) => {
    const start = realNow();
    return request((time) => {
      nativeFrames.count += 1;
      nativeFrames.time += realNow() - start;
      nativeFrames.reasons[frameReason] = (nativeFrames.reasons[frameReason] ?? 0) + 1;
      callback(time);
    });
  };
}
trackPageMessages();
countLayoutWatchers();

// The dynamic imports in flight (vitest.config.ts, trackDynamicImports): the
// page has loaded what it asked for once none is.
let importsInFlight = 0;
const importsSettled: (() => void)[] = [];
(globalThis as { commaTrackImport?: unknown }).commaTrackImport = <T>(
  loading: Promise<T>
) => {
  importsInFlight += 1;
  const done = () => {
    importsInFlight -= 1;
    if (importsInFlight === 0)
      for (const resolve of importsSettled.splice(0)) resolve();
  };
  loading.then(done, done);
  return loading;
};

// The page's own record of the requests it made, in the order it made them:
// kept before the fake timers replace `performance`, and long enough to keep
// every one.
const resourceEntries = performance.getEntriesByType.bind(performance, "resource");
// Real time the fixture's module took to load and its first render to settle.
const mountTimes = { load: 0, render: 0 };
const nativeFrame = () => new Promise((resolve) => window.commaNativeFrame!(resolve));
performance.setResourceTimingBufferSize(1_000_000);

(scope as { setImmediate?: unknown }).setImmediate = yieldTask;
const timers = withGlobal(window);
delete (scope as { setImmediate?: unknown }).setImmediate;
const clock = timers.install({
  now: testEpoch,
  toFake: [
    "setTimeout",
    "clearTimeout",
    "setInterval",
    "clearInterval",
    "Date",
    "performance",
    "requestAnimationFrame",
    "cancelAnimationFrame",
  ],
});
// Random numbers from the test's seed (./random), before any page module
// loads: libraries draw on them at load (react-aria's id prefix outside
// NODE_ENV "test").
const randomSeed = (window as { commaRandomSeed?: number }).commaRandomSeed ?? 0;
const randomSeeded = installSeededRandom(window, randomSeed);
seedNestedFrames(document, randomSeed);
holdWorkers(window, randomSeed);
holdRequests(window);
keepDownloads(window);
keepPopups(window);
// Set after the fake timers are made: they reach for Node's `util` when the
// window has a `process`. Fixture modules load later and see it.
scope.process ??= { env: {} };
scope.process.env.VIRT_ON = "1";
runFramesOnTestClock();
markAttached(true);
installAnimationHold(() => clock.now - testEpoch);

const frames = window.commaVirtualTime!;
const frameWork = new Set<(elapsed: number) => void>();
let elapsed = 0;
let animationsFinished = false;
window.commaAnimationFrame = () => {
  animationsFinished = driveAnimations(virtualFrameMs) || animationsFinished;
};

// Work posted on the page's message channels (React's scheduler) has run.
function messagesIdle() {
  const messages = window.commaPendingMessages;
  return !messages || messages.count === 0
    ? Promise.resolve()
    : new Promise<void>((resolve) => messages.idle.push(resolve));
}

// Each animation's play state, phase and iteration: a change in them is what
// the browser renders a frame for (a start time, an event).
function animationPhases() {
  const phases = new Map<Animation, string>();
  for (const animation of document.getAnimations()) {
    const timing = animation.effect?.getComputedTiming();
    const phase = timing?.progress === null ? "out" : "in";
    phases.set(
      animation,
      `${animation.playState}:${animation.pending}:${phase}:${timing?.currentIteration}`
    );
  }
  return phases;
}

function changedPhases(before: Map<Animation, string>, after: Map<Animation, string>) {
  if (before.size !== after.size) return true;
  for (const [animation, phase] of after)
    if (before.get(animation) !== phase) return true;
  return false;
}

// Page time jumps: a step runs its timers, frame callbacks and animation times
// a frame at a time in memory (./animation-hold), then Chromium renders one
// real frame at its end if its rendering step has something to deliver
// (option A, docs/testing.md): after trusted input; when an animation
// appeared, finished or changed phase (its events fire on a frame); and when
// the page changed or scrolled while a ResizeObserver, IntersectionObserver or
// scroll listener watches it. A test that needs a real frame every 16 ms (a
// ResizeObserver following an element as it grows) asks for `eachFrame`.
// A bound only for a failure: a hover that never matches the pointer.
const hoverFrameLimit = 30;
let phases = animationPhases();
const settle = async (forceFrame: false | "input" | "finished") => {
  const scrolled = scrolledSinceLastCheck();
  let rendered = false;
  if (forceFrame || changedPhases(phases, animationPhases())) {
    frameReason = forceFrame || "animation";
    await frames.render(true);
    rendered = true;
  } else if (watchesLayout() && (scrolled || frames.dirty)) {
    frameReason = "layout";
    await frames.render(true);
    rendered = true;
  }
  // Resize observer callbacks and scroll events run in the frame's rendering
  // step, which computes intersections after the frame callbacks that ended
  // `render`. A task posted now runs after that step: the intersection
  // entries it computed are delivered then, at this fixed point
  // (./layout-watch), without waiting for another frame.
  if (rendered) {
    await new Promise<void>((resolve) => yieldTask(resolve));
    deliverIntersections();
  }
  await messagesIdle();
  // With the pointer over the page, the browser's hover catches up with what
  // moved under it (./hover) before the next step: real frames, each after a
  // layout outside the page, until it has.
  for (let frame = 0; !hoverState().settled; frame += 1) {
    if (frame === hoverFrameLimit) {
      const { actual, at, expected } = hoverState();
      throw new Error(
        `Hover did not settle in ${hoverFrameLimit} frames: the pointer at ${at} is over ${expected.join(" < ")}; :hover matches ${actual.join(", ") || "nothing"}`
      );
    }
    nudgeLayout();
    frameReason = "hover";
    await nativeFrame();
    await messagesIdle();
  }
  scrolledSinceLastCheck();
  phases = animationPhases();
};

// What the page's workers answered and its requests received reaches it at
// this point, before page time moves; time waits for an answer or a response
// still on its way (./workers, ./requests).
const workersAnswered = async () => {
  await workersIdle();
  await requestsIdle();
  deliverWorkerMessages();
  deliverResponses();
  await messagesIdle();
};

const advance = async (ms: number, options: AdvanceOptions = {}) => {
  // What the test did before this step (input, an animation it played or
  // finished) shows first.
  await settle(options.afterInput ? "input" : false);
  for (let remaining = ms; remaining > 0; remaining -= virtualFrameMs) {
    await workersAnswered();
    const step = Math.min(virtualFrameMs, remaining);
    await clock.tickAsync(step);
    elapsed += step;
    const finished = animationsFinished;
    animationsFinished = false;
    for (const work of frameWork) work(elapsed);
    await messagesIdle();
    if (options.eachFrame || finished) await settle(finished && "finished");
  }
  await settle(false);
};

const pageClock = {
  elapsed: () => elapsed,
  eachFrame(work: (time: number) => void) {
    frameWork.add(work);
    return () => frameWork.delete(work);
  },
};

window.commaPage = {
  advance,
  elapsed: () => elapsed,
  async mount(moduleUrl, search, body) {
    // The fixture's HTML is in the page before its module brings the styles:
    // a first page load does not animate from unstyled to styled, so no
    // transition runs until the module and its stylesheets have loaded.
    const loading = document.createElement("style");
    loading.textContent =
      "*, *::before, *::after { transition-duration: 0s !important; transition-delay: 0s !important; }";
    document.head.append(loading);
    document.body.innerHTML = body;
    (globalThis as { commaFixtureSearch?: string }).commaFixtureSearch = search;
    const name = /fixtures\/([^/]+)\/src\/main\.tsx?$/.exec(
      new URL(moduleUrl).pathname
    )?.[1];
    const load = Object.entries(fixtures).find(([path]) =>
      path.startsWith(`../fixtures/${name}/`)
    )?.[1];
    if (!load) throw new Error(`No fixture at ${moduleUrl}`);
    const loadStart = realNow();
    await load();
    mountTimes.load += realNow() - loadStart;
    const renderStart = realNow();
    document.documentElement.getBoundingClientRect();
    loading.remove();
    document.documentElement.getBoundingClientRect();
    // A page load resolves after the first render commits and its effects run.
    await messagesIdle();
    await advance(3 * virtualFrameMs);
    mountTimes.render += realNow() - renderStart;
  },
  fakeMedia(sources) {
    installFakeMedia(sources, pageClock);
  },
  frameState,
  setPointer,
  randomSeeded,
  importsLoaded: () =>
    importsInFlight === 0
      ? Promise.resolve()
      : new Promise<void>((resolve) => importsSettled.push(resolve)),
  downloads: downloadsOfPage,
  popups: popupsOfPage,
  resources: () =>
    (resourceEntries() as PerformanceResourceTiming[])
      // Media elements play from fakes; their own loads are aborted.
      .filter(
        (entry) =>
          !/^(data|blob):/.test(entry.name) &&
          !["audio", "video"].includes(entry.initiatorType)
      )
      .map((entry) => `${entry.initiatorType} ${entry.name}`),
  nativeFrames: () => nativeFrames,
  mountTimes: () => mountTimes,
  release() {
    delete window.commaAnimationFrame;
    releaseAnimations();
    clock.uninstall();
  },
};

// The app's fonts are loaded before the page reports ready: a fixture's first
// render measures text in them, before its stylesheet (packages/ui/src/styles.css,
// whose faces these are) has arrived.
for (const [url, style] of [
  [interUrl, "normal"],
  [interItalicUrl, "italic"],
] as const) {
  const face = new FontFace("Inter Variable", `url("${url}") format("woff2")`, {
    display: "block",
    style,
    weight: "100 900",
  });
  document.fonts.add(face);
  await face.load();
}
// The page learns its frame's size by a resize event, at its next rendering
// after the size reaches it: reading the size has it reach now, and a frame
// later the event is behind it, not in the middle of the test.
void window.innerWidth;
await new Promise((resolve) => window.commaNativeFrame!(resolve));
(parent as Window & { commaPageOpened?: (page: TestPage) => void }).commaPageOpened?.(
  window.commaPage
);
