// Where the core's work runs: fibers on Effect's runtime, in scopes, every timer on its Clock — the live one, or a
// TestClock in tests. What arrives from outside (a UI's message, a host callback) is synchronous; it starts fibers
// here. Nothing in the core calls setTimeout itself.
import { Cause, Clock, Effect, Exit, Fiber, FiberSet, Scheduler, Scope } from "effect";

/**
 * A scheduler that runs the core's work to the end before what came in returns: each task as soon as it is queued (in
 * priority order, one at a time), never yielding to the host's event loop. What a core does about one input is done
 * before the next input arrives, so a run is fixed by its inputs and their order alone: a recorded run plays again
 * exactly. Tests and replays run on it.
 */
export class TurnScheduler implements Scheduler.Scheduler {
  readonly executionMode = "sync" as const;
  readonly #tasks: { task: () => void; priority: number }[] = [];
  #running = false;

  shouldYield(): boolean {
    return false;
  }

  makeDispatcher(): Scheduler.SchedulerDispatcher {
    return {
      scheduleTask: (task, priority) => {
        let at = this.#tasks.length;
        while (at > 0 && this.#tasks[at - 1]!.priority > priority) at--;
        this.#tasks.splice(at, 0, { task, priority });
        this.#drain();
      },
      flush: () => this.#drain(),
    };
  }

  #drain(): void {
    if (this.#running) return;
    this.#running = true;
    try {
      for (let next = this.#tasks.shift(); next; next = this.#tasks.shift())
        next.task();
    } finally {
      this.#running = false;
    }
  }
}

/// A scope and the fibers forked in it: closing it interrupts them, and anything else that was opened in it.
export type Scoped = {
  readonly scope: Scope.Closeable;
  readonly fibers: FiberSet.FiberSet<unknown, unknown>;
};

export class Runner {
  readonly clock: Clock.Clock | null;
  /// The core's own: closing it ends everything.
  readonly root: Scoped;
  #closed = false;
  /// Told of a fiber that failed with a bug: a native host starts the core anew.
  onDefect: (error: unknown) => void = (error) => {
    console.error("core fiber failed", error);
  };

  /// The scheduler the core's fibers run on (Effect's own unless given: `TurnScheduler` in tests and replays).
  readonly scheduler: Scheduler.Scheduler | null;

  constructor(clock?: Clock.Clock, scheduler?: Scheduler.Scheduler) {
    this.clock = clock ?? null;
    this.scheduler = scheduler ?? null;
    const scope = Scope.makeUnsafe();
    this.root = {
      scope,
      fibers: Effect.runSync(Scope.provide(FiberSet.make(), scope)),
    };
  }

  /// The effect with the core's clock.
  provide<A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
    const clocked = this.clock
      ? effect.pipe(Effect.provideService(Clock.Clock, this.clock))
      : effect;
    return this.scheduler
      ? clocked.pipe(Effect.provideService(Scheduler.Scheduler, this.scheduler))
      : clocked;
  }

  /// Runs an effect as a fiber of `scoped` (the core's by default): interrupted when it closes. A failure that is no
  /// interruption is a bug, told to `onDefect`.
  fork<A, E>(
    effect: Effect.Effect<A, E>,
    scoped: Scoped = this.root
  ): Fiber.Fiber<A, E> {
    const fiber = Effect.runFork(this.provide(effect));
    fiber.addObserver((exit) => {
      if (Exit.isFailure(exit) && !Cause.hasInterruptsOnly(exit.cause))
        this.onDefect(Cause.squash(exit.cause));
    });
    FiberSet.addUnsafe(scoped.fibers, fiber as Fiber.Fiber<unknown, unknown>);
    return fiber;
  }

  /// An effect's result as a promise (hosts' entries, tests).
  run<A, E>(effect: Effect.Effect<A, E>): Promise<A> {
    return Effect.runPromise(this.provide(effect));
  }

  /// A scope inside `parent` (a topic's, a link's).
  child(parent: Scoped = this.root): Scoped {
    const scope = Scope.forkUnsafe(parent.scope);
    return { scope, fibers: Effect.runSync(Scope.provide(FiberSet.make(), scope)) };
  }

  /// Closes a scope: what runs in it is interrupted.
  close(scoped: Scoped): void {
    Effect.runFork(Scope.close(scoped.scope, Exit.void));
  }

  interrupt(fiber: Fiber.Fiber<unknown, unknown>): void {
    Effect.runFork(Fiber.interrupt(fiber));
  }

  /// Stops everything (the core is let go).
  shutdown(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.close(this.root);
  }

  get closed(): boolean {
    return this.#closed;
  }
}
