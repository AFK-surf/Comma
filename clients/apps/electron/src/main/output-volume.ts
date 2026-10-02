import { execFile } from "node:child_process";

/** Runs a program and resolves with what it printed. */
export type RunProgram = (file: string, args: readonly string[]) => Promise<string>;

const runProgram: RunProgram = (file, args) =>
  new Promise((resolve, reject) => {
    execFile(file, [...args], { timeout: 2_000 }, (error, stdout) =>
      error ? reject(error) : resolve(stdout)
    );
  });

/**
 * The Mac's output volume, from 0 to 1, as System Settings shows it. Null
 * when the output has no volume (AppleScript answers "missing value") or the
 * read fails: the caller then treats it as unknown.
 */
export async function readMacOutputVolume(run: RunProgram = runProgram) {
  try {
    const answer = await run("/usr/bin/osascript", [
      "-e",
      "output volume of (get volume settings)",
    ]);
    const percent = Number.parseInt(answer.trim(), 10);
    return Number.isFinite(percent) ? Math.min(1, Math.max(0, percent / 100)) : null;
  } catch {
    return null;
  }
}
