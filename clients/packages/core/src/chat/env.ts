// What chat's engine needs of the world besides the API: timers, the time and randomness. The core gives them from
// its Clock and the host's random bytes (chat/clock.ts), so a run can be recorded and played again; tests give their
// own. The engine's long-lived work (a channel's connection) runs as fibers on the core's runner.
import type { Runner } from "@comma/core-kernel";
import { Duration, Effect, type Fiber } from "effect";

/** A timer `after` started, to cancel it: a fiber sleeping on the core's Clock. */
export type TimerHandle = Fiber.Fiber<void>;

export interface ChatEnv {
  /** Where chat's long-lived work runs: the core's fibers, on its Clock. */
  runner: Runner;
  /** Milliseconds since the Unix epoch. */
  now(): number;
  /** A number in [0, 1). */
  random(): number;
  /** A random version 4 UUID. */
  uuid(): string;
}

/** A UUID's text for 16 random bytes (version 4, RFC 9562 variant). */
export function uuidOf(bytes: Uint8Array): string {
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Runs `run` after `delayMs` on the core's Clock. */
export function after(
  env: { runner: Runner },
  delayMs: number,
  run: () => void
): TimerHandle {
  return env.runner.fork(
    Effect.sleep(Duration.millis(Math.max(0, delayMs))).pipe(
      Effect.andThen(Effect.sync(run))
    )
  );
}

/** Cancels a timer `after` started (none: nothing). */
export function cancel(env: { runner: Runner }, timer: TimerHandle | undefined): void {
  if (timer) env.runner.interrupt(timer);
}
