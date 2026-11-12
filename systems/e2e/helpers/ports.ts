// Ports a test reserves and hands to a process it starts (MinIO, Salix and its transfer listeners, PostgreSQL).
// The port is free while it is held here and is released just before the process binds it. They come from below
// the operating system's ephemeral range, so nothing the OS assigns in that gap (a `port: 0` listener of a started
// app, an outgoing connection) can take one: on 2026-10-29 Salix's observability listener (port 0 in test) took
// the transfer port a test had just released.
import { readFileSync } from "node:fs";

export type PortLease = {
  port: number;
  release: () => void;
};

const FIRST_PORT = 20_000;
// Below Linux's default ephemeral range (32768) and macOS's (49152).
const DEFAULT_EPHEMERAL_START = 32_768;

let next = FIRST_PORT;

function ephemeralStart(): number {
  let range: string;
  try {
    range = readFileSync("/proc/sys/net/ipv4/ip_local_port_range", "utf8");
  } catch {
    return DEFAULT_EPHEMERAL_START;
  }
  const first = Number(range.trim().split(/\s+/)[0]);
  if (!Number.isInteger(first)) return DEFAULT_EPHEMERAL_START;
  return first;
}

const limit = ephemeralStart();
if (limit <= FIRST_PORT)
  throw new Error(`the ephemeral port range starts at ${limit}, at or below the e2e ports from ${FIRST_PORT}`);

/** A free port below the ephemeral range, held until `release`. */
export function reservePort(): PortLease {
  for (; next < limit; next++) {
    let listener: Bun.TCPSocketListener<undefined>;
    try {
      listener = Bun.listen<undefined>({ hostname: "127.0.0.1", port: next, socket: { data() {} } });
    } catch {
      continue;
    }
    next++;
    let released = false;
    return {
      port: listener.port,
      release() {
        if (released) return;
        released = true;
        listener.stop(true);
      },
    };
  }
  throw new Error(`no free port between ${FIRST_PORT} and ${limit}`);
}

export function releasePorts(...ports: PortLease[]) {
  for (const port of ports) port.release();
}
