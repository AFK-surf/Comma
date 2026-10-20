// The desktop app's own update (the host's `desktop.updates`: Electron's Main and its Velopack feed). The core checks
// the feed when it starts and then each hour; a failed check is tried again after 5 and 30 seconds, then after the
// hour. A release found is downloaded at once, and then the core checks no more: the `appUpdate` topic offers the
// restart until the app restarts into it. Check for Updates (`appUpdate.check`) joins the check under way, or checks
// now, and moves the schedule as any check does. The main window coming back (`appUpdate.wake`: focus, the network)
// runs a check the wall clock says is overdue, as after the computer slept.
//
// Bounds: one schedule per device (the core's), one check at a time: one an hour, and two retries after a failure.
import { asCoreError, CoreError } from "@comma/core-kernel";
import { Duration, Effect, Fiber, Queue, Result } from "effect";
import type { AppUpdateValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { AppRelease, AppUpdatePorts } from "./host.ts";

export const APP_UPDATE_INTERVAL_MS = 60 * 60_000;
export const APP_UPDATE_RETRY_MS = [5_000, 30_000] as const;

type Ready = { productName: string; version: string; release: AppRelease };
/** What a check found: no feed, nothing newer, or a release on disk. */
type Outcome = "unconfigured" | "current" | Ready;

export class AppUpdates {
  readonly #ctx: Ctx;
  readonly #ports: AppUpdatePorts | undefined;
  #ready: Ready | null = null;
  #downloading = false;
  /** The check under way: the schedule and Check for Updates wait for the same one. */
  #check: Fiber.Fiber<Result.Result<Outcome, CoreError>> | null = null;
  /** Failed checks in a row: the retries used. */
  #failures = 0;
  /** When the schedule checks next, on the core's clock: at once when the core starts. */
  #due = 0;
  readonly #wakes = Effect.runSync(Queue.dropping<void>(1));

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#ports = ctx.host.desktop?.updates;
    ctx.kernel.source("appUpdate", {
      start() {},
      stop() {},
      compute: () => ({ ok: this.#value() }),
    });
    ctx.kernel.calls({
      "appUpdate.check": {
        run: () =>
          this.#checkNow().pipe(
            Effect.map((outcome) => ({
              outcome: typeof outcome === "string" ? outcome : ("ready" as const),
            }))
          ),
      },
      "appUpdate.apply": { run: () => this.#apply() },
      "appUpdate.wake": {
        run: () =>
          Effect.sync(() => {
            Queue.offerUnsafe(this.#wakes, undefined);
            return null;
          }),
      },
    });
    if (this.#ports) ctx.runner.fork(this.#schedule());
  }

  /** Checks when due, until a release is on disk. Woken early, it looks at the clock again. */
  #schedule(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      while (!this.#ready) {
        const wait = this.#due - this.#ctx.now();
        if (wait > 0)
          yield* Effect.raceFirst(
            Effect.sleep(Duration.millis(wait)),
            Queue.take(this.#wakes)
          );
        else yield* this.#shared();
      }
    });
  }

  #checkNow(): Effect.Effect<Outcome, CoreError> {
    return this.#shared().pipe(
      Effect.flatMap((result) =>
        Result.isSuccess(result)
          ? Effect.succeed(result.success)
          : Effect.fail(result.failure)
      )
    );
  }

  /** The check under way, else a new one. It runs on its own: a caller that stops waiting does not stop it. */
  #shared(): Effect.Effect<Result.Result<Outcome, CoreError>> {
    return Effect.suspend(() => {
      const ports = this.#ports;
      if (this.#ready) return Effect.succeed(Result.succeed<Outcome>(this.#ready));
      if (!ports) return Effect.succeed(Result.succeed<Outcome>("unconfigured"));
      // It starts after a yield, so it is the one kept here before it can settle.
      this.#check ??= this.#ctx.runner.fork(
        Effect.yieldNow.pipe(
          Effect.andThen(this.#run(ports)),
          Effect.result,
          Effect.tap((result) => Effect.sync(() => this.#settle(result)))
        )
      );
      return Fiber.join(this.#check);
    });
  }

  #run(ports: AppUpdatePorts): Effect.Effect<Outcome, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const status = yield* ports.status;
      if (!status.configured) return "unconfigured" as const;
      if (status.error) return yield* Effect.fail(CoreError.host(status.error));
      const productName = status.productName ?? "Comma";
      const pending = status.pendingRestart;
      if (pending) return { productName, version: pending.version, release: pending };
      const release = yield* ports.check;
      if (!release) return "current" as const;
      this.#downloading = true;
      this.#changed();
      if (!(yield* ports.download(release)))
        return yield* Effect.fail(CoreError.host("The update was not downloaded."));
      return { productName, version: release.version, release };
    }).pipe(Effect.mapError(asCoreError));
  }

  /** A check ended: the next is due in an hour, or after the next retry's pause. */
  #settle(result: Result.Result<Outcome, CoreError>): void {
    this.#check = null;
    this.#downloading = false;
    const now = this.#ctx.now();
    if (Result.isSuccess(result)) {
      if (typeof result.success !== "string") this.#ready = result.success;
      this.#failures = 0;
      this.#due = now + APP_UPDATE_INTERVAL_MS;
    } else {
      const pause = APP_UPDATE_RETRY_MS[this.#failures];
      this.#failures = pause === undefined ? 0 : this.#failures + 1;
      this.#due = now + (pause ?? APP_UPDATE_INTERVAL_MS);
    }
    this.#changed();
  }

  #apply(): Effect.Effect<{ applied: boolean }, CoreError> {
    return Effect.suspend(() => {
      const ready = this.#ready;
      if (!ready || !this.#ports)
        return Effect.fail(CoreError.invalid("No update is ready."));
      return this.#ports.apply(ready.release).pipe(
        Effect.map((applied) => ({ applied })),
        Effect.mapError(asCoreError)
      );
    });
  }

  #value(): AppUpdateValue {
    const ready = this.#ready;
    return {
      downloading: this.#downloading,
      ready: ready ? { productName: ready.productName, version: ready.version } : null,
    };
  }

  #changed(): void {
    this.#ctx.kernel.store.invalidate({ topic: "appUpdate" });
  }
}
