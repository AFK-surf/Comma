import type { BrowserContext, Frame, Page } from "@playwright/test";

/**
 * One test clock for the pages of a Chromium or Electron browser context.
 * Timers, `Date`, `performance.now()`, `requestAnimationFrame` and every CSS
 * transition, CSS animation and Web Animation of an attached page stop. They
 * move only when the test steps the clock, so a result does not depend on
 * machine speed or load.
 *
 * - Playwright's clock owns the timers, `Date`, `performance.now()` and frame
 *   callbacks. Its frames fall on multiples of 16 ms.
 * - CDP `Animation.setPlaybackRate(0)` stops the document timeline of an
 *   attached page. The browser no longer moves its CSS or Web Animations.
 * - Each test-clock frame first moves the running animations of an attached
 *   page by the frame time (times their playback rate), then runs the page's
 *   frame callbacks with the frame timestamp.
 * - A step starts with one real browser frame, and so does each following
 *   frame after the page changed (DOM, a moved animation, or an animation
 *   played, paused, seeked or ended). Animation events, scroll events,
 *   resize and intersection observers and paint then happen before page time
 *   moves on, as in a browser. Before each of these frames, work posted on
 *   the page's own message channels (React's scheduler) finishes, so a render
 *   lands in the same test-clock frame every run.
 *
 * Chromium virtual time (`Emulation.setVirtualTimePolicy`) cannot do this: it
 * stops rendering, so a new transition or animation never starts, and frame
 * callbacks do not run on its budget.
 *
 * On an attached page, `document.timeline.currentTime` and Web Animation
 * start times read and write the test-clock frame time, so a frame loop may
 * start from either clock. `performance.now()` and `Date.now()` advance
 * between frames too; motion must not read them.
 *
 * Install before the page loads: a timer or frame callback that a page
 * requested earlier stays on real time. Attach each other page whose
 * animations the test steps, for example a second Electron window. The
 * clock belongs to the browser context, so in Electron it stops the timers of
 * every window until `release`.
 */
export type VirtualTime = {
  /** Run `ms` of page time: every timer, frame and animation step in it. */
  advance(ms: number): Promise<void>;
  /** Run `count` frames. */
  advanceFrames(count: number): Promise<void>;
  /**
   * Run one frame at a time until `condition` holds in the page, for at most
   * `frames` frames. Network replies and work started before the clock do not
   * follow it. Step to the state they lead to, then assert. Returns the
   * number of frames run.
   */
  advanceUntil(
    condition: () => unknown,
    options?: { frames?: number; page?: Page }
  ): Promise<number>;
  /** Also stop and step the animations of `page`. */
  attach(page: Page): Promise<void>;
  /** Let time and animations run on real time again. */
  release(): Promise<void>;
  /** Page time since the clock started, in ms. */
  now(): Promise<number>;
};

/** The frame of Playwright's clock: frame callbacks run every 16 ms. */
export const virtualFrameMs = 16;

type PageClock = {
  /** Page time when the clock started. */
  start: number;
  /** Page time of the current frame. */
  frameTime: number;
  /** Set by `attach`: this page's animations step with the clock. */
  attached: boolean;
  /** A frame moved an animation, or the page changed, since the last render. */
  dirty: boolean;
  /** Resolves after the next real browser frame, if forced or the page is dirty. */
  render(force?: boolean): Promise<void>;
  /** Stops stepping frames; the fake clock is gone. */
  stop(): void;
  /** How many frame callbacks the page requested for the next frame. */
  requested(): number;
  /**
   * Runs the frame callbacks the page requested, with the current frame
   * time: Chromium is rendering a frame before page time reached the next.
   */
  runRequested(): void;
};

declare global {
  interface Window {
    commaVirtualTime?: PageClock;
    commaVirtualTimeShims?: boolean;
    commaPendingMessages?: { count: number; idle: (() => void)[] };
    commaNativeFrame?: typeof requestAnimationFrame;
    commaAnimationFrame?: () => void;
  }
}

export async function installVirtualTime(
  page: Page,
  { start = Date.UTC(2026, 0, 1) }: { start?: number } = {}
): Promise<VirtualTime> {
  const context = page.context();
  const loaded = () => context.pages().filter((each) => each.url() !== "about:blank");
  // Keep the real frame callback before Playwright's clock replaces it.
  await context.addInitScript(keepNativeFrame);
  await context.addInitScript(trackPageMessages);
  for (const each of loaded()) {
    await each.evaluate(keepNativeFrame);
    await each.evaluate(trackPageMessages);
  }
  await context.clock.install({ time: start });
  await stopClock(context, start);
  await context.addInitScript(runFramesOnTestClock);
  for (const each of loaded()) await each.evaluate(runFramesOnTestClock);

  const attached = new Map<Page, { detach(): Promise<void> }>();
  const render = async (force = false) => {
    for (const each of attached.keys()) {
      if (each.isClosed()) attached.delete(each);
      else
        await each.evaluate((always) => window.commaVirtualTime?.render(always), force);
    }
  };
  const run = async (ms: number) => {
    for (let remaining = ms; remaining > 0; remaining -= virtualFrameMs) {
      await context.clock.runFor(Math.min(virtualFrameMs, remaining));
      await render();
    }
  };
  // What the test did before a step renders first: a scroll, an input, a
  // render React has not committed yet.
  const advance = async (ms: number) => {
    await render(true);
    await run(ms);
  };
  const time: VirtualTime = {
    advance,
    // Any 16 ms span holds one frame.
    advanceFrames: (count) => advance(count * virtualFrameMs),
    async advanceUntil(condition, { frames = 120, page: target = page } = {}) {
      await render(true);
      for (let frame = 0; frame <= frames; frame += 1) {
        if (await target.evaluate(condition)) return frame;
        if (frame < frames) await run(virtualFrameMs);
      }
      throw new Error(`The page condition did not hold within ${frames} frames`);
    },
    async attach(target) {
      attached.set(target, await attachPage(target));
    },
    async release() {
      for (const [each, { detach }] of attached) if (!each.isClosed()) await detach();
      attached.clear();
      await context.clock.resume();
    },
    now: () =>
      page.evaluate(() => performance.now() - (window.commaVirtualTime?.start ?? 0)),
  };
  await time.attach(page);
  return time;
}

/**
 * Stops a just-installed clock. On a loaded page it already runs, so it stops
 * a moment ahead of `start`; timers due in that moment run first.
 */
async function stopClock(context: BrowserContext, start: number) {
  for (let ahead = 0; ; ahead = Math.max(100, ahead * 4)) {
    try {
      await context.clock.pauseAt(start + ahead);
      return;
    } catch (error) {
      if (!String(error).includes("to the past") || ahead > 60_000) throw error;
    }
  }
}

async function attachPage(page: Page) {
  const session = await page.context().newCDPSession(page);
  const setTimelineRate = async (playbackRate: number) => {
    await session.send("Animation.enable");
    await session.send("Animation.setPlaybackRate", { playbackRate });
  };
  await setTimelineRate(0);
  await page.addInitScript(markAttached, true);
  if (page.url() !== "about:blank") await page.evaluate(markAttached, true);
  // A new document starts its timeline at the normal rate.
  const onNavigated = (frame: Frame) => {
    if (frame === page.mainFrame()) void setTimelineRate(0).catch(() => undefined);
  };
  page.on("framenavigated", onNavigated);
  return {
    async detach() {
      page.off("framenavigated", onNavigated);
      await page.addInitScript(markAttached, false);
      await page.evaluate(markAttached, false);
      await setTimelineRate(1);
      await session.detach();
    },
  };
}

export function markAttached(attached: boolean) {
  if (window.commaVirtualTime) window.commaVirtualTime.attached = attached;
}

export function keepNativeFrame() {
  window.commaNativeFrame ??= window.requestAnimationFrame.bind(window);
}

/**
 * Runs each test-clock frame as a browser frame: first move the running
 * animations, then run the frame callbacks that the page requested, all with
 * the frame timestamp. One clock frame callback serves the whole frame.
 * Install the fake clock first.
 */
export function runFramesOnTestClock() {
  if (window.commaVirtualTime) return;
  const farTimeMs = 24 * 60 * 60 * 1000;
  const nativeFrame = window.commaNativeFrame;
  if (!nativeFrame) throw new Error("The real frame callback was not kept");
  const requestFrame = window.requestAnimationFrame.bind(window);
  let callbacks = new Map<number, FrameRequestCallback>();
  let nextId = 1;
  let stopped = false;
  const changes = new MutationObserver(() => {
    clock.dirty = true;
  });
  const clock: PageClock = {
    start: performance.now(),
    frameTime: performance.now(),
    attached: false,
    dirty: false,
    async render(force = false) {
      // Work posted on this window's message channels (React's scheduler)
      // finishes, then a real frame shows what it changed. Bounded, in case
      // the page keeps changing itself.
      const messages = window.commaPendingMessages;
      const idle = () =>
        !messages || messages.count === 0
          ? Promise.resolve()
          : new Promise<void>((resolve) => messages.idle.push(resolve));
      for (let round = 0; round < 8; round += 1) {
        await idle();
        // A font a render asked for loads on real time; its glyphs change
        // layout. Wait for it, so text measures the same on every machine.
        await document.fonts.ready;
        if (!force && !clock.dirty) return;
        force = false;
        clock.dirty = false;
        await new Promise((resolve) => nativeFrame(resolve));
      }
    },
    requested: () => callbacks.size,
    runRequested: () => runCallbacks(clock.frameTime),
    stop() {
      stopped = true;
      changes.disconnect();
      delete window.commaVirtualTime;
    },
  };
  window.commaVirtualTime = clock;
  changes.observe(document, {
    attributes: true,
    characterData: true,
    childList: true,
    subtree: true,
  });

  // An attached page's timeline stands still, so its own time is not the
  // frame time. Report the test-clock frame time instead, and convert Web
  // Animation start times between the two: a start time read or written
  // against `document.timeline.currentTime` then means what it means in a
  // browser. Patched once per window; it follows the current clock.
  if (!window.commaVirtualTimeShims) {
    window.commaVirtualTimeShims = true;

    const timelineTime = Object.getOwnPropertyDescriptor(
      AnimationTimeline.prototype,
      "currentTime"
    )!.get!;
    const startTime = Object.getOwnPropertyDescriptor(
      Animation.prototype,
      "startTime"
    )!;
    // The current clock, while it is attached and `timeline` is the page's.
    // In the page: this script cannot reach module scope.
    // oxlint-disable-next-line unicorn/consistent-function-scoping
    const attachedClock = (timeline: AnimationTimeline | null) =>
      timeline === document.timeline && window.commaVirtualTime?.attached
        ? window.commaVirtualTime
        : undefined;
    // An animation the page or the test plays, pauses, seeks or ends has
    // events and style for the next real frame.
    for (const method of [
      "cancel",
      "finish",
      "pause",
      "play",
      "reverse",
      "updatePlaybackRate",
    ] as const) {
      const call = Animation.prototype[method] as (
        this: Animation,
        ...args: unknown[]
      ) => void;
      Object.defineProperty(Animation.prototype, method, {
        configurable: true,
        writable: true,
        value(this: Animation, ...args: unknown[]) {
          if (window.commaVirtualTime) window.commaVirtualTime.dirty = true;
          return call.apply(this, args);
        },
      });
    }
    const currentTime = Object.getOwnPropertyDescriptor(
      Animation.prototype,
      "currentTime"
    )!;
    Object.defineProperty(Animation.prototype, "currentTime", {
      configurable: true,
      get(this: Animation) {
        return currentTime.get!.call(this);
      },
      set(this: Animation, value: CSSNumberish | null) {
        if (window.commaVirtualTime) window.commaVirtualTime.dirty = true;
        currentTime.set!.call(this, value);
      },
    });
    const offset = (current: PageClock) =>
      current.frameTime - Number(timelineTime.call(document.timeline));
    Object.defineProperty(AnimationTimeline.prototype, "currentTime", {
      configurable: true,
      get(this: AnimationTimeline) {
        return attachedClock(this)?.frameTime ?? timelineTime.call(this);
      },
    });
    Object.defineProperty(Animation.prototype, "startTime", {
      configurable: true,
      get(this: Animation) {
        const value = startTime.get!.call(this);
        const current = attachedClock(this.timeline);
        // The two clocks are far apart, so the sum carries float error from
        // their difference (80 can read 79.99999999999909 one frame and 80 the
        // next). Chromium keeps animation times to the microsecond: so does this.
        return value === null || !current
          ? value
          : Math.round((Number(value) + offset(current)) * 1000) / 1000;
      },
      set(this: Animation, value: CSSNumberish | null) {
        if (window.commaVirtualTime) window.commaVirtualTime.dirty = true;
        const current = attachedClock(this.timeline);
        startTime.set!.call(
          this,
          value === null || !current ? value : Number(value) - offset(current)
        );
      },
    });
  }

  const frame = (now: number) => {
    if (stopped) return;
    const elapsed = now - clock.frameTime;
    clock.frameTime = now;
    // A clock that holds the animations moves them first, as a browser updates
    // animations before it runs the frame callbacks.
    window.commaAnimationFrame?.();
    if (clock.attached && elapsed > 0) {
      for (const animation of document.getAnimations()) {
        if (
          window.commaHeldAnimations?.has(animation) ||
          animation.playState !== "running" ||
          animation.timeline !== document.timeline ||
          animation.currentTime === null
        )
          continue;
        let current = Number(animation.currentTime);
        // Chromium gives an animation that was pending when its timeline
        // stopped a start time on the system clock: ahead of the timeline by
        // the machine's uptime, which is less than a day on a runner that
        // started recently. Nothing else puts a running animation before its
        // start, where it holds its first frame. It starts now.
        if (current < 0 || Math.abs(current) > farTimeMs) current = 0;
        // To the microsecond, as Chromium keeps animation times: the frame
        // times are large, so their difference carries float error that
        // depends on how long the page has lived.
        animation.currentTime =
          Math.round((current + elapsed * animation.playbackRate) * 1000) / 1000;
        clock.dirty = true;
      }
    }
    runCallbacks(now);
    requestFrame(frame);
  };
  function runCallbacks(now: number) {
    const due = callbacks;
    callbacks = new Map();
    for (const callback of due.values()) {
      try {
        callback(now);
      } catch (error) {
        reportError(error);
      }
    }
  }
  window.requestAnimationFrame = (callback) => {
    callbacks.set(nextId, callback);
    return nextId++;
  };
  window.cancelAnimationFrame = (id) => {
    callbacks.delete(id);
  };
  requestFrame(frame);
}

/**
 * Counts the messages between the two ports of a channel made in this window
 * (React's scheduler) until their handler has run, so a test-clock step lets
 * scheduled renders finish first. Only channels made after this call count:
 * React makes its channel when its scheduler loads, so install it before the
 * page's scripts run (an init script, or a Vitest browser setup file).
 */
export function trackPageMessages() {
  if (window.commaPendingMessages) return;
  const messages = { count: 0, idle: [] as (() => void)[] };
  window.commaPendingMessages = messages;
  const partners = new WeakMap<MessagePort, MessagePort>();
  const listening = new WeakSet<MessagePort>();
  const NativeChannel = window.MessageChannel;
  window.MessageChannel = class extends NativeChannel {
    constructor() {
      super();
      partners.set(this.port1, this.port2);
      partners.set(this.port2, this.port1);
    }
  };
  const handled = () => {
    messages.count = Math.max(0, messages.count - 1);
    if (messages.count === 0) for (const resolve of messages.idle.splice(0)) resolve();
  };
  const onmessage = Object.getOwnPropertyDescriptor(
    MessagePort.prototype,
    "onmessage"
  )!;
  Object.defineProperty(MessagePort.prototype, "onmessage", {
    configurable: true,
    get(this: MessagePort) {
      return onmessage.get!.call(this);
    },
    set(this: MessagePort, handler: ((event: MessageEvent) => unknown) | null) {
      if (handler) listening.add(this);
      else listening.delete(this);
      onmessage.set!.call(
        this,
        handler &&
          function (this: MessagePort, event: MessageEvent) {
            try {
              return handler.call(this, event);
            } finally {
              handled();
            }
          }
      );
    },
  });
  const postMessage = MessagePort.prototype.postMessage;
  MessagePort.prototype.postMessage = function (this: MessagePort, ...args: unknown[]) {
    const partner = partners.get(this);
    if (partner && listening.has(partner)) messages.count += 1;
    return (postMessage as (...values: unknown[]) => void).apply(this, args);
  } as MessagePort["postMessage"];
}
