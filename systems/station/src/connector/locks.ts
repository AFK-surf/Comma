// Locks for state shared by fibers across waits: a mutex with try-lock, and a readers-writer lock. Waiters are served
// in arrival order; an interrupted waiter leaves the queue.
import { Deferred, Effect, Exit } from "effect";

export class Mutex {
  private held = false;
  private waiters: Array<Deferred.Deferred<void>> = [];

  get locked() {
    return this.held;
  }

  tryLock(): boolean {
    if (this.held) return false;
    this.held = true;
    return true;
  }

  readonly lock: Effect.Effect<void> = Effect.suspend(() => {
    if (this.tryLock()) return Effect.void;
    const waiter = Deferred.makeUnsafe<void>();
    this.waiters.push(waiter);
    return Deferred.await(waiter).pipe(
      Effect.onInterrupt(() =>
        Effect.sync(() => {
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) this.waiters.splice(index, 1);
          // Granted while being interrupted: pass it on.
          else if (Deferred.isDoneUnsafe(waiter)) this.unlock();
        }),
      ),
    );
  });

  unlock() {
    const next = this.waiters.shift();
    if (next) Deferred.doneUnsafe(next, Exit.void);
    else this.held = false;
  }

  /** Runs `effect` holding the lock. */
  with<A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
    return Effect.acquireUseRelease(
      this.lock,
      () => effect,
      () => Effect.sync(() => this.unlock()),
    );
  }
}

export class RWLock {
  private readers = 0;
  private writer = false;
  private queue: Array<{ write: boolean; grant: Deferred.Deferred<void> }> = [];

  private grantable(write: boolean) {
    return write ? !this.writer && this.readers === 0 : !this.writer && !this.queue.some((w) => w.write);
  }

  private acquire(write: boolean): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (this.queue.length === 0 && this.grantable(write)) {
        if (write) this.writer = true;
        else this.readers++;
        return Effect.void;
      }
      const grant = Deferred.makeUnsafe<void>();
      const entry = { write, grant };
      this.queue.push(entry);
      return Deferred.await(grant).pipe(
        Effect.onInterrupt(() =>
          Effect.sync(() => {
            const index = this.queue.indexOf(entry);
            if (index >= 0) this.queue.splice(index, 1);
            else if (Deferred.isDoneUnsafe(grant)) (write ? this.unlockWrite() : this.unlockRead());
          }),
        ),
      );
    });
  }

  private drain() {
    while (this.queue.length > 0) {
      const next = this.queue[0];
      if (next.write ? this.writer || this.readers > 0 : this.writer) return;
      this.queue.shift();
      if (next.write) this.writer = true;
      else this.readers++;
      Deferred.doneUnsafe(next.grant, Exit.void);
      if (next.write) return;
    }
  }

  readonly lockRead = this.acquire(false);
  readonly lockWrite = this.acquire(true);

  tryLockWrite(): boolean {
    if (this.queue.length > 0 || !this.grantable(true)) return false;
    this.writer = true;
    return true;
  }

  unlockRead() {
    this.readers--;
    this.drain();
  }

  unlockWrite() {
    this.writer = false;
    this.drain();
  }

  withRead<A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
    return Effect.acquireUseRelease(
      this.lockRead,
      () => effect,
      () => Effect.sync(() => this.unlockRead()),
    );
  }

  withWrite<A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> {
    return Effect.acquireUseRelease(
      this.lockWrite,
      () => effect,
      () => Effect.sync(() => this.unlockWrite()),
    );
  }
}
