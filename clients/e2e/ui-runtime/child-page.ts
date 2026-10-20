// The page of one browser component test, on the test UI runtime
// (packages/ui/src/runtime): an iframe of its own, loading this module first
// (../app-shell/support/virtual-time makes it and removes it when the test
// ends). `../app-shell/support/page` drives it through `window.commaPage`. A
// spec that opts out (`useFixture(..., { runtime: false })`) gets the page on
// fake timers instead, ../app-shell/support/child.ts.
//
// The host's functions are the runtime's before anything else loads
// (./child.ts), React posts its work on a message channel whose messages are
// the runtime's tasks, and one runtime owns the page from here to its end:
// page time, frames, animations, scroll events, layout observers, random
// numbers, storage and the order in which what the page loads reaches it.

import interItalicUrl from "../../packages/ui/src/fonts/InterVariable-Italic.woff2?url";
import interUrl from "../../packages/ui/src/fonts/InterVariable.woff2?url";
import { testEpoch } from "@comma/test-utils/test-epoch";
import {
  createTestUiRuntime,
  installTestUiHost,
  realHost,
  type TestUiRuntime,
} from "../../packages/ui/src/runtime/test/testing";
import type { AdvanceOptions, TestPage } from "../app-shell/support/child";
import { frameState } from "../app-shell/support/digest";
import { installFakeMedia } from "../app-shell/support/fake-media";
import { hoverState, nudgeLayout, setPointer } from "../app-shell/support/hover";
import { derivedSeed, workerSeedParameter } from "../app-shell/support/random";
import {
  downloadsOfPage,
  keepDownloads,
  keepPopups,
  popupsOfPage,
  wholly,
} from "../app-shell/support/requests";
import {
  createRealm,
  type HttpRoute,
  type RealmControl,
  type WorldCall,
  type WorldMessage,
  type WorldReply,
  worldMessage,
} from "./realm";
import { routeRequests } from "./realm-http";
import { routePlatform } from "./realm-platform";
import { exchangeLog, recordedLine } from "./scripted-peer";
import {
  frameHello,
  workerPreludeParameter,
  workerRealmParameter,
  workerRoutesParameter,
} from "./realm-names";

const scope = globalThis as {
  process?: { env: Record<string, string | undefined> };
  __name?: (fn: unknown) => unknown;
  commaTrackImport?: <T>(loading: Promise<T>) => Promise<T>;
  commaFixtureSearch?: string;
  commaRandomSeed?: number;
};
// The host's hook for a module imported on demand (testing.ts, installTestUiHost).
const uiImport = "__commaUiImport";
type UiImport = <T>(load: () => Promise<T>, key: string) => Promise<T>;
// Functions a test evaluates here keep the names its compiler gave them.
// oxlint-disable-next-line no-underscore-dangle -- the compiler's helper name.
scope.__name = (fn) => fn;
// React Aria's virtualizer skips measuring under NODE_ENV=test unless
// process.env.VIRT_ON is set. Real layout here measures as the app does.
scope.process ??= { env: {} };
scope.process.env.VIRT_ON = "1";

installTestUiHost({ layout: true });
const host = realHost();
// The fixtures this page can mount, each its own chunk.
const fixtures = import.meta.glob<unknown>("../app-shell/fixtures/*/src/main.{ts,tsx}");

const runtime: TestUiRuntime = createTestUiRuntime({
  seed: scope.commaRandomSeed ?? 0,
  start: testEpoch,
  layout: true,
  // A frame's hover is the browser's once what it scrolled has moved.
  afterScroll: () => settleHover(),
});
const uninstall = runtime.install();
keepDownloads(window);
keepPopups(window);

// The page's own requests reach the test server on real time. Each is work of
// the runtime: its response reaches the page whole, in the order the requests
// started, before page time moves on.
if (host.fetch) {
  const hostFetch = host.fetch;
  window.fetch = (input, init) =>
    // A request to a realm of the page's world is a message of the world.
    pageRequests?.fetch(input, init) ??
    runtime.load.work(
      `fetch ${input instanceof Request ? input.url : String(input)}`,
      () => hostFetch(input, init).then(wholly)
    );
}

// Styles are computed after every task that changes the page, before
// Chromium could render a frame of its own between tasks. A transition starts
// when a computed style changes, so which changes start one follows the code,
// not whether a real frame happened to fall between two tasks.
// A page that changed has a frame due: its observers and frame callbacks see
// the change on it, so a wait that moves to the next time anything is due
// does not pass over it.
new MutationObserver(() => {
  document.documentElement.getBoundingClientRect();
  runtime.invalidate();
}).observe(document, {
  attributes: true,
  characterData: true,
  childList: true,
  subtree: true,
});

// Real frames the page waited for (the browser's hover catching up) and real
// time it waited for what an input makes the browser send, to report where a
// test's real time went (../app-shell/support/timing).
const nativeFrames = { count: 0, time: 0, reasons: {} as Record<string, number> };
const waited = (reason: string, since: number, frames: number) => {
  nativeFrames.count += frames;
  nativeFrames.time += host.now() - since;
  nativeFrames.reasons[reason] = (nativeFrames.reasons[reason] ?? 0) + frames;
};
// A frame of the browser's own: its hover catches up on one, and the frame's
// size reaches the page on one. Page time does not move for it.
const nativeFrame = () =>
  new Promise<void>((resolve) =>
    // ast-grep-ignore: ts-test-timer -- the browser's own frame, waited for as an event; page time stands still.
    host.requestAnimationFrame(() => resolve())
  );
const mountTimes = { load: 0, render: 0 };

// The dynamic imports of the pages build (vitest.config.ts,
// trackDynamicImports). One the page starts is the runtime's work: its module
// reaches the code that asked before page time moves on, in the order the
// imports started. The fixture's own module is the page's load, not work of
// the page (`direct`).
let importsInFlight = 0;
const importsSettled: (() => void)[] = [];
let direct = 0;
/** Something the page asked for is loading (a module, a worker's script); returns what to call when it has. */
const loadingStarted = () => {
  importsInFlight += 1;
  return () => {
    importsInFlight -= 1;
    if (importsInFlight === 0)
      for (const resolve of importsSettled.splice(0)) resolve();
  };
};
scope.commaTrackImport = <T>(loading: Promise<T>) => {
  const done = loadingStarted();
  loading.then(done, done);
  return direct > 0
    ? loading
    : (globalThis as unknown as Record<string, UiImport>)[uiImport]!(
        () => loading,
        "module"
      );
};

// The page's own record of the requests it made, in the order it made them.
const resourceEntries = performance.getEntriesByType.bind(performance, "resource");
performance.setResourceTimingBufferSize(1_000_000);

// A wait that never ends holds the test until the job's limit: by then the
// log says what the page waited for.
const reportWaitAfterMs = 10_000;
async function named<T>(what: string, wait: Promise<T>): Promise<T> {
  // ast-grep-ignore: ts-test-timer -- only reports a wait that has not ended; nothing the test sees depends on it.
  const report = host.setTimeout(
    () =>
      // The test runner prints its own frame's console.
      (parent as Window & typeof globalThis).console.error(
        `[ui-runtime page] still waiting for ${what}; work the page started and has not received: ${runtime.pendingWork().join(", ") || "none"}`
      ),
    reportWaitAfterMs
  );
  try {
    return await wait;
  } finally {
    host.clearTimeout(report);
  }
}

// --- input ---------------------------------------------------------------

/** Where the test's pointer is, in this page's coordinates; null outside it. */
let pointer: { x: number; y: number } | null = null;
/** The mouse buttons the test holds down over the page. */
let buttonsDown = 0;

const inside = (x: number, y: number) =>
  x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight;

// The page's window and those of the same-origin frames in it: input over a
// nested frame reaches that frame's document, not the page's.
function pageWindows(view: Window = window): Window[] {
  const views = [view];
  for (const frame of view.document.querySelectorAll("iframe")) {
    try {
      if (frame.contentWindow?.document)
        views.push(...pageWindows(frame.contentWindow));
    } catch {
      // Another origin's frame: its events are its own.
    }
  }
  return views;
}

/** Resolves on the next `type` the page, or a frame in it, receives. */
// Input that reached a frame of another origin (./frame-realm.ts): the frame
// says so, by type.
const frameInputs = new Map<string, Set<() => void>>();
// The page's frames that are realms of its world (enterFrames).
const realmFrames = new WeakSet<Window>();
const isRealmFrame = (frame: HTMLIFrameElement) =>
  Boolean(frame.contentWindow && realmFrames.has(frame.contentWindow));
const received = (type: string) =>
  new Promise<void>((resolve) => {
    const views = pageWindows();
    const done = () => {
      for (const view of views) view.removeEventListener(type, done, true);
      frameInputs.get(type)?.delete(done);
      resolve();
    };
    for (const view of views) view.addEventListener(type, done, true);
    const waiting = frameInputs.get(type) ?? new Set();
    waiting.add(done);
    frameInputs.set(type, waiting);
  });

/** Resolves on the next `type` at `target`. */
const receivedAt = (type: string, target: EventTarget) =>
  new Promise<void>((resolve) =>
    target.addEventListener(type, () => resolve(), { capture: true, once: true })
  );

const media: Record<string, [string, (value: unknown) => boolean]> = {
  reducedMotion: ["(prefers-reduced-motion: reduce)", (value) => value === "reduce"],
  colorScheme: ["(prefers-color-scheme: dark)", (value) => value === "dark"],
  forcedColors: ["(forced-colors: active)", (value) => value === "active"],
};

/** Whether `element` scrolls along `axis` and has room to move by `delta`. */
function scrolls(element: Element, axis: "x" | "y", delta: number) {
  if (delta === 0) return false;
  const style = getComputedStyle(element);
  const overflow = axis === "x" ? style.overflowX : style.overflowY;
  if (element !== document.scrollingElement && !/(auto|scroll)/.test(overflow))
    return false;
  const position = axis === "x" ? element.scrollLeft : element.scrollTop;
  const range =
    axis === "x"
      ? element.scrollWidth - element.clientWidth
      : element.scrollHeight - element.clientHeight;
  return delta < 0 ? position > 0 : position < range;
}

/**
 * A wheel the page does not handle itself scrolls the nearest scroll
 * container under the pointer that can move that way, at once (smooth
 * scrolling is off). Waits for the browser's scroll of it.
 */
function expectedWheel(
  at: { x: number; y: number },
  [deltaX, deltaY]: [number, number]
): () => Promise<void> {
  const over = document.elementFromPoint(at.x, at.y);
  // Over a frame of another origin the wheel is the frame's: it says it
  // arrived, and a frame of the test build lets the browser chain it on.
  const wheel =
    over instanceof HTMLIFrameElement && isRealmFrame(over)
      ? received("wheel").then(() => false)
      : new Promise<boolean>((resolve) =>
          window.addEventListener("wheel", (event) => resolve(event.defaultPrevented), {
            once: true,
          })
        );
  let scroller: Element | null = over;
  while (scroller && !scrolls(scroller, "y", deltaY) && !scrolls(scroller, "x", deltaX))
    scroller =
      scroller.parentElement ??
      (scroller === document.documentElement ? null : document.scrollingElement);
  if (!scroller) return async () => void (await wheel);
  const target = scroller;
  const scrolled = runtime.whenBrowserSends(
    "scroll",
    target === document.scrollingElement ? document : target
  );
  return async () => {
    // The page scrolls itself, on page time.
    if (await wheel) return;
    await scrolled;
  };
}

type Expected = { what: string; wait: () => Promise<void> };

/**
 * What the page must receive for an input, each a wait made before the input
 * is sent; nothing when the input changes nothing (the pointer already there,
 * the media value already set). The test waits for exactly that, never for a
 * number of frames.
 */
function expectedInput(name: string, args: unknown[]): Expected[] {
  const waits: Expected[] = [];
  const expect = (what: string, event: Promise<void>) =>
    waits.push({ what, wait: () => event });
  switch (name) {
    // A pointer event, not its mouse event: a page that prevents the default
    // of a pointerdown gets no mouse events for that press.
    case "mouseMove": {
      const [x, y] = args as [number, number];
      const moved = !pointer || pointer.x !== x || pointer.y !== y;
      if (buttonsDown > 0) {
        // A press holds the pointer: its moves reach the page wherever it is.
        if (moved) expect("pointermove", received("pointermove"));
        pointer = { x, y };
      } else if (inside(x, y)) {
        if (moved) expect("pointermove", received("pointermove"));
        pointer = { x, y };
      } else {
        if (pointer) expect("pointerout", received("pointerout"));
        pointer = null;
      }
      break;
    }
    case "mouseDown":
      if (!pointer) break;
      buttonsDown += 1;
      // A second button of a press is a move of the pointer's buttons.
      expect(
        "pointerdown",
        received(buttonsDown === 1 ? "pointerdown" : "pointermove")
      );
      break;
    case "mouseUp":
      if (!pointer || buttonsDown === 0) break;
      buttonsDown -= 1;
      expect("pointerup", received(buttonsDown === 0 ? "pointerup" : "pointermove"));
      // Released outside the page, the pointer is no longer over it.
      if (buttonsDown === 0 && !inside(pointer.x, pointer.y)) pointer = null;
      break;
    case "mouseWheel":
      if (pointer)
        waits.push({
          what: "the wheel and its scroll",
          wait: expectedWheel(pointer, args as [number, number]),
        });
      break;
    case "keyboardPress":
    case "keyboardUp":
      if (document.hasFocus()) expect("keyup", received("keyup"));
      break;
    case "keyboardDown":
      if (document.hasFocus()) expect("keydown", received("keydown"));
      break;
    case "keyboardType":
      if (document.hasFocus())
        for (let index = 0; index < String(args[0]).length; index += 1)
          expect("keyup", received("keyup"));
      break;
    case "keyboardInsertText":
      if (document.hasFocus() && args[0]) expect("input", received("input"));
      break;
    case "emulateMedia":
      for (const [option, [query, matches]] of Object.entries(media)) {
        const value = (args[0] as Record<string, unknown>)[option];
        if (value === undefined) continue;
        const list = matchMedia(query);
        if (list.matches !== matches(value))
          expect(`a change of ${query}`, receivedAt("change", list));
      }
      break;
    case "viewport": {
      const [width, height] = args as [number, number];
      if (width !== window.innerWidth || height !== window.innerHeight)
        expect("resize", received("resize"));
      break;
    }
    default:
      // A CDP call of the test: a setting, no input.
      break;
  }
  return waits;
}

// --- page time -----------------------------------------------------------

// A bound only for a failure: a hover that never matches the pointer.
const hoverFrameLimit = 30;

/**
 * With the pointer over the page, the browser's hover catches up with what
 * moved under it (../app-shell/support/hover) before the next step: real
 * frames, each after a layout outside the page, until it has. The browser
 * sends the hover events itself, on its own time; with hover settled at every
 * step's start and end, what the test reads after a step has them.
 */
async function settleHover() {
  if (hoverState().settled) return;
  const start = host.now();
  let frames = 0;
  for (; !hoverState().settled; frames += 1) {
    if (frames === hoverFrameLimit) {
      const { actual, at, expected } = hoverState();
      throw new Error(
        `Hover did not settle in ${hoverFrameLimit} frames: the pointer at ${at} is over ${expected.join(" < ")}; :hover matches ${actual.join(", ") || "nothing"}`
      );
    }
    nudgeLayout();
    await nativeFrame();
  }
  waited("hover", start, frames);
  runtime.invalidate();
}

const frameMs = 16;

// One step of the page at a time: a step the test starts while another runs
// (code it evaluates in the page steps the clock itself) runs after it.
let steps: Promise<unknown> = Promise.resolve();
function serial<T>(step: () => Promise<T>): Promise<T> {
  const next = steps.then(step);
  steps = next.catch(() => undefined);
  return next;
}

// The fake media of a page (../app-shell/support/fake-media) play on page
// time: their work runs among each frame's callbacks, while there is any.
const frameWork = new Set<(elapsed: number) => void>();
let frameWorkArmed = false;
const runFrameWork = () => {
  frameWorkArmed = false;
  for (const work of frameWork) work(runtime.elapsed());
  armFrameWork();
};
function armFrameWork() {
  if (frameWorkArmed || frameWork.size === 0) return;
  frameWorkArmed = true;
  runtime.clock.frame(runFrameWork);
}
const mediaClock = {
  elapsed: () => runtime.elapsed(),
  eachFrame(work: (elapsed: number) => void) {
    frameWork.add(work);
    armFrameWork();
    return () => frameWork.delete(work);
  },
};

const advance = (ms: number, _options: AdvanceOptions = {}) =>
  serial(() => named(`page time to move ${ms} ms`, advanceBy(ms)));

const advanceBy = async (ms: number) => {
  // What the test did before this step (input, a scroll, a style it set)
  // shows first.
  await settleHover();
  await runtime.render();
  // Every frame in the step runs, as the browser project's page runs them: a
  // scroll or a style the test set shows on the next frame.
  for (const end = runtime.elapsed() + ms; runtime.elapsed() < end; ) {
    const now = runtime.elapsed();
    const next = (Math.floor(now / frameMs) + 1) * frameMs;
    if (next > end) {
      await runtime.advance(end - now);
      break;
    }
    await runtime.advanceFrames(1);
    // A frame that fell on this instant ran first, without moving time.
    if (runtime.elapsed() === now) await runtime.advanceFrames(1);
  }
  // What the step left (an animation that ended, a size that changed) shows
  // before the test reads the page.
  await settleHover();
  await runtime.render();
};

// --- the page as a realm of a world ----------------------------------------

type PageWorld = NonNullable<ReturnType<NonNullable<TestPage["world"]>>>;
let pageWorld: PageWorld | undefined;
let pageRequests: ReturnType<typeof routeRequests> | undefined;
// What the page did that its world does not carry.
const outsideWorld: string[] = [];

/**
 * The page and the workers it starts from now on become realms
 * (./realm.ts): each worker runs on a runtime of its own (./worker-realm.ts),
 * and the world reaches it on the worker's port.
 */
function enterWorld(options: { replay?: boolean } = {}): PageWorld {
  if (pageWorld) return pageWorld;
  // What the page and its first worker exchange and where the page rests:
  // the same notes whether a worker runs or a record is played.
  const log = exchangeLog(() => runtime.elapsed());
  let line: ReturnType<typeof recordedLine> | undefined;
  // The page's time moves as in a test without a world: frame by frame.
  // A step in which the page did something (a timer, an observer's
  // notification, an animation's event, a scroll) may leave it something to
  // show on the next frame that no timer and no running animation announces:
  // the next frame is due after it. Only after a step that did nothing is the
  // page's next work its next timer.
  const ran = runtime.trace();
  let seen = ran.length;
  const due = () => {
    const busy = ran.slice(seen).some((step) => !/^\S+ (render|frame)\b/.test(step));
    seen = ran.length;
    const timer = runtime.nextDue();
    if (!busy) return timer;
    const frame = (Math.floor(runtime.elapsed() / frameMs) + 1) * frameMs;
    return timer === null ? frame : Math.min(timer, frame);
  };
  // More than a frame of the world's time is a wait: the page runs what is
  // due in it, and no frame that has nothing to show.
  const realm = createRealm(runtime, {
    due,
    async advance(ms) {
      if (ms <= frameMs) return advanceBy(ms);
      await settleHover();
      await runtime.render();
      await runtime.advance(ms);
      await settleHover();
      await runtime.render();
    },
    // A step can leave something due now: a timer a committed effect set
    // with no delay, or the frame of this instant when the step ended on it.
    // The page rests only when nothing is.
    async rest() {
      await runtime.render();
      for (let round = 0; ; round += 1) {
        const now = runtime.elapsed();
        const at = runtime.nextDue();
        if (at === null || at > now) return;
        if (round === 100)
          throw new Error(`The page keeps something due at ${at} ms: it cannot rest.`);
        await runtime.flush();
        if ((runtime.nextDue() ?? Infinity) <= now) await runtime.advanceFrames(1);
        if (runtime.elapsed() !== now)
          throw new Error(
            `The page's frame due at ${at} ms moved its time to ${runtime.elapsed()} ms.`
          );
        await runtime.render();
      }
    },
  });
  const workers = new Map<string, RealmControl>();
  const routes: HttpRoute[] = [];
  const routeWorker = new Map<string, (route: HttpRoute) => Promise<unknown>>();
  pageRequests = routeRequests(realm, { name: "page", hostFetch: host.fetch! });
  // A stylesheet a module brings with it (the build's preload of a lazy
  // chunk) is loading until it has loaded: the module's import follows it.
  new MutationObserver((records) => {
    for (const record of records)
      for (const node of record.addedNodes) {
        if (!(node instanceof HTMLLinkElement) || node.rel !== "stylesheet") continue;
        void runtime.load.work(
          `stylesheet ${node.href}`,
          () =>
            new Promise<void>((resolve) => {
              node.addEventListener("load", () => resolve());
              node.addEventListener("error", () => resolve());
            })
        );
      }
  }).observe(document.head, { childList: true });
  // Locks, the origin's file system and keys answer on the page's schedule too.
  routePlatform(runtime, (what) => outsideWorld.push(what));
  const HostWorker = host.Worker!;
  window.Worker = function (url: string | URL, workerOptions?: WorkerOptions) {
    // The view alone: its worker is a line to the player of a record, which
    // the world runs as it would run the worker.
    if (options.replay) {
      line = recordedLine();
      realm.route(
        "worker 1",
        line.endpoint as unknown as Parameters<typeof realm.route>[1],
        () => {},
        { ran: log.ran }
      );
      log.sends(line.endpoint);
      return line.endpoint;
    }
    const resolved = new URL(url, location.href);
    // A worker of the shipped web build runs the realm's modules first: the
    // test server puts them before its script (vitest.config.ts, servedWebApp).
    if (resolved.pathname.startsWith("/assets/"))
      resolved.searchParams.set(workerPreludeParameter, "1");
    const name = `worker ${workers.size + 1}`;
    resolved.hash = new URLSearchParams({
      [workerSeedParameter]: String(
        derivedSeed(scope.commaRandomSeed ?? 0, workers.size + 1)
      ),
      [workerRealmParameter]: name,
      // Its requests are routed before its own modules run.
      [workerRoutesParameter]: JSON.stringify(routes),
    }).toString();
    const worker = new HostWorker(resolved, workerOptions);
    const first = workers.size === 0;
    // The worker's script is loading until its realm says it is set up.
    const loaded = loadingStarted();
    let calls = 0;
    const replies = new Map<number, (reply: WorldReply) => void>();
    const post = realm.route(
      name,
      worker as unknown as Parameters<typeof realm.route>[1],
      (message) => {
        if ("ready" in message) loaded();
        if (!("reply" in message)) return;
        replies.get(message.reply)?.(message);
        replies.delete(message.reply);
      },
      {
        ran: (data) => {
          if (first) log.ran(data);
        },
      }
    );
    // What the page sends its worker, as it sends it.
    if (first) log.sends(worker);
    // A worker that failed to load or threw answers nothing: its error is
    // the answer to whatever the world asked it.
    worker.addEventListener("error", (event) => {
      const error = `${event.message || "the worker failed to load"} (${event.filename}:${event.lineno})`;
      for (const [id, reply] of replies) reply({ reply: id, error });
      replies.clear();
      loaded();
    });
    const call = (
      body:
        | { op: "settle"; now: number }
        | { op: "deliver"; from: string; id: number; detail?: unknown }
        | { op: "http"; route: HttpRoute }
    ) =>
      named(
        `${name} to ${body.op}`,
        new Promise<WorldReply>((resolve, reject) => {
          calls += 1;
          replies.set(calls, (reply) =>
            reply.error ? reject(new Error(`${name}: ${reply.error}`)) : resolve(reply)
          );
          post({ commaWorld: { call: calls, ...body } as WorldCall });
        })
      );
    workers.set(name, {
      settle: (now) => call({ op: "settle", now }).then((reply) => reply.report!),
      deliver: (from, id, detail) =>
        call({ op: "deliver", from, id, detail }).then(() => undefined),
    });
    routeWorker.set(name, (route) => call({ op: "http", route }));
    return worker;
  } as unknown as typeof Worker;
  enterFrames(realm, workers);
  pageWorld = {
    exchanged: () => log.entries,
    step: log.step,
    due: log.due,
    inject: (data) => line?.inject(data),
    page: {
      settle: (now) =>
        serial(() =>
          named(
            "the page to rest",
            realm.control.settle(now).then((report) => {
              log.rested();
              return report;
            })
          )
        ),
      deliver: (from, id, detail) =>
        named(`message ${id} from ${from}`, realm.control.deliver(from, id, detail)),
    },
    async http(route) {
      if (routes.some((known) => known.origin === route.origin)) return;
      routes.push(route);
      pageRequests!.add(route);
      for (const add of routeWorker.values()) await add(route);
    },
    workers: () => [...workers.keys()],
    worker(name) {
      const control = workers.get(name);
      if (!control) throw new Error(`The page has no ${name}.`);
      return control;
    },
  };
  return pageWorld;
}

/**
 * The page's sandboxed frames of the test build (./frame-realm.ts) as realms
 * of its world. A frame says it is one in its first message; from then on
 * what it posts the page is held until the world hands it over, and the page
 * posts it with `commaFrames.post` (an origin of its own: the page cannot
 * wrap the frame's window). A port the page sends a frame is a line of its
 * own both ways: the port that stays is routed here, the one sent there.
 */
function enterFrames(
  realm: ReturnType<typeof createRealm>,
  controls: Map<string, RealmControl>
) {
  // Which port of a channel stays when the other is sent.
  const partners = new WeakMap<MessagePort, MessagePort>();
  const HostChannel = window.MessageChannel;
  window.MessageChannel = class extends HostChannel {
    constructor() {
      super();
      partners.set(this.port1, this.port2);
      partners.set(this.port2, this.port1);
    }
  };
  type Frame = {
    name: string;
    view: Window;
    arrive(event: MessageEvent): void;
    post(message: unknown, transfer?: Transferable[]): void;
    replies: Map<number, (reply: WorldReply) => void>;
  };
  const frames = new Map<Window, Frame>();
  const redispatched = new WeakSet<Event>();
  // A frame of the test build is loading until its realm says it is set up
  // (its first message): work of the page, done before page time moves on.
  const loading = new Map<HTMLIFrameElement, () => void>();
  new MutationObserver((records) => {
    for (const record of records)
      for (const node of record.addedNodes) {
        const added =
          node instanceof HTMLIFrameElement
            ? [node]
            : node instanceof Element
              ? [...node.querySelectorAll("iframe")]
              : [];
        for (const frame of added)
          if (
            !loading.has(frame) &&
            new URL(frame.src || "about:blank", location.href).pathname.startsWith(
              "/__dynamic-ui/"
            )
          )
            void runtime.load.work(
              `frame ${frame.src}`,
              () => new Promise<void>((resolve) => loading.set(frame, resolve))
            );
      }
  }).observe(document, { childList: true, subtree: true });
  let lines = 0;
  window.addEventListener(
    "message",
    (event) => {
      if (redispatched.has(event)) return;
      const view = event.source as Window | null;
      if (!view || view === window) return;
      const world = worldMessage(event.data) as
        | (WorldMessage & { frameHello?: string; frameInput?: string })
        | undefined;
      let frame = frames.get(view);
      if (!frame && world?.frameHello === frameHello) {
        event.stopImmediatePropagation();
        frame = addFrame(view);
        for (const [element, loaded] of loading)
          if (element.contentWindow === view) {
            loading.delete(element);
            loaded();
          }
        return;
      }
      if (!frame) return;
      event.stopImmediatePropagation();
      if (world?.frameInput) {
        // Each resolves and leaves the set: iterate a copy.
        for (const done of Array.from(frameInputs.get(world.frameInput) ?? [])) done();
        return;
      }
      frame.arrive(event);
    },
    true
  );
  function addFrame(view: Window): Frame {
    const name = `frame ${frames.size + 1}`;
    let arrival: ((event: Event) => void) | undefined;
    const endpoint = {
      addEventListener(_type: string, listener: (event: Event) => void) {
        arrival = listener;
      },
      postMessage: (message: unknown, transfer?: Transferable[]) =>
        view.postMessage(message, "*", transfer ?? []),
      onmessage: null,
    };
    const replies = new Map<number, (reply: WorldReply) => void>();
    const post = realm.route(
      name,
      endpoint as unknown as Parameters<typeof realm.route>[1],
      (message) => {
        if (!("reply" in message)) return;
        replies.get(message.reply)?.(message);
        replies.delete(message.reply);
      }
    );
    // What the world hands over reaches the page's listeners as it arrived.
    endpoint.addEventListener("message", (event: Event) => {
      const arrived = event as MessageEvent;
      const copy = new MessageEvent("message", {
        data: arrived.data,
        origin: arrived.origin,
        source: arrived.source,
        ports: [...arrived.ports],
      });
      redispatched.add(copy);
      window.dispatchEvent(copy);
    });
    const frame: Frame = {
      name,
      view,
      arrive: (event) => arrival?.(event),
      post: (message, transfer = []) => {
        const portLines = transfer.flatMap((item) => {
          if (!(item instanceof MessagePort)) return [];
          const stays = partners.get(item);
          if (!stays)
            throw new Error(
              "A port sent to a frame is one of a MessageChannel of the page."
            );
          lines += 1;
          const line = `port ${lines}`;
          // A line of the world, not a port of the page's runtime: its
          // messages are the world's to count and hand over.
          stays.addEventListener = EventTarget.prototype.addEventListener.bind(stays);
          stays.postMessage = MessagePort.prototype.postMessage.bind(
            stays
          ) as typeof stays.postMessage;
          stays.start = MessagePort.prototype.start.bind(stays);
          realm.route(
            name,
            stays as unknown as Parameters<typeof realm.route>[1],
            () => {},
            {
              line,
            }
          );
          return [line];
        });
        endpoint.postMessage(
          portLines.length > 0
            ? { commaFrameLines: portLines, data: message }
            : message,
          transfer
        );
      },
      replies,
    };
    frames.set(view, frame);
    realmFrames.add(view);
    // Its name and seed come first, before anything the page posts it.
    post({
      commaWorld: {
        frame: name,
        seed: derivedSeed(scope.commaRandomSeed ?? 0, 1000 + frames.size),
      },
    } as never);
    let calls = 0;
    const call = (body: Record<string, unknown>) =>
      named(
        `${name} to ${String(body.op)}`,
        new Promise<WorldReply>((resolve, reject) => {
          calls += 1;
          replies.set(calls, (reply) =>
            reply.error ? reject(new Error(`${name}: ${reply.error}`)) : resolve(reply)
          );
          post({ commaWorld: { call: calls, ...body } } as never);
        })
      );
    const control = (target: string | undefined): RealmControl => ({
      async settle(now) {
        const reply = await call({ op: "settle", now, realm: target });
        // The workers the frame started are realms of the world from now on.
        for (const worker of (reply as { workers?: string[] }).workers ?? [])
          if (!controls.has(worker)) controls.set(worker, control(worker));
        return reply.report!;
      },
      deliver: (from, id, detail) =>
        call({ op: "deliver", from, id, detail, realm: target }).then(() => undefined),
    });
    controls.set(name, control(undefined));
    return frame;
  }
  const frameOf = (target: Window | HTMLIFrameElement | null) => {
    const view = target instanceof HTMLIFrameElement ? target.contentWindow : target;
    const frame = view && frames.get(view);
    if (!frame) throw new Error("The frame is not a realm of the page's world (yet).");
    return frame;
  };
  (window as Window & { commaFrames?: CommaFrames }).commaFrames = {
    post: (target, message, transfer) => frameOf(target).post(message, transfer),
    names: () => [...frames.values()].map((frame) => frame.name),
    nameOf: (target) => frameOf(target).name,
  };
}

/** The page's side of its frames' realms (enterFrames). */
export type CommaFrames = {
  /** Posts a frame as `target.postMessage(message, "*", transfer)` would. */
  post(
    target: Window | HTMLIFrameElement | null,
    message: unknown,
    transfer?: Transferable[]
  ): void;
  names(): string[];
  nameOf(target: Window | HTMLIFrameElement | null): string;
};

// The host routes these to the runtime's seed: a page that replaced one
// draws outside it.
const routedRandom = Math.random;
const routedUuid = crypto.randomUUID;
const routedValues = crypto.getRandomValues;
const randomRouted = () =>
  Math.random === routedRandom &&
  crypto.randomUUID === routedUuid &&
  crypto.getRandomValues === routedValues;

window.commaPage = {
  advance,
  elapsed: () => runtime.elapsed(),
  input: (name, args, send) =>
    serial(async () => {
      const expected = expectedInput(name, args);
      const result = await send();
      const start = host.now();
      for (const { what, wait } of expected)
        await named(`${what} after ${name}(${JSON.stringify(args)})`, wait());
      // What a new size sends the page besides its resize (a media query's
      // change, a layout the browser finishes) arrives on the browser's
      // next frames, before the page runs what the input started.
      if (name === "viewport" && expected.length > 0) {
        await nativeFrame();
        await nativeFrame();
        waited("viewport", start, 2);
      } else waited("input", start, 0);
      runtime.invalidate();
      await named(`what ${name} started`, runtime.flush());
      return result;
    }),
  async mount(moduleUrl, search, body, styles = []) {
    // The fixture's HTML is in the page before its module brings the styles:
    // a first page load does not animate from unstyled to styled, so no
    // transition runs until the module and its stylesheets have loaded.
    const loading = document.createElement("style");
    loading.textContent =
      "*, *::before, *::after { transition-duration: 0s !important; transition-delay: 0s !important; }";
    document.head.append(loading);
    document.body.innerHTML = body;
    scope.commaFixtureSearch = search;
    const name = /fixtures\/([^/]+)\/src\/main\.tsx?$/.exec(
      new URL(moduleUrl).pathname
    )?.[1];
    // The shipped web build's entry, after its document's stylesheets.
    const shipped = new URL(moduleUrl).pathname.startsWith("/assets/")
      ? async () => {
          await Promise.all(
            styles.map(
              (href) =>
                new Promise<void>((resolve, reject) => {
                  const link = document.createElement("link");
                  link.rel = "stylesheet";
                  link.crossOrigin = "";
                  link.href = href;
                  link.addEventListener("load", () => resolve());
                  link.addEventListener("error", () =>
                    reject(new Error(`The stylesheet ${href} did not load.`))
                  );
                  document.head.append(link);
                })
            )
          );
          // The page's load, as the fixtures' modules are: not work of the page.
          direct += 1;
          const entry = import(/* @vite-ignore */ moduleUrl);
          direct -= 1;
          await entry;
        }
      : undefined;
    const load =
      shipped ??
      Object.entries(fixtures).find(([path]) =>
        path.startsWith(`../app-shell/fixtures/${name}/`)
      )?.[1];
    if (!load) throw new Error(`No fixture at ${moduleUrl}`);
    const loadStart = host.now();
    direct += 1;
    const loaded = load();
    direct -= 1;
    await loaded;
    mountTimes.load += host.now() - loadStart;
    const renderStart = host.now();
    // A page load resolves after what the page declared has loaded, the first
    // render committed and its effects ran.
    await named(
      "the fixture's first render",
      (async () => {
        await runtime.prepare();
        runtime.invalidate();
        await runtime.flush();
        // React commits the first DOM during that flush. The styles of the
        // load stay until the browser has applied the pointer the page
        // inherited to that DOM, as on a document's first rendering.
        await settleHover();
        await runtime.render();
        loading.remove();
        document.documentElement.getBoundingClientRect();
        await runtime.render();
        await runtime.advanceFrames(3);
      })()
    );
    mountTimes.render += host.now() - renderStart;
  },
  fakeMedia(sources) {
    installFakeMedia(sources, mediaClock);
  },
  frameState,
  setPointer(at) {
    // The test's helpers say where they sent the pointer; over this page
    // that is a point inside it, or anywhere while a press holds it.
    if (buttonsDown === 0) pointer = at && inside(at.x, at.y) ? at : null;
    setPointer(pointer ?? undefined);
  },
  randomSeeded: () => randomRouted(),
  importsLoaded: () =>
    importsInFlight === 0
      ? Promise.resolve()
      : new Promise<void>((resolve) => importsSettled.push(resolve)),
  downloads: downloadsOfPage,
  popups: popupsOfPage,
  resources: () =>
    (resourceEntries() as PerformanceResourceTiming[])
      .filter(
        (entry) =>
          !/^(data|blob):/.test(entry.name) &&
          !["audio", "video"].includes(entry.initiatorType)
      )
      .map((entry) => `${entry.initiatorType} ${entry.name}`),
  nativeFrames: () => nativeFrames,
  mountTimes: () => mountTimes,
  settle: () =>
    serial(() => named("what the test started in the page", runtime.flush())),
  world: enterWorld,
  violations: () => [...runtime.violations(), ...outsideWorld],
  pendingWork: () => [...runtime.pendingWork()],
  release() {
    uninstall();
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
await nativeFrame();
(parent as Window & { commaPageOpened?: (page: TestPage) => void }).commaPageOpened?.(
  window.commaPage
);
