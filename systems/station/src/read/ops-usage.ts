// The reads of usage, the machine's own sessions, the agents' memory and the host (src/api/routes/usage.ts asks them).
// The request's language comes in the args (`lang`), as these words are said outside views.ts.
import type { ReadOp } from "./ops.ts";
import { hostInfo } from "./host.ts";
import { machineSession, machineSessions } from "./machine.ts";
import { memory } from "./memory.ts";
import { usage } from "./usage.ts";

export const usageOps: Record<string, ReadOp> = {
  // `reading`: the counter's readingAll (absent: true).
  usage: (store, a) => usage(store, a.lang, BigInt(a.from), BigInt(a.to), BigInt(a.tz), typeof a.reading === "boolean" ? a.reading : true),
  machineSessions: (store) => machineSessions(store),
  machineSession: (store, a) => machineSession(store, a.lang, a.runtime, a.id, a.limit),
  memory: (store) => memory(store.dataDir),
  host: (store, a) => hostInfo(store.dataDir, a.seen),
};
