// Time for tests: a clock the test moves (`pass`), with every sleep asked of it noted, and the wall clock read from
// it. A core given `time.clock` (Runner) sleeps on it: what a test waits for happens when it says, however fast or slow
// the machine is.
import { Duration, Effect, type Clock } from "effect";

const nanos = (ms: number) => BigInt(Math.round(ms * 1_000_000));

/** A sleep under way: due at `due` (ms from the clock's zero). */
type Sleeper = { readonly due: number; readonly wake: () => void };

export class TestTime {
  readonly clock: Clock.Clock;
  /// Every sleep asked for (ms), in order: timers show here.
  readonly sleeps: number[] = [];
  /// What the clock read at its zero: the wall clock is this from there.
  readonly #base: number;
  /// The time passed since the zero (ms).
  #now = 0;
  /// The sleeps under way, by due time and then in the order they were asked for. An interrupted sleep leaves.
  readonly #sleepers: Sleeper[] = [];
  #ended = false;
  /// How long the computer slept (`sleepThrough`): the wall clock read is this much ahead of the timers.
  #slept = 0;
  /// What a move waits for at each stop: what is ready has run (`settle`), or a host's own measure of settled.
  readonly #settle: () => Promise<void>;

  constructor(start = Date.UTC(2026, 0, 1), settled: () => Promise<void> = settle) {
    this.#base = start;
    this.#settle = settled;
    const wall = () => this.#base + this.#slept + this.#now;
    this.clock = {
      currentTimeMillisUnsafe: wall,
      currentTimeMillis: Effect.sync(wall),
      currentTimeNanosUnsafe: () => nanos(wall()),
      currentTimeNanos: Effect.sync(() => nanos(wall())),
      monotonicTimeNanosUnsafe: () => nanos(this.#now),
      monotonicTimeNanos: Effect.sync(() => nanos(this.#now)),
      sleep: (duration: Duration.Duration) =>
        Effect.callback<void>((resume) => {
          const ms = Duration.toMillis(duration);
          this.sleeps.push(ms);
          if (!(ms > 0)) {
            resume(Effect.void);
            return;
          }
          const sleeper: Sleeper = {
            due: this.#now + ms,
            wake: () => resume(Effect.void),
          };
          const sleepers = this.#sleepers;
          let at = sleepers.length;
          while (at > 0 && sleepers[at - 1]!.due > sleeper.due) at--;
          sleepers.splice(at, 0, sleeper);
          return Effect.sync(() => {
            const index = sleepers.indexOf(sleeper);
            if (index >= 0) sleepers.splice(index, 1);
          });
        }),
    };
  }

  now(): number {
    return this.#base + this.#slept + this.#now;
  }

  /// When the earliest sleep under way is due, on the wall clock `now` reads; undefined when none is.
  nextDue(): number | undefined {
    const next = this.#sleepers[0];
    return next ? this.#base + this.#slept + next.due : undefined;
  }

  /// The wall clock moves `ms` on while no timer runs, as when the computer sleeps: what reads the time sees it, and a
  /// timer still waits its full time. A run that slept is not played again (a replay's clock does not sleep).
  sleepThrough(ms: number): void {
    this.#slept += ms;
  }

  /// The test that moves this clock has ended. A test that timed out runs on; its next move of the clock never returns,
  /// so what is left of it does not take the event loop from the tests after it.
  end(): void {
    this.#ended = true;
  }

  /// Lets `ms` of the core's time pass: the clock stops at each sleep due on the way, at its exact time, and what it
  /// wakes runs (and sleeps again) before the clock moves on. The work is one stop per timer, however long `ms` is.
  /// `_step` is not used (the clock once moved in fixed steps).
  async pass(ms: number, _step?: number): Promise<void> {
    if (this.#ended) return never();
    await this.#settle();
    await this.advance(ms);
  }

  /// `pass` for a caller whose last `flush` settled (said true): the clock moves at once, with the same stops.
  async advance(ms: number): Promise<void> {
    const target = this.#now + ms;
    for (;;) {
      if (this.#ended) return never();
      const next = this.#sleepers[0];
      if (!next || next.due > target) break;
      this.#sleepers.shift();
      this.#now = next.due;
      next.wake();
      await this.#settle();
    }
    this.#now = target;
    await this.#settle();
  }
}

/// Lets what is ready run: promise continuations and the runtime's scheduled fibers, turn by turn, at most `rounds`
/// turns. On Node it stops at the first turn that leaves nothing for the next, and says so (true): the turn's own
/// immediate runs after every continuation and every immediate queued before it, so with no immediate pending then,
/// another turn would run nothing (the core's work runs on immediates, continuations and its Clock, never a real
/// timer). Each turn is a trip through the event loop, which a loaded machine makes slow: a test pays for the turns
/// its work needs, not a fixed number.
export async function flush(rounds = 6): Promise<boolean> {
  const pending = immediatesPending();
  if (!pending) {
    for (let i = 0; i < rounds; i++)
      await new Promise<void>((r) =>
        // A turn of the event loop itself, outside the core: where Node has no immediates.
        // @effect-diagnostics-next-line globalTimers:off
        typeof setImmediate === "function" ? setImmediate(r) : setTimeout(r, 0)
      );
    return false;
  }
  for (let i = 0; i < rounds; i++) {
    const more = await new Promise<boolean>((r) => setImmediate(() => r(pending())));
    if (!more) return true;
  }
  return false;
}

const never = () => new Promise<void>(() => {});

/// Lets what is ready run until nothing is left for the next turn (on Node; elsewhere one `flush`): what the core
/// started finishes before the clock moves. A core that keeps queuing turns stops it after 64 flushes.
export async function settle(): Promise<void> {
  if (!immediatesPending()) {
    await flush();
    return;
  }
  for (let i = 0; i < 64; i++) if (await flush()) return;
}

/// Whether an immediate waits for the event loop's next turn, where Node can tell (null elsewhere).
function immediatesPending(): (() => boolean) | null {
  const node = (globalThis as { process?: { getActiveResourcesInfo?: () => string[] } })
    .process;
  if (
    typeof setImmediate !== "function" ||
    typeof node?.getActiveResourcesInfo !== "function"
  )
    return null;
  return () => node.getActiveResourcesInfo!().includes("Immediate");
}
