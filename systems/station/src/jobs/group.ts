// Process groups as jobs use them (the Rust station's runtime/process.rs `signal_group`, `group_alive`, `still_ours`,
// `end_group`): a job runs in a group of its own, so it and what it starts are signalled together, and a group an
// earlier station recorded is checked to still be that group before it is touched (pids are reused).
//
// How a machine has groups is the platform's (platform/: on Windows a job's group is the job object of the
// `stillfail-runner --job` it runs under, its pgid that runner's pid, ended whole when the runner is).
import { Effect } from "effect";
import type { ProcessRow } from "../store/store.ts";
import { platform } from "../platform/index.ts";

/// Signals a whole group; one already gone is no error.
export const signalGroup = (pgid: number, signal: NodeJS.Signals): void => platform.signalGroup(pgid, signal);

/// Whether any process of the group is there (kill(-pgid, 0) == 0, as the Rust has it).
export const groupAlive = (pgid: number): boolean => platform.groupAlive(pgid);

/// Whether one process is there.
export { pidAlive } from "../platform/processes.ts";

/// When `pid` started (ms), or null if it is not running.
export const startTimeOf = (pid: number): number | null => platform.startTimeOf(pid);

/// Whether a group recorded by an earlier run is still that group. One whose leader is alive is only if the leader
/// started when it was recorded (pids get reused); one whose leader is gone but still has members is, where a group
/// lives on without its leader (a pgid cannot be reused while any member remains); where it does not, only a leader
/// known to be the one recorded is ours.
export function stillOurs(entry: ProcessRow): boolean {
  const started = startTimeOf(entry.pgid);
  // ps gives whole seconds: a few seconds either way is the same start.
  const ours = started !== null ? Math.abs(started - entry.startedAt) < 5000 : platform.groupOutlivesLeader && groupAlive(entry.pgid);
  return ours && groupAlive(entry.pgid);
}

/// How often a group being ended is looked at.
const LOOK_MS = 100;

/// SIGTERM a group, SIGKILL it if it is still there after `graceMs`. A group that is not this process's children has
/// no exit to wait on: it is looked at every 100 ms within the grace (as the Rust does), and only then. On the clock of
/// whoever runs it.
export function endGroup(pgid: number, graceMs: number): Effect.Effect<void> {
  return Effect.gen(function* () {
    signalGroup(pgid, "SIGTERM");
    for (let i = 0; i < Math.max(1, Math.floor(graceMs / LOOK_MS)); i++) {
      yield* Effect.sleep(LOOK_MS);
      if (!groupAlive(pgid)) return;
    }
    signalGroup(pgid, "SIGKILL");
  });
}
