// Commands the station starts as a group of their own: the command and everything it starts, ended together. How a
// machine makes a group is the platform's (platform.grouped: spawned detached on Unix, under `stillfail-runner --job`
// on Windows); what is done with one is said here, once, of two kinds:
// - a command (startCommand): the station's while it runs (a device command, a runtime's update), its output read; on
//   a timeout or a cancel it is ended whole (endCommand);
// - a lasting one (startLasting): a job, which lives on past the station, recorded by its pgid (its pid), and taken up
//   or ended by the station that runs later (jobs/group.ts).
import { type ChildProcess, type SpawnOptions, spawn } from "node:child_process";
import { platform } from "../platform/index.ts";

type Options = Pick<SpawnOptions, "cwd" | "env" | "stdio">;

/// `program` with `args` as a group of its own, the station's while it runs.
export function startCommand(program: string, args: string[], options: Options): ChildProcess {
  return spawn(...platform.grouped(program, args), { ...options, detached: true, windowsHide: true });
}

/// A command started by startCommand ended with `signal`, and all it started.
export const endCommand = (child: ChildProcess, signal: NodeJS.Signals): void => platform.signalChildGroup(child, signal);

/// `program` with `args` as a group of its own that outlives the station (nothing here waits for it).
export function startLasting(program: string, args: string[], options: Options): ChildProcess {
  const child = spawn(...platform.grouped(program, args), { ...options, detached: true, windowsHide: true });
  child.unref();
  return child;
}
