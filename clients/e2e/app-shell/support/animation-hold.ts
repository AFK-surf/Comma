// CSS transitions, CSS animations and Web Animations on the test clock without
// real frames. Each animation the page plays is held: paused in Chromium, its
// time set from page time after each test-clock frame. Its style is then what
// the browser would show at that time, read at once, however far a step jumps
// (./virtual-time). The page still sees it running: `playState`, `startTime`,
// `currentTime`, `pause()`, `play()` and the rest mean what they mean in a
// browser. When it reaches its end it finishes natively; its `finish` and
// `transitionend`/`animationend` events fire on the next real frame.

type Held = { start: number; rate: number };

const held = new Map<Animation, Held>();
let now = () => 0;
// The start time the page reads (the timeline shim's, in page time), so an
// animation keeps its start when the clock takes it over.
let pageStartTime: ((animation: Animation) => CSSNumberish | null) | undefined;
let setPageStartTime: ((animation: Animation, value: number) => void) | undefined;

declare global {
  interface Window {
    commaHeldAnimations?: Map<Animation, unknown>;
  }
}

const native = {
  currentTime: Object.getOwnPropertyDescriptor(Animation.prototype, "currentTime")!,
  startTime: Object.getOwnPropertyDescriptor(Animation.prototype, "startTime")!,
  playState: Object.getOwnPropertyDescriptor(Animation.prototype, "playState")!.get!,
  pending: Object.getOwnPropertyDescriptor(Animation.prototype, "pending")!.get!,
  playbackRate: Object.getOwnPropertyDescriptor(Animation.prototype, "playbackRate")!,
  pause: Animation.prototype.pause,
};

const nativeTime = (animation: Animation) => native.currentTime.get!.call(animation);
const setNativeTime = (animation: Animation, time: number) =>
  native.currentTime.set!.call(animation, time);

// A CSS animation its style pauses (`animation-play-state: paused`) holds its
// time while the style says so.
function pausedByStyle(animation: Animation) {
  if (!(animation instanceof CSSAnimation)) return false;
  const target = (animation.effect as KeyframeEffect | null)?.target;
  if (!target) return false;
  const style = getComputedStyle(
    target,
    (animation.effect as KeyframeEffect).pseudoElement
  );
  const names = style.animationName.split(", ");
  const states = style.animationPlayState.split(", ");
  const index = names.indexOf(animation.animationName);
  return index >= 0 && states[index % states.length] === "paused";
}

const timeOf = (state: Held) => (now() - state.start) * state.rate;

/**
 * Holds the animations the page started since the last call and sets every
 * held animation's time to page time: after each test-clock frame. True if an
 * animation finished (its events need a real frame).
 */
export function driveAnimations(frameMs: number) {
  let finished = false;
  for (const animation of document.getAnimations()) {
    if (held.has(animation) || animation.timeline !== document.timeline) continue;
    const playState = native.playState.call(animation);
    if (playState !== "running" && !native.pending.call(animation)) continue;
    if (playState === "paused") continue;
    const rate = Number(native.playbackRate.get!.call(animation));
    const current = Number(nativeTime(animation) ?? 0);
    // Chromium gives an animation that was pending when its timeline stopped
    // a time far from its start (see e2e/helpers/virtual-time.ts). It starts now.
    const time = current < 0 || Math.abs(current) > 86_400_000 ? 0 : current;
    const reported = pageStartTime?.(animation);
    // A start the page set keeps; one still pending starts on this frame.
    const start =
      reported === null || reported === undefined
        ? now() - (rate === 0 ? 0 : time / rate)
        : Number(reported);
    native.pause.call(animation);
    const hold = { start, rate };
    held.set(animation, hold);
    setNativeTime(animation, Math.round(timeOf(hold) * 1000) / 1000);
  }
  for (const [animation, state] of held) {
    if (native.playState.call(animation) === "idle") {
      held.delete(animation);
      continue;
    }
    if (pausedByStyle(animation)) state.start += frameMs;
    const time = Math.round(timeOf(state) * 1000) / 1000;
    const end = animation.effect?.getComputedTiming().endTime;
    const ended =
      state.rate > 0
        ? typeof end === "number" && Number.isFinite(end) && time >= end
        : state.rate < 0 && time <= 0;
    if (!ended) {
      setNativeTime(animation, time);
      continue;
    }
    // It runs out as in a browser: playing from its own start, past its end,
    // it finishes with that start kept.
    held.delete(animation);
    if (setPageStartTime) setPageStartTime(animation, state.start);
    else animation.finish();
    finished = true;
  }
  return finished;
}

/** Releases every held animation: the test ended. */
export function releaseAnimations() {
  for (const animation of held.keys()) {
    try {
      animation.play();
    } catch {
      // A canceled animation has nothing to play.
    }
  }
  held.clear();
}

/**
 * Patches `Animation` so a held animation reads as running and the page's
 * calls act on its page time. `pageTime` is the test clock's page time in ms.
 */
export function installAnimationHold(pageTime: () => number) {
  now = pageTime;
  window.commaHeldAnimations = held;
  if (
    Object.getOwnPropertyDescriptor(Animation.prototype, "playState")?.get?.name ===
    "heldPlayState"
  )
    return;
  const proto = Animation.prototype;
  const wrap = <K extends "pause" | "play" | "cancel" | "finish" | "reverse">(
    method: K,
    before: (animation: Animation, state: Held) => boolean | void
  ) => {
    const call = proto[method] as (this: Animation) => void;
    Object.defineProperty(proto, method, {
      configurable: true,
      writable: true,
      value(this: Animation) {
        const state = held.get(this);
        if (state && before(this, state) === true) return;
        return call.call(this);
      },
    });
  };
  // A held animation already plays; the page pausing, canceling, finishing or
  // reversing it takes it back from the clock.
  wrap("play", () => true);
  wrap("pause", (animation) => {
    held.delete(animation);
  });
  wrap("cancel", (animation) => {
    held.delete(animation);
  });
  wrap("finish", (animation) => {
    held.delete(animation);
  });
  wrap("reverse", (animation) => {
    held.delete(animation);
  });
  const currentTime = Object.getOwnPropertyDescriptor(proto, "currentTime")!;
  Object.defineProperty(proto, "currentTime", {
    configurable: true,
    get(this: Animation) {
      return currentTime.get!.call(this);
    },
    set(this: Animation, value: CSSNumberish | null) {
      const state = held.get(this);
      if (state && value !== null && state.rate !== 0)
        state.start = now() - Number(value) / state.rate;
      currentTime.set!.call(this, value);
    },
  });
  const startTime = Object.getOwnPropertyDescriptor(proto, "startTime")!;
  pageStartTime = (animation) => startTime.get!.call(animation);
  setPageStartTime = (animation, value) => startTime.set!.call(animation, value);
  Object.defineProperty(proto, "startTime", {
    configurable: true,
    get(this: Animation) {
      const state = held.get(this);
      return state ? state.start : startTime.get!.call(this);
    },
    set(this: Animation, value: CSSNumberish | null) {
      if (value === null) {
        held.delete(this);
        startTime.set!.call(this, value);
        return;
      }
      // A start the page sets plays the animation from it: the clock holds it
      // from now on, at exactly that start.
      let state = held.get(this);
      if (!state) {
        if (this.timeline !== document.timeline) {
          startTime.set!.call(this, value);
          return;
        }
        state = {
          start: Number(value),
          rate: Number(native.playbackRate.get!.call(this)),
        };
        native.pause.call(this);
        held.set(this, state);
      }
      state.start = Number(value);
      setNativeTime(this, Math.round(timeOf(state) * 1000) / 1000);
    },
  });
  const playbackRate = Object.getOwnPropertyDescriptor(proto, "playbackRate")!;
  Object.defineProperty(proto, "playbackRate", {
    configurable: true,
    get(this: Animation) {
      return playbackRate.get!.call(this);
    },
    set(this: Animation, value: number) {
      const state = held.get(this);
      if (state && value !== 0) {
        const time = timeOf(state);
        state.rate = value;
        state.start = now() - time / value;
      }
      playbackRate.set!.call(this, value);
    },
  });
  const updatePlaybackRate = proto.updatePlaybackRate;
  proto.updatePlaybackRate = function (this: Animation, value: number) {
    if (held.has(this)) {
      this.playbackRate = value;
      return;
    }
    updatePlaybackRate.call(this, value);
  };
  Object.defineProperty(proto, "playState", {
    configurable: true,
    get: function heldPlayState(this: Animation) {
      if (!held.has(this)) return native.playState.call(this);
      return pausedByStyle(this) ? "paused" : "running";
    },
  });
  Object.defineProperty(proto, "pending", {
    configurable: true,
    get(this: Animation) {
      return held.has(this) ? false : native.pending.call(this);
    },
  });
}
