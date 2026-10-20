// What the machine a station runs on looks like (GET /host), ported from the Rust station's host.rs: for people deciding
// where work goes and whether a station is struggling. How each machine is read (memory, CPU time, uptime, its OS) is
// the platform's (platform/: macOS's sysctl and vm_stat, Linux's /proc, what Node's os says on Windows); disk is the
// file system holding the station's data directory. It runs commands and may wait a moment for the CPUs, so it runs in
// a reader thread; what the Rust keeps between looks (the ticks last seen, the answer of the last ten seconds) the main
// thread keeps (api/routes/usage.ts) and hands in, as readers come and go.
import { statfsSync } from "node:fs";
import { availableParallelism, hostname as osHostname, loadavg } from "node:os";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";

/// CPU time since boot, all CPUs together: (busy, total).
export type Ticks = [busy: number, total: number];
/// The ticks last seen, and when (host.rs TICKS).
export type Seen = { at: number; ticks: Ticks } | null;

/// hostname, without a `.local`.
function hostname(): string {
  const name = osHostname();
  return name.endsWith(".local") ? name.slice(0, -".local".length) : name;
}

/// A real sleep, in a reader thread.
const sleep = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/// cpu_busy: how busy the CPUs have been since the last look, if that was within a minute; otherwise over the next
/// moment. With the ticks seen now, for the next look.
function cpuBusy(last: Seen): [busy: number | null, seen: Seen] {
  const share = ([b0, t0]: Ticks, [b1, t1]: Ticks) => (t1 > t0 ? Math.min(Math.max(Math.max(b1 - b0, 0) / (t1 - t0), 0), 1) : null);
  const before = last !== null && wall.now() - last.at < 60_000 ? last.ticks : null;
  let now = platform.host.cpuTicks();
  if (now === null) return [null, last];
  let busy = before === null ? null : share(before, now);
  if (busy === null) {
    // macOS updates the ticks only now and then (seen unchanged after a real 505 ms, 2026-09-30), so it looks again,
    // up to 2 s, until they have moved.
    const then = now;
    const start = wall.now();
    sleep(500);
    let again: Ticks | null;
    for (;;) {
      again = platform.host.cpuTicks();
      if (again === null || again[1] > then[1] || wall.now() - start >= 2000) break;
      sleep(100);
    }
    if (again === null) return [null, last];
    now = again;
    busy = share(then, now);
    if (busy === null) return [null, last];
  }
  return [Math.round(busy * 100) / 100, { at: wall.now(), ticks: now }];
}

/// disk: the file system holding `path`: its size and what is free for the station.
function disk(path: string) {
  try {
    const st = statfsSync(path);
    return { path, totalBytes: st.blocks * st.bsize, freeBytes: st.bavail * st.bsize };
  } catch {
    return { path, totalBytes: 0, freeBytes: 0 };
  }
}

/// host_info (without its ten-second cache, which the caller keeps): the machine's state now, and the ticks seen.
export function hostInfo(dataDir: string, last: Seen): { info: unknown; seen: Seen } {
  const { host } = platform;
  const mem = host.memory();
  const os = host.osName();
  const model = host.cpuModel();
  const uptime = host.uptimeSec();
  const rss = host.ownRss();
  const [busy, seen] = cpuBusy(last);
  const n = availableParallelism();
  const info = {
    hostname: hostname(),
    os,
    arch: process.arch,
    cpus: n,
    cpuModel: model,
    load: Math.round((loadavg()[0]! / Math.max(n, 1)) * 100) / 100,
    cpuBusy: busy,
    uptimeSec: uptime,
    memory: mem,
    disk: disk(dataDir),
    emberRssBytes: rss,
    checkedAt: wall.now(),
  };
  return { info, seen };
}
