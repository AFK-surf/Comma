import { afterEach, beforeEach, expect, vi } from "vitest";
import { page } from "vitest/browser";
import { testEpoch } from "@comma/test-utils/test-epoch";
import {
  driveAnimations,
  installAnimationHold,
  releaseAnimations,
} from "./animation-hold";
import {
  keepNativeFrame,
  markAttached,
  runFramesOnTestClock,
  trackPageMessages,
  virtualFrameMs,
} from "../../helpers/virtual-time";

// The test clock of a browser test's own frame (the component tests that
// render here, not in a page of their own, ./child): from the start of each
// test to its end, the frame's timers, `Date`, `performance.now()`, frame
// callbacks and animations (./animation-hold) run on Vitest's fake timers,
// from the same instant as every test (testEpoch).
//
// The clock moves only at fixed points:
// - each input (a click, a key, a pointer move) takes one frame;
// - `vi.waitFor` and `expect.poll`/`expect.element` check, and while the check
//   fails, run one frame and check again: up to their timeout in page time;
// - when the test waits on the clock alone (a timer, a frame callback or a
//   running animation is due, and no browser command, check or request is in
//   progress), it runs a frame at a time until that changes.
// Between frames, work posted on the frame's message channels (React's
// scheduler) finishes, and a real frame renders what changed.

// Browser commands (input, viewport), checks and requests in progress: the
// clock waits for them.
let busy = 0;
let running = false;

const during = <T>(work: () => T | PromiseLike<T>): Promise<T> => {
  busy += 1;
  return Promise.resolve()
    .then(work)
    .finally(() => {
      busy -= 1;
      wake();
    });
};

const messagesIdle = () => {
  const messages = window.commaPendingMessages;
  return !messages || messages.count === 0
    ? Promise.resolve()
    : new Promise<void>((resolve) => messages.idle.push(resolve));
};

// Read through functions: they change while a loop awaits.
const testRunning = () => running;
const waitsOnClock = () => running && busy === 0 && clockDue();

// Something only the clock brings: a timer besides the frame loop's own, a
// frame callback, a held animation.
const clockDue = () =>
  vi.getTimerCount() > 1 ||
  (window.commaVirtualTime?.requested() ?? 0) > 0 ||
  (window.commaHeldAnimations?.size ?? 0) > 0;

let animationsFinished = false;
let stepping = false;
let woken = false;
let nativeChannel: MessageChannel;

// Looks on the next real frame whether the test waits on the clock alone:
// after anything that may leave it so (a timer or frame callback requested, a
// command or check ended), not on every frame.
function wake() {
  if (woken) return;
  woken = true;
  window.commaNativeFrame!(() => nativeChannel.port2.postMessage(undefined));
}

// A frame of page time waits for Chromium's next frame (runFrame).
let frameDue = false;

// Chromium renders on its own frames too, between those of page time: the
// frame callbacks the page requested run first, as in a browser, with the
// frame time unchanged.
// Only while the page has frame callbacks requested: a frame tree that asks
// for no frame lets Chromium render no frame.
let realFrameArmed = false;
function armRealFrame() {
  if (realFrameArmed || !running) return;
  realFrameArmed = true;
  window.commaNativeFrame!(onRealFrame);
}
function onRealFrame() {
  realFrameArmed = false;
  if (!running) return;
  if (!frameDue) window.commaVirtualTime?.runRequested();
  if ((window.commaVirtualTime?.requested() ?? 0) > 0) armRealFrame();
}

/**
 * One frame of page time, in a browser's order: the frame's timers run, each
 * followed by the tasks it leads to (React's scheduler); then, in a real
 * frame's callbacks, the clock reaches the frame and runs its frame callbacks
 * and animations, and Chromium renders right after them (resize observers,
 * scroll events, paint). A frame with nothing to render runs in memory.
 */
async function runFrame() {
  // A frame still under way when its test ended moves no clock: the next
  // test's starts afresh.
  const advance = (ms: number) => {
    if (running) vi.advanceTimersByTime(ms);
  };
  await messagesIdle();
  if (running) await vi.advanceTimersByTimeAsync(virtualFrameMs - 1);
  await messagesIdle();
  const clock = window.commaVirtualTime;
  const renders =
    clock &&
    (clock.dirty ||
      clock.requested() > 0 ||
      animationsFinished ||
      (window.commaHeldAnimations?.size ?? 0) > 0);
  animationsFinished = false;
  if (renders) {
    frameDue = true;
    await new Promise<void>((resolve) =>
      window.commaNativeFrame!(() => {
        frameDue = false;
        advance(1);
        clock.dirty = false;
        resolve();
      })
    );
  } else advance(1);
  await messagesIdle();
}

async function step() {
  stepping = true;
  try {
    while (waitsOnClock()) await runFrame();
  } finally {
    stepping = false;
  }
  if (waitsOnClock()) wake();
}

/**
 * Calls `attempt` until it resolves: first once what the test did before has
 * rendered (a real frame), then after each frame, for at most `timeout` ms of
 * page time. `attempt` learns whether it is the last.
 */
async function untilHolds<T>(
  attempt: (last: boolean) => T | PromiseLike<T>,
  timeout = 1000
): Promise<T> {
  await messagesIdle();
  await window.commaVirtualTime?.render(true);
  const frames = Math.ceil(timeout / virtualFrameMs);
  for (let frame = 0; ; frame += 1) {
    try {
      return await attempt(frame === frames);
    } catch (error) {
      if (frame === frames || !running) throw error;
    }
    await runFrame();
  }
}

// `expect.poll(read)` and the chain after it (`.not`, a matcher): each
// attempt applies the chain to `expect(value)`.
function checkChain(
  run: (chain: string[], args: unknown[]) => Promise<unknown>,
  chain: string[] = []
): unknown {
  return new Proxy(function check() {}, {
    get(target, key) {
      if (key === "then") return undefined;
      if (typeof key === "symbol" || key === "__flags")
        return Reflect.get(target, key) as unknown;
      return checkChain(run, [...chain, key]);
    },
    apply(_target, _self, args) {
      return run(chain, args);
    },
  });
}

// Vitest's input commands and ours (@comma/test-utils/browser-commands).
const inputCommand =
  /^(__vitest_(click|dblClick|tripleClick|hover|clear|fill|wheel|upload|dragAndDrop|selectOptions|keyboard|type|tab)|mouse|keyboard)/;

// An input's target, while the test runs: Playwright acts once it is in the
// page, shown, and stable (the same box on two frames in a row), which takes
// page time (a menu opening, a card moving in). The clock runs a frame at a
// time until then, for at most `targetFrameLimit` frames.
const targetFrameLimit = 600;
let findElements: ((selector: string) => Element[]) | undefined;

async function targetReady(args: unknown) {
  const selector = Array.isArray(args) ? args[0] : undefined;
  if (typeof selector !== "string" || !findElements) return;
  // Where the target is shown, or undefined.
  const shownAt = () => {
    for (const element of findElements!(selector)) {
      const box = element.getBoundingClientRect();
      if (
        box.width > 0 &&
        box.height > 0 &&
        element.checkVisibility({ visibilityProperty: true })
      )
        return `${box.x},${box.y},${box.width},${box.height}`;
    }
    return undefined;
  };
  let before = shownAt();
  for (let frame = 0; frame < targetFrameLimit && testRunning(); frame += 1) {
    await runFrame();
    const now = shownAt();
    if (now !== undefined && now === before) return;
    before = now;
  }
}

// The input commands whose first argument is their target's selector.
const targetCommand =
  /^__vitest_(click|dblClick|tripleClick|hover|clear|fill|wheel|upload|dragAndDrop|selectOptions)$/;

// Outside a test (a hook between tests) no test clock runs: a wait there
// could only poll on real time. It fails, naming where it was called.
const outsideTest = (what: string): never => {
  throw new Error(
    `${what} was called outside a test, where no test clock runs (e2e/app-shell/support/tester-clock.ts)`
  );
};

type PollOptions = { timeout?: number; interval?: number; message?: string };

/** Puts each test of this frame on the test clock. */
export function installTesterClock() {
  // Made before the frame's channels are counted (trackPageMessages).
  nativeChannel = new MessageChannel();
  nativeChannel.port1.addEventListener("message", () => {
    woken = false;
    if (!running) return;
    if (!stepping && busy === 0) void step();
  });
  nativeChannel.port1.start();
  keepNativeFrame();
  trackPageMessages();

  // Styles are computed after every task that changes the frame, as in a
  // test's page (./child): which changes start a transition follows the
  // code, not whether a real frame fell between two tasks.
  new MutationObserver(() => {
    document.documentElement.getBoundingClientRect();
  }).observe(document, {
    attributes: true,
    characterData: true,
    childList: true,
    subtree: true,
  });

  type Runner = {
    commands: { triggerCommand: (...args: unknown[]) => Promise<unknown> };
  };
  // Vitest's browser runner, under Vitest's name.
  const runner = (window as unknown as Record<string, Runner>)[
    "__vitest_browser_runner__"
  ]!;
  // Vitest's own selector engine, through a locator of its own kind.
  const locator = Object.getPrototypeOf(page.getByText("")) as object;
  findElements = (selector) => {
    const found = Object.create(locator) as { elements(): Element[] };
    Object.assign(found, { _pwSelector: selector });
    return found.elements();
  };
  const trigger = runner.commands.triggerCommand.bind(runner.commands);
  runner.commands.triggerCommand = (...args) =>
    during(async () => {
      if (running && targetCommand.test(String(args[0]))) await targetReady(args[1]);
      const result = await trigger(...args);
      // Input takes a frame: Chromium renders it, then page time moves on, as
      // in a test's page (./virtual-time, afterInput).
      if (running && inputCommand.test(String(args[0]))) {
        await messagesIdle();
        await window.commaVirtualTime?.render(true);
        await runFrame();
      }
      return result;
    });
  const fetch = window.fetch;
  window.fetch = (...args) => during(() => fetch(...args));

  // Checks run on the test clock (untilHolds) while a test runs.
  vi.waitFor = ((
    callback: () => unknown,
    options?: number | { timeout?: number; interval?: number }
  ) =>
    running
      ? during(() =>
          untilHolds(
            () => callback(),
            typeof options === "number" ? options : options?.timeout
          )
        )
      : outsideTest("vi.waitFor")) as typeof vi.waitFor;
  expect.poll = ((read: (this: unknown) => unknown, options?: PollOptions) => {
    if (!running) return outsideTest("expect.poll");
    return checkChain((chain, args) =>
      during(() =>
        untilHolds(async (last) => {
          const name = chain.at(-1)!;
          // What Vitest's own poll gives its reader (expect.element reads it).
          const flags = {
            __flags: {
              negate: chain.includes("not"),
              _name: name,
              _isLastPollAttempt: last,
            },
          };
          let target = expect(await read.call(flags), options?.message) as unknown;
          for (const key of chain.slice(0, -1))
            target = (target as Record<string, unknown>)[key];
          const matcher = (target as Record<string, (...a: unknown[]) => unknown>)[
            name
          ]!;
          return matcher.apply(target, args);
        }, options?.timeout)
      )
    );
  }) as typeof expect.poll;

  beforeEach(() => {
    vi.useFakeTimers({
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
    runFramesOnTestClock();
    markAttached(true);
    // ast-grep-ignore: ts-test-clock -- the fake clock's Date: page time.
    installAnimationHold(() => Date.now() - testEpoch);
    window.commaAnimationFrame = () => {
      animationsFinished = driveAnimations(virtualFrameMs) || animationsFinished;
    };
    // What may leave the test waiting on the clock wakes it (wake); a frame
    // callback requested also asks for Chromium's frames (armRealFrame).
    const timers = window as unknown as Record<string, (...args: unknown[]) => unknown>;
    for (const name of ["setTimeout", "setInterval"]) {
      const fake = timers[name]!;
      timers[name] = (...args: unknown[]) => {
        wake();
        return fake(...args);
      };
    }
    const requestFrame = window.requestAnimationFrame;
    window.requestAnimationFrame = (callback) => {
      wake();
      armRealFrame();
      return requestFrame(callback);
    };
    running = true;
    wake();
  });
  afterEach(() => {
    running = false;
    delete window.commaAnimationFrame;
    releaseAnimations();
    window.commaVirtualTime?.stop();
    vi.useRealTimers();
  });
}
