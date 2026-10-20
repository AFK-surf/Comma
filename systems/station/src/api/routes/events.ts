// GET /events (admin/mod.rs): every change to what the API shows, pushed as it happens (src/api/events.ts).
import { type Request, error, param } from "../request.ts";
import type { Route, Tools } from "../admin.ts";

/// A query's values for `name`, in order (`asked.params`).
const all = (r: Request, name: string) => r.query.filter(([k]) => k === name).map(([, v]) => v);

/// Rust's `parse::<usize>()`: digits only (a leading + too).
const usize = (v: string | undefined) => (v !== undefined && /^\+?[0-9]+$/.test(v) ? Number(v) : null);

export const routes = ({ events, sessionExists }: Tools): Route[] => [
  {
    method: "GET",
    pattern: /^\/events$/,
    handle: async (r: Request) => {
      if (events === undefined) return error(503, "events not ready");
      // `live=<key>&from=<n>&last=<m>`, repeated: those sessions as they run, on this same stream (from entry `n`, but
      // no more than the last `m` of the transcript; `last=0`: all of it).
      const froms = all(r, "from");
      const lasts = all(r, "last");
      const live = all(r, "live")
        .map((key, i): [string, number, number | null] => {
          const f = Number(froms[i]);
          const from = froms[i] !== undefined && froms[i]!.trim() !== "" && !Number.isNaN(f) ? Math.trunc(Math.max(0, f)) : 0;
          const last = usize(lasts[i]);
          return [key, Number.isFinite(from) ? from : Number.MAX_SAFE_INTEGER, last !== null && last > 0 ? last : null];
        })
        .filter(([key]) => sessionExists(key));
      // `job=<id>&lines=<n>`, repeated: those jobs' last `n` lines of output, now and as they grow.
      const lines = all(r, "lines");
      const logs = all(r, "job").map((id, i): [string, number] => [id, Math.min(1000, Math.max(1, usize(lines[i]) ?? 200))]);
      return events.open(r.viewer, r.lang, param(r, "host") === "1", live, logs);
    },
  },
];
