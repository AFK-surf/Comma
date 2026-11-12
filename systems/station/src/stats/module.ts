// The station's statistics as its connections send them (stats/index.ts): built from its own records and sent by each
// connection as its Task index is (connector/task-index.ts): as the station starts, a minute after what its agents spent
// was recorded, and every hour. Bounded: one build at a time.
import { Effect } from "effect";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import type { Store as StationStore } from "../store/store.ts";
import { type StatsIndexRow, StatsIndex } from "./index.ts";
import type { PagedIndex } from "../connector/task-index.ts";
import type { StatsSource } from "./rows.ts";

/// The Stats index as a connection sends it.
export type StationStats = PagedIndex<StatsIndexRow>;
import { selfSource } from "./self.ts";

const SETTLE_MS = 60_000;
const EVERY_MS = 60 * 60_000;

/// The station's Stats index, built and kept current until the returned function stops it; and, for each host's
/// connection, the index as it sends it (a tombstone goes once every host holds it).
export function stationStats(
  store: StationStore,
  data: string,
): { forHost: (host: string) => StationStats; stop: () => void } {
  const index = new StatsIndex(store.db);
  const sources: StatsSource[] = [selfSource(store.db, data)];
  let building: Promise<void> | null = null;
  // The sources to build next, once the build under way is done.
  const pending = new Set<StatsSource>();
  const run = (): void => {
    const these = sources.filter((s) => pending.has(s));
    pending.clear();
    building = index
      .build(these, wall.now(), (source, error) => log.info("stats", "a source gave nothing this time", { source, error: error.message }))
      .then(() => {}, (e) => log.warn("stats", "not built", { error: (e as Error).message }))
      .finally(() => {
        building = null;
        if (pending.size > 0) run();
      });
  };
  const build = (which: StatsSource[] = sources): void => {
    for (const s of which) pending.add(s);
    if (building === null) run();
  };
  let settle: (() => void) | null = null;
  const unsubscribe = store.subscribe((change) => {
    if (change.type !== "usage" || settle !== null) return;
    settle = wall.after(SETTLE_MS, () => {
      settle = null;
      build();
    });
  });
  let hourly = wall.after(EVERY_MS, function tick() {
    build();
    hourly = wall.after(EVERY_MS, tick);
  });
  build();
  const held = new Map<string, number>();
  return {
    forHost: (host) => ({
      epoch: () => index.epoch(),
      rev: () => index.rev(),
      since: (since, limit) => index.since(since, limit),
      prune: (through) => {
        held.set(host, through);
        index.prune(Math.min(...held.values()));
      },
      listen: (changed) => index.listen(changed),
    }),
    stop: () => {
      unsubscribe();
      settle?.();
      hourly();
    },
  };
}

export const statsLayer = (store: StationStore, data: string) =>
  Effect.acquireRelease(
    Effect.sync(() => stationStats(store, data)),
    (s) => Effect.sync(s.stop),
  );
