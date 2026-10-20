// The connector's clock: Effect's live Clock, or a TestClock the tests advance. Every effect the connector runs or
// returns is provided with it, so its timeouts, sleeps and timestamps follow the same time.
import { Clock, Duration, Effect, Scope } from "effect";
import { TestClock } from "effect/testing";
import { liveClock as stationClock, wall } from "../ops/fibers.ts";

export type ConnectorClock = {
  /** Runs `effect` on this clock. */
  provide<A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R>;
  /** Milliseconds since the epoch on this clock. */
  nowMs(): number;
  /** Advances a test clock; a live clock refuses. */
  advance(duration: Duration.Input): Effect.Effect<void>;
  /** How many sleeps a test clock holds, for a test to advance only once a wait began; a live clock says 0. */
  sleeps(): number;
  readonly isTest: boolean;
};

export function liveClock(): ConnectorClock {
  return {
    // The station's live clock: a wait does not keep the process up by itself (a screenshot's expiry, a backoff).
    provide: (effect) => Effect.provideService(effect, Clock.Clock, stationClock),
    nowMs: () => wall.now(),
    advance: () => Effect.die(new Error("advanceClockForTest needs a connector made with testClock: true")),
    sleeps: () => 0,
    isTest: false,
  };
}

export function testClock(): ConnectorClock {
  const scope = Effect.runSync(Scope.make());
  // Its warning fiber waits on the live clock it finds: the station's, which keeps no process up.
  const test = Effect.runSync(Scope.provide(scope)(TestClock.make({ warningDelay: Duration.hours(24) })).pipe(Effect.provideService(Clock.Clock, stationClock)));
  // The clock reads as the wall time at creation plus what the test advanced: timestamps it writes are plausible, and
  // only the test moves it.
  const baseMs = wall.now();
  const baseNanos = BigInt(baseMs) * 1_000_000n;
  let sleeps = 0;
  const clock: Clock.Clock = {
    currentTimeMillisUnsafe: () => baseMs + test.currentTimeMillisUnsafe(),
    currentTimeMillis: Effect.sync(() => baseMs + test.currentTimeMillisUnsafe()),
    currentTimeNanosUnsafe: () => baseNanos + test.currentTimeNanosUnsafe(),
    currentTimeNanos: Effect.sync(() => baseNanos + test.currentTimeNanosUnsafe()),
    monotonicTimeNanosUnsafe: () => test.monotonicTimeNanosUnsafe(),
    monotonicTimeNanos: test.monotonicTimeNanos,
    sleep: (duration) =>
      Effect.suspend(() => {
        sleeps++;
        return test.sleep(duration).pipe(Effect.ensuring(Effect.sync(() => void sleeps--)));
      }),
  };
  return {
    provide: (effect) => Effect.provideService(effect, Clock.Clock, clock),
    nowMs: () => clock.currentTimeMillisUnsafe(),
    advance: (duration) => test.adjust(duration),
    sleeps: () => sleeps,
    isTest: true,
  };
}
