import "@comma/test-utils/browser-commands";
import { inject } from "vitest";
import { commands } from "vitest/browser";
import type { AdvanceOptions, TestPage } from "./child";
import { recordFrame, recording } from "./record";
import { virtualFrameMs } from "../../helpers/virtual-time";

/**
 * The test clock of a browser component test. Each test runs in a page of its
 * own: an iframe made when the test starts and removed when it ends (./child),
 * so it starts from a fresh document, fresh modules and fresh storage. The
 * page's timers, `Date`, `performance.now()`, frame callbacks and animations
 * run on fake time there, and page time moves only when a test step moves it:
 * an action, an assertion or a wait in `./page`, or the test itself
 * (`testClock()`). A run therefore never depends on how fast the machine is.
 */
export type VirtualTime = {
  /**
   * Run `ms` of page time: every timer, frame callback and animation step in
   * it, in memory; one real frame at the end if the page's rendering step has
   * something to deliver. `eachFrame` renders one every 16 ms instead.
   */
  advance(ms: number, options?: AdvanceOptions): Promise<void>;
  /** Run `count` frames. */
  advanceFrames(count: number, options?: AdvanceOptions): Promise<void>;
  /** Run one frame after trusted input: Chromium renders it first. */
  afterInput(): Promise<void>;
  /**
   * A wait's step: page time moves to the next time anything is due, at most
   * `limit` ms on. In a world that is the next timer, frame with work or
   * message of any realm, however far; false when none is due in `limit` ms
   * (time does not move). A page without a world moves one frame.
   */
  advanceToNext(limit: number): Promise<boolean>;
  /** Page time the clock has run since it started, in ms. */
  elapsed(): number;
};

type Running = VirtualTime & { frame: HTMLIFrameElement; page: TestPage };

let running: Running | undefined;

declare global {
  interface Window {
    commaPageOpened?: (page: TestPage) => void;
    /** The test page's document asks for its seed and entry (vitest.config.ts, servedTestPage). */
    commaPageOpening?: (page: Window) => void;
  }
}

/** The running test's clock. */
export function testClock(): VirtualTime {
  if (!running) throw new Error("No test is running on the test clock.");
  return running;
}

/** The running test's clock, if a test runs: what `./page` steps while it waits. */
export function runningClock(): VirtualTime | undefined {
  return running;
}

/** The running test's page window: where its fixture renders and evaluates. */
export function pageWindow(): Window & typeof globalThis {
  if (!running) throw new Error("No test page is open.");
  return running.frame.contentWindow as Window & typeof globalThis;
}

/** The running test's page API (./child). */
export function testPage(): TestPage {
  if (!running) throw new Error("No test page is open.");
  return running.page;
}

// The world the running test's page is a realm of (./world): page time is the
// world's, so a step of the clock is a step of every realm.
let stepWorld: ((ms: number) => Promise<void>) | undefined;
let nextInWorld: ((limit: number) => Promise<boolean>) | undefined;

/** From now on the test clock moves by `step`: the page's world's time. */
export function setClockWorld(
  step: ((ms: number) => Promise<void>) | undefined,
  next?: (limit: number) => Promise<boolean>
) {
  stepWorld = step;
  nextInWorld = next;
}

// The seed of the pages opened from now on (./random).
let pageSeed = 0;

/** Seeds the random numbers of the pages opened from now on. */
export function setPageSeed(seed: number) {
  pageSeed = seed;
}

// Whether the pages opened from now on run on the UI runtime
// (../../ui-runtime/child) or on fake timers (./child).
let pageRuntime = true;

/** Opens the pages from now on on the UI runtime, or on fake timers. */
export function setPageRuntime(runtime: boolean) {
  pageRuntime = runtime;
}

/** Opens the test's page and its clock before the test mounts anything. */
export function startTestClock(): Promise<void> {
  return openTestPage();
}

/**
 * Opens the test's page: a new frame, or the document of `reloaded` loaded
 * again, as a reload keeps the frame's session history.
 */
async function openTestPage(reloaded?: HTMLIFrameElement): Promise<void> {
  if (running) throw new Error("The test clock is already running.");
  const frame = reloaded ?? document.createElement("iframe");
  frame.title = "test page";
  frame.style.cssText =
    "position: fixed; inset: 0; width: 100%; height: 100%; border: 0; margin: 0; background: transparent;";
  // The page is a document of the run's origin (vite/app-shell-origin.ts),
  // served as it is for every test (vitest.config.ts, servedTestPage): it asks
  // this window for its seed and entry before anything of it runs. The entry
  // loads from the run's build (vitest.config.ts, appShellPagesBuild), or
  // from the dev server, which wraps dynamic imports by Vitest's runner: the
  // page's own imports load directly.
  const head = [`window.commaRandomSeed = ${pageSeed};`];
  if (inject("appShellPages") === "dev")
    head.push(
      "window.__vitest_browser_runner__ = Object.assign(" +
        "Object.create(parent.__vitest_browser_runner__ || null), " +
        "{ wrapDynamicImport: (load) => load() });"
    );
  const entry =
    inject("appShellPages") === "dev"
      ? new URL(
          pageRuntime ? "../../ui-runtime/child.ts" : "./child.ts",
          import.meta.url
        ).pathname
      : `/__pages/${pageRuntime ? "runtime-child" : "child"}.js`;
  if (!reloaded) frame.src = "/";
  // The page calls back once it is ready (./child): a page that never loads
  // fails the test at its timeout.
  const page = await new Promise<TestPage>((resolve) => {
    window.commaPageOpening = (view) => {
      const script = view.document.createElement("script");
      script.textContent = head.join("\n");
      view.document.head.append(script);
      const module = view.document.createElement("script");
      module.type = "module";
      module.src = entry;
      view.document.head.append(module);
    };
    window.commaPageOpened = resolve;
    if (reloaded) reloaded.contentWindow!.location.reload();
    else document.body.append(frame);
  });
  delete window.commaPageOpening;
  delete window.commaPageOpened;
  // Its document timeline stands still: the page's animations move on page time.
  await commands.cdpSend("Animation.setPlaybackRate", { playbackRate: 0 });
  const advance = async (ms: number, options?: AdvanceOptions) => {
    if (stepWorld) await stepWorld(ms);
    else await page.advance(ms, options);
    if (recording()) recordFrame(String(page.elapsed()), page.frameState());
  };
  // The page's frames fall every 16 ms of its time. A step of frames ends on
  // the `count`th next one, wherever between two frames the last step ended
  // (a timer of another realm of its world): where a test's next look falls
  // is the page's, not the other realms'.
  const toFrame = (count: number) =>
    (Math.floor(page.elapsed() / virtualFrameMs) + count) * virtualFrameMs -
    page.elapsed();
  const clock: VirtualTime = {
    advance,
    advanceFrames: (count, options) => advance(toFrame(count), options),
    afterInput: () => advance(toFrame(1), { afterInput: true }),
    async advanceToNext(limit) {
      if (!nextInWorld) {
        await advance(virtualFrameMs);
        return true;
      }
      const moved = await nextInWorld(limit);
      if (moved && recording()) recordFrame(String(page.elapsed()), page.frameState());
      return moved;
    },
    elapsed: () => page.elapsed(),
  };
  // Older tests step the clock from code they evaluate in the page. The page
  // offers the clock's functions under the names they use; nothing else of
  // the test reaches it. A new test steps the clock from the test.
  Object.assign(frame.contentWindow!, {
    testClock: () => clock,
    time: clock,
    stepUntilSettled,
  });
  running = { frame, page, ...clock };
}

/** Replaces the test's page with a new one: a navigation. */
export async function reopenTestPage(): Promise<void> {
  await stopTestClock();
  await startTestClock();
}

/** Loads the test's page again in its frame, as a reload: its session history stays. */
export async function reloadTestPage(): Promise<void> {
  const current = running;
  if (!current) throw new Error("No test page is open.");
  await stopTestClock({ keepFrame: true });
  await openTestPage(current.frame);
}

/** Closes the test's page once the test ended: its state goes with it. */
// What runs as the test's page closes, while it is still there.
let closing: (() => void | Promise<void>)[] = [];

/** Runs `run` once, when the running test's page closes, before it is gone. */
export function onTestPageClose(run: () => void | Promise<void>) {
  closing.push(run);
}

export async function stopTestClock({
  keepFrame = false,
}: { keepFrame?: boolean } = {}): Promise<void> {
  const leaving = closing;
  closing = [];
  // A close step that fails fails the test; the page closes all the same,
  // so the next test opens its own.
  try {
    if (running) for (const run of leaving) await run();
  } finally {
    const current = running;
    running = undefined;
    stepWorld = undefined;
    nextInWorld = undefined;
    if (current) {
      current.page.release();
      if (!keepFrame) current.frame.remove();
      await commands.cdpSend("Animation.setPlaybackRate", { playbackRate: 1 });
    }
  }
}

export async function stepUntil(
  condition: () => unknown,
  {
    frames = 600,
    description = "the condition",
  }: { frames?: number; description?: string } = {}
): Promise<void> {
  const clock = testClock();
  // The wait's limit is page time: `frames` frames of it.
  const end = clock.elapsed() + frames * virtualFrameMs;
  for (;;) {
    if (await condition()) return;
    const left = end - clock.elapsed();
    if (left <= 0)
      throw new Error(`${description} did not hold within ${frames} frames`);
    // With nothing due, a frame: what the page waits for may come from
    // outside its world (a frame's document loading).
    if (!(await clock.advanceToNext(left))) await clock.advanceFrames(1);
  }
}
export async function stepUntilSettled<T>(
  promise: Promise<T>,
  frames = 600
): Promise<T> {
  let settled = false;
  const done = promise.finally(() => {
    settled = true;
  });
  // A rejection surfaces from `done` below, not as an unhandled one meanwhile.
  done.catch(() => undefined);
  await stepUntil(() => settled, { frames, description: "the page's wait" });
  return done;
}

/** Steps the running test's clock until every finite animation of `root` has finished. */
export function stepUntilAnimationsFinish(
  root: Document | Element = pageWindow().document,
  frames?: number
): Promise<void> {
  return stepUntil(
    () =>
      (root.nodeType === Node.DOCUMENT_NODE
        ? (root as Document).getAnimations()
        : (root as Element).getAnimations({ subtree: true })
      )
        .filter((animation) => animation.effect?.getTiming().iterations !== Infinity)
        .every((animation) => animation.playState !== "running"),
    {
      ...(frames === undefined ? {} : { frames }),
      description: "the animations to finish",
    }
  );
}

/** Runs `steps` with the running test's clock. */
export function withVirtualTime<T>(
  steps: (time: VirtualTime) => Promise<T>
): Promise<T> {
  return steps(testClock());
}
