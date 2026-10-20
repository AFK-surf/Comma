// Keeps the station on still.fail's relays (the Rust station's main.rs `keep_relays`): the ones browsers reach (they
// know no others), iroh homing on the nearest and the station kept on the rest too (keepers), so a device that reaches
// only some of them still reaches it. Those the cloud adds or takes away are put in or taken out as it pushes them.
// iroh's public relays come in only while none of ours answers (so the station can still be reached; the DHT says
// where), and go once one does again (else iroh may home on a public relay, where browsers can't follow).
import { Effect, Schedule, Stream } from "effect";
import { log } from "../ops/log.ts";
import { ControlPlane } from "../services.ts";
import type { Endpoint } from "./native.ts";

/// Asking our relays whether they answer is asking an outside system: the one timer here.
const RELAY_CHECK = "30 seconds";

/// Runs for good (until interrupted).
export const keepRelays = (endpoint: Endpoint) =>
  Effect.gen(function* () {
    const cloud = yield* ControlPlane;
    let ours = cloud.state.relays();
    endpoint.keep(ours);
    let added = false;

    // As the cloud pushes them.
    const follow = cloud.changes.pipe(
      Stream.runForEach(() =>
        Effect.promise(async () => {
          const now = cloud.state.relays();
          if (now.length === 0 || JSON.stringify(now) === JSON.stringify(ours)) return;
          log.info("mesh", "still.fail's relays changed", { relays: now });
          const was = ours;
          ours = now;
          for (const url of now.filter((u) => !was.includes(u))) await endpoint.insertRelay(url);
          for (const url of was.filter((u) => !now.includes(u))) await endpoint.removeRelay(url);
          endpoint.keep(now);
        }),
      ),
    );

    const check = Effect.promise(async () => {
      let up = false;
      // Two tries each: one lost request is not the relay down.
      relays: for (const relay of ours) {
        for (let i = 0; i < 2; i++) {
          try {
            const r = await fetch(`${relay.replace(/\/+$/, "")}/ping`, { signal: AbortSignal.timeout(10_000) });
            if (r.ok) {
              up = true;
              break relays;
            }
          } catch {}
        }
      }
      if (!up && !added) {
        log.warn("mesh", "none of still.fail's relays answers; adding iroh's public relays until one does", { relays: ours });
        await endpoint.publicRelays(true);
        added = true;
      } else if (up && added) {
        log.info("mesh", "still.fail's relays answer again; back home to them", { relays: ours });
        await endpoint.publicRelays(false);
        added = false;
      }
    });

    yield* Effect.all([follow, Effect.repeat(check, Schedule.spaced(RELAY_CHECK))], { concurrency: "unbounded", discard: true });
  });
