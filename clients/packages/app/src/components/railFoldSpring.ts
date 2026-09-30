import { isReducedMotionEnabled, motionRailFold } from "@comma/ui";
import { useLayoutEffect, useRef, useState } from "react";

/**
 * A rail fold driven by a spring instead of a CSS transition.
 *
 * React still renders the resting value of each fold. While a fold moves, the
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

// Fixed simulation steps keep the curve identical at 60Hz and 120Hz.
const stepMs = 4;
// A frame after a long stall (hidden window, debugger) lands at rest instead
// of replaying the backlog.
const maxFrameMs = 100;
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
  position: number;
  velocity: number;
  target: number;
  span: number;
  transitionUntil?: number | undefined;
  read: () => number | undefined;
  write: (progress: number, phase: RailFoldPhase) => void;
}

const moving = new Set<Fold>();
let frame: number | undefined;
let clock: number | undefined;

const clamp = (progress: number) => Math.min(1, Math.max(0, progress));

function tick(now: number) {
  frame = undefined;
  const elapsed = clock === undefined ? 0 : now - clock;
  const stalled = elapsed > maxFrameMs;
  const steps = stalled ? 0 : Math.floor(elapsed / stepMs);
  clock = stalled || clock === undefined ? now : clock + steps * stepMs;
  const dt = stepMs / 1000;
  const { damping, stiffness } = motionRailFold;
  for (const fold of moving) {
    if (fold.transitionUntil !== undefined) {
      if (now >= fold.transitionUntil) rest(fold);
      continue;
    }
    for (let step = 0; step < steps; step += 1) {
      const acceleration =
        -stiffness * (fold.position - fold.target) - damping * fold.velocity;
      fold.velocity += acceleration * dt;
      fold.position += fold.velocity * dt;
    }
    const resting =
      stalled ||
      (Math.abs(fold.target - fold.position) * fold.span < restPx &&
        Math.abs(fold.velocity) * fold.span < restPxPerSecond);
    if (resting) rest(fold);
    else fold.write(clamp(fold.position), "spring");
  }
  if (moving.size > 0) {
    frame = requestAnimationFrame(tick);
  } else {
    clock = undefined;
  }
}

function rest(fold: Fold) {
  moving.delete(fold);
  fold.transitionUntil = undefined;
  fold.position = fold.target;
  fold.velocity = 0;
  fold.write(fold.target, "rest");
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
    position: shut ? 1 : 0,
    velocity: 0,
    target: shut ? 1 : 0,
    span: 1,
    read: () => callbacks.current.read(),
    write: (progress, phase) => callbacks.current.write(progress, phase),
  }));

  // A layout effect: the commit has already written the new resting value
  // into React's style, and the fold must take over before the next paint.
  useLayoutEffect(() => {
    const target = shut ? 1 : 0;
    if (target === fold.target) return;
    fold.target = target;
    if (fold.transitionUntil !== undefined) {
      fold.position = fold.read() ?? fold.position;
      fold.velocity = 0;
    }
    if (isReducedMotionEnabled()) {
      rest(fold);
      return;
    }
    fold.span = Math.max(1, callbacks.current.span());
    const move = callbacks.current.timing();
    moving.add(fold);
    if (move.kind === "transition") {
      fold.transitionUntil = performance.now() + move.durationMs + transitionSettleMs;
      fold.write(target, "transition");
    } else {
      fold.transitionUntil = undefined;
      fold.write(clamp(fold.position), "spring");
    }
    frame ??= requestAnimationFrame(tick);
  }, [fold, shut]);

  useLayoutEffect(
    () => () => {
      moving.delete(fold);
    },
    [fold]
  );
}
