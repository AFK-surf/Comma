// What the agents spent, the machine's own sessions, the agents' memory, the machine itself, and the retired footprint
// (admin/mod.rs: GET /usage, /machine-sessions, /machine-sessions/:runtime/:id, /memory, /host, /footprint).
import { type Request, type Answer, error, json, param, percentDecode } from "../request.ts";
import type { Route, Tools } from "../admin.ts";

const I64_MIN = -9223372036854775808n;
const I64_MAX = 9223372036854775807n;

/// `v.parse::<f64>().ok().map(|v| v as i64)`: Rust's float syntax (inf, infinity and nan too, any case), then as an i64
/// (NaN 0, beyond its range its ends, the fraction dropped). None when it does not read.
function number(r: Request, name: string): bigint | null {
  const v = param(r, name);
  if (v === undefined || !/^[+-]?(?:inf|infinity|nan|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$/i.test(v)) return null;
  const body = v.replace(/^[+-]/, "").toLowerCase();
  const x = body === "nan" ? NaN : body === "inf" || body === "infinity" ? (v.startsWith("-") ? -Infinity : Infinity) : Number(v);
  if (Number.isNaN(x)) return 0n;
  if (x >= 2 ** 63) return I64_MAX;
  if (x < -(2 ** 63)) return I64_MIN;
  return BigInt(Math.trunc(x));
}

/// A path segment (admin/mod.rs segment_decode): `+` stays itself there.
const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));

/// The Rust's `/footprint` for clients from before footprint statistics were retired (admin/footprint.rs `retired`).
const RETIRED = JSON.stringify({
  checkedAt: null, tookMs: null, scanning: false, manage: false,
  disk: { totalBytes: 0, freeBytes: 0 },
  parts: [], elsewhere: [], chats: [],
  unseen: { count: 0, bytes: 0 },
  memory: { totalBytes: 0, usedBytes: 0, stationBytes: 0 },
  processes: [],
});

export const routes = ({ read, host, agents }: Tools): Route[] => {
  return [
    // What the agents spent from `from` until `to` (ms), by day as the asker's clock has them (`tz`: minutes east of
    // UTC), with whom, where and on what.
    {
      method: "GET",
      pattern: /^\/usage$/,
      handle: (r: Request) => {
        const to = number(r, "to") ?? I64_MAX;
        const from = number(r, "from") ?? 0n;
        const tz = number(r, "tz") ?? 0n;
        const clamped = tz < -1440n ? -1440n : tz > 1440n ? 1440n : tz;
        return read(r, "usage", { lang: r.lang, from: String(from), to: String(to), tz: String(clamped), reading: agents?.usage.readingAll() ?? true });
      },
    },
    // Sessions this machine's own Claude Code and Codex kept (in a terminal), to go on with one in a chat.
    { method: "GET", pattern: /^\/machine-sessions$/, handle: (r: Request) => read(r, "machineSessions", {}) },
    // One of them, to look at before going on with it: what was said, the latest `limit`. As the Rust matches its
    // segments (empty ones dropped, any after the third ignored).
    {
      method: "GET",
      pattern: /^\/+machine-sessions\/+([^/]+)\/+([^/]+)(?:\/.*)?$/,
      handle: (r: Request, [runtime, id]: string[]) =>
        read(r, "machineSession", { lang: r.lang, runtime: segment(runtime!), id: segment(id!), limit: param(r, "limit") }),
    },
    // The agents' memory, for the pages to show: the global one, and the shared skills (projects' memories among them).
    { method: "GET", pattern: /^\/memory$/, handle: (r: Request) => read(r, "memory", {}) },
    // The machine's state, at most ten seconds old.
    {
      method: "GET",
      pattern: /^\/host$/,
      handle: async (r: Request): Promise<Answer> => {
        try {
          return json(200, JSON.stringify(await host.sample(r.lang)));
        } catch (e) {
          return error(500, (e as Error).message);
        }
      },
    },
    // Retired: old clients' route kept, without scanning.
    { method: "GET", pattern: /^\/footprint$/, handle: async () => json(200, RETIRED) },
  ];
};
