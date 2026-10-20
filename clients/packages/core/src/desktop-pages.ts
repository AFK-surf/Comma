// The clock of the Compute page's local node (`computeTick`): while shown, `tick` grows every 5 s, and the page reads
// what each tick asks for. The core keeps its time on its Clock.
//
// Bounds: per device, while the page is shown, one tick every 5 s; it stops as soon as no window shows it.
import type { Scoped } from "@comma/core-kernel";
import { Duration, Effect } from "effect";
import type { Ctx } from "./ctx.ts";

export const COMPUTE_TICK_MS = 5_000;

export class DesktopPages {
  #tick = 0;
  #tickScope: Scoped | null = null;

  constructor(ctx: Ctx) {
    ctx.kernel.source("computeTick", {
      start: () => {
        if (this.#tickScope) return;
        const scope = ctx.runner.child();
        this.#tickScope = scope;
        ctx.runner.fork(
          Effect.forever(
            Effect.sleep(Duration.millis(COMPUTE_TICK_MS)).pipe(
              Effect.andThen(
                Effect.sync(() => {
                  this.#tick += 1;
                  ctx.kernel.store.invalidate({ topic: "computeTick" });
                })
              )
            )
          ),
          scope
        );
      },
      stop: () => {
        if (this.#tickScope) ctx.runner.close(this.#tickScope);
        this.#tickScope = null;
      },
      compute: () => ({ ok: { tick: this.#tick } }),
      evictAfterMs: 0,
    });
  }
}
