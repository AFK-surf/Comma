// Where the station's endpoint may be reached (its home relay, its direct addresses), kept in memory as it changes:
// the presence socket tells the control plane (cloud/presence.ts), and Comma gives it to the workspace's stations and
// members as hints for dialing. iroh still authenticates the station by its key, whatever address was dialed.
import { Effect } from "effect";
import type { Cloud } from "../cloud/state.ts";
import type { Endpoint, Reach } from "./native.ts";

/// Runs until the endpoint closes or it is interrupted; then the station has no reach to tell.
export const followReach = (endpoint: Pick<Endpoint, "reach">, cloud: Cloud) =>
  Effect.gen(function* () {
    let last: Reach | null = null;
    for (;;) {
      const now: Reach | null = yield* Effect.promise(() => endpoint.reach(last));
      if (now === null) return;
      cloud.setReach(now);
      last = now;
    }
  }).pipe(Effect.ensuring(Effect.sync(() => cloud.setReach(null))));
