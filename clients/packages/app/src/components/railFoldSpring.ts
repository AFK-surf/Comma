import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import {
  createSpring,
  placeSpring,
  retargetSpring,
  springAtRest,
  springStateAt,
  type Spring,
} from "@comma/ui/motion";
import { isReducedMotionEnabled, motionRailFold } from "@comma/ui/tokens";
import { useLayoutEffect, useRef, useState } from "react";

/**
 * A rail fold driven by a spring instead of a CSS transition.
 *
 * React renders the resting value of each fold, or, for a fold a CSS transition
 * may move, leaves every value after the first to `write`. While a fold moves, the
 * spring writes its progress straight to the DOM once per frame, so no React
 * render runs during the motion. A second toggle mid-fold retargets the same
 * spring and keeps its position and velocity: the rail turns back from where
 * it is instead of restarting a timed curve.
 *
 * A move can instead be handed to the shell's CSS transition. A fold the
 * layout makes on its own runs beside another shell transition, such as the
 * Chat Sidebar opening, and only the same mechanism keeps the two in step
 * frame for frame.
 */

// The spring's state at a frame is computed from the time since it started
// (@comma/ui/motion): the curve is the same at any frame rate, and a frame
// after a long stall finds the fold where its time puts it.
// Rest thresholds in pixels of the fold's own span. The tail of a spring
// moves by fractions of a pixel; each of those frames would still cost a
// full style and layout pass.
const restPx = 0.5;
const restPxPerSecond = 30;
// A CSS transition starts at the next frame, after the commit that armed it.
// Rest waits out that frame so ending the move never cuts the curve short.
const transitionSettleMs = 50;

/** How a move plays: the reader's spring, or the shell's CSS transition. */
export type RailFoldTiming =
  | { kind: "spring" }
  | { kind: "transition"; durationMs: number };

/**
 * `spring`: write this progress now. `transition`: arm the CSS transition
 * toward `progress`. `rest`: the fold is done; hand the element back to the
 * styles React and CSS own.
 */
export type RailFoldPhase = "spring" | "transition" | "rest";

interface Fold {
  spring: Spring;
  span: number;
  transitionUntil?: number | undefined;
  read: () => number | undefined;
  write: (progress: number, phase: RailFoldPhase) => void;
}

const moving = new Set<Fold>();
let frame: CancelUiTimer | undefined;

const clamp = (progress: number) => Math.min(1, Math.max(0, progress));

function tick(now: number) {
  frame = undefined;
  for (const fold of moving) {
    if (fold.transitionUntil !== undefined) {
      if (now >= fold.transitionUntil) rest(fold, now);
      continue;
    }
    const { spring } = fold;
    const state = springStateAt(spring, now);
    if (
      springAtRest(
        state,
        spring.target,
        restPx / fold.span,
        restPxPerSecond / fold.span
      )
    )
      rest(fold, now);
    else fold.write(clamp(state.position), "spring");
  }
  if (moving.size > 0) frame = uiClock.frame(tick);
}

function rest(fold: Fold, now: number) {
  moving.delete(fold);
  fold.transitionUntil = undefined;
  placeSpring(fold.spring, now, fold.spring.target);
  fold.write(fold.spring.target, "rest");
}

/**
 * Drives one fold between open (0) and shut (1). `span` is the fold's travel
 * in pixels and `timing` picks how the move plays; both are read when a move
 * starts. `read` returns the progress a CSS transition has currently painted,
 * so a spring can take over from it mid-move.
 */
export function useRailFoldSpring(
  shut: boolean,
  {
    read = () => undefined,
    span,
    timing = () => ({ kind: "spring" }),
    write,
  }: {
    read?: () => number | undefined;
    span: () => number;
    timing?: () => RailFoldTiming;
    write: (progress: number, phase: RailFoldPhase) => void;
  }
) {
  const callbacks = useRef({ read, span, timing, write });
  callbacks.current = { read, span, timing, write };
  const [fold] = useState<Fold>(() => ({
    spring: createSpring(motionRailFold, shut ? 1 : 0, uiClock.monotonic()),
    span: 1,
    read: () => callbacks.current.read(),
    write: (progress, phase) => callbacks.current.write(progress, phase),
  }));

  // A layout effect: the fold must take over before the next paint. A caller
  // whose fold is a CSS transition leaves the value to `write`, which arms the
  // transition before it moves the value.
  useLayoutEffect(() => {
    const target = shut ? 1 : 0;
    const { spring } = fold;
    if (target === spring.target) return;
    const now = uiClock.monotonic();
    // Taking over from a CSS transition, the spring starts, still, from what
    // it painted.
    if (fold.transitionUntil !== undefined)
      placeSpring(spring, now, fold.read() ?? springStateAt(spring, now).position);
    retargetSpring(spring, now, target);
    if (isReducedMotionEnabled()) {
      rest(fold, now);
      return;
    }
    fold.span = Math.max(1, callbacks.current.span());
    const move = callbacks.current.timing();
    moving.add(fold);
    if (move.kind === "transition") {
      fold.transitionUntil = now + move.durationMs + transitionSettleMs;
      fold.write(target, "transition");
    } else {
      fold.transitionUntil = undefined;
      fold.write(clamp(springStateAt(spring, now).position), "spring");
    }
    frame ??= uiClock.frame(tick);
  }, [fold, shut]);

  useLayoutEffect(
    () => () => {
      moving.delete(fold);
    },
    [fold]
  );
}
