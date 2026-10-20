/**
 * Motion whose state at each frame is computed from the time since it started,
 * never accumulated frame by frame: the same moment looks the same at any frame
 * rate, and a test may step frames coarsely or jump straight to the moment it
 * checks.
 */

/** A spring: stiffness and damping per unit mass (mass 1 unless given). */
export type SpringConfig = { stiffness: number; damping: number; mass?: number };

export type SpringState = { position: number; velocity: number };

/**
 * Where a damped spring is `seconds` after it left `from` for `target`: the
 * closed-form solution of `m·x″ = −k·(x − target) − c·x′`, under-, critically
 * or over-damped.
 */
export function springAt(
  config: SpringConfig,
  from: SpringState,
  target: number,
  seconds: number
): SpringState {
  const mass = config.mass ?? 1;
  const x0 = from.position - target;
  const v0 = from.velocity;
  if (seconds <= 0) return { position: from.position, velocity: v0 };
  const omega = Math.sqrt(config.stiffness / mass);
  const zeta = config.damping / (2 * Math.sqrt(config.stiffness * mass));
  const t = seconds;
  if (Math.abs(zeta - 1) < 1e-6) {
    const decay = Math.exp(-omega * t);
    const b = v0 + omega * x0;
    return {
      position: target + (x0 + b * t) * decay,
      velocity: (b - omega * (x0 + b * t)) * decay,
    };
  }
  if (zeta < 1) {
    const damped = omega * Math.sqrt(1 - zeta * zeta);
    const decay = Math.exp(-zeta * omega * t);
    const b = (v0 + zeta * omega * x0) / damped;
    const cos = Math.cos(damped * t);
    const sin = Math.sin(damped * t);
    const x = decay * (x0 * cos + b * sin);
    return {
      position: target + x,
      velocity: -zeta * omega * x + decay * (-x0 * damped * sin + b * damped * cos),
    };
  }
  const root = omega * Math.sqrt(zeta * zeta - 1);
  const r1 = -zeta * omega + root;
  const r2 = -zeta * omega - root;
  const a = (v0 - r2 * x0) / (r1 - r2);
  const b = x0 - a;
  const e1 = Math.exp(r1 * t);
  const e2 = Math.exp(r2 * t);
  return { position: target + a * e1 + b * e2, velocity: a * r1 * e1 + b * r2 * e2 };
}

/**
 * A spring in flight: its state at any time comes from where it last started.
 * A new target (or a fling's velocity) starts it again from its state at that
 * moment, so the motion stays continuous.
 */
export type Spring = {
  readonly config: SpringConfig;
  target: number;
  /** The state it started from, at `startTime` (ms). */
  start: SpringState;
  startTime: number;
};

export function createSpring(
  config: SpringConfig,
  position: number,
  time: number
): Spring {
  return {
    config,
    target: position,
    start: { position, velocity: 0 },
    startTime: time,
  };
}

/** The spring's state at `time` (ms). */
export function springStateAt(spring: Spring, time: number): SpringState {
  return springAt(
    spring.config,
    spring.start,
    spring.target,
    (time - spring.startTime) / 1000
  );
}

/**
 * Starts the spring again at `time` toward `target`, from its state then; a
 * given `velocity` replaces the state's (a fling).
 */
export function retargetSpring(
  spring: Spring,
  time: number,
  target: number,
  velocity?: number
) {
  const now = springStateAt(spring, time);
  spring.start = { position: now.position, velocity: velocity ?? now.velocity };
  spring.startTime = time;
  spring.target = target;
}

/** Puts the spring at `position`, still, from `time`. */
export function placeSpring(spring: Spring, time: number, position: number) {
  spring.start = { position, velocity: 0 };
  spring.startTime = time;
  spring.target = position;
}

/** Whether the spring is within `distance` of its target and slower than `speed`. */
export function springAtRest(
  state: SpringState,
  target: number,
  distance: number,
  speed: number
) {
  return (
    Math.abs(state.position - target) < distance && Math.abs(state.velocity) < speed
  );
}

/**
 * A tween's value at `elapsed` ms: from `from` to `to` over `duration` ms,
 * shaped by `easing` (linear unless given), held at `to` once it has ended.
 */
export function tween(
  from: number,
  to: number,
  duration: number,
  elapsed: number,
  easing: (progress: number) => number = (progress) => progress
) {
  if (duration <= 0 || elapsed >= duration) return to;
  if (elapsed <= 0) return from;
  return from + (to - from) * easing(elapsed / duration);
}
