import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

/** Starts an AirDrop helper. Tests replace it with an in-process helper. */
export type SpawnAirDropHelper = (
  command: string,
  args: string[]
) => ChildProcessWithoutNullStreams;

/** Every stream is a pipe, and no shell reads the arguments. */
export const spawnAirDropHelper: SpawnAirDropHelper = (command, args) =>
  spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], shell: false });
