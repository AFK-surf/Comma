import { writeSync } from "node:fs";

/**
 * The stdout line an Electron Main under test prints once its own shutdown has
 * finished. `closeElectronTestApp` waits for it.
 */
export const MAIN_SHUTDOWN_COMPLETE_LINE = "comma-e2e: main shutdown complete";

/** The stderr line an Electron Main under test prints, before its stack, when it exits on an uncaught exception. */
export const MAIN_UNCAUGHT_EXCEPTION_LINE = "comma-e2e: uncaught exception in main";

/** Exit code of a Main under test that ended on an uncaught exception. */
export const MAIN_UNCAUGHT_EXCEPTION_EXIT_CODE = 70;

let uncaught = false;

/**
 * Prints {@link MAIN_SHUTDOWN_COMPLETE_LINE} when Node exits, if `finished()`
 * says Main's quit sequence ran to its end. A Main that exits any other way
 * (a crash, a failed shutdown, an uncaught exception) prints nothing.
 */
export function reportMainShutdownOnExit(finished: () => boolean) {
  process.on("exit", () => {
    if (!uncaught && finished()) writeSync(1, `${MAIN_SHUTDOWN_COMPLETE_LINE}\n`);
  });
}

/**
 * Under test, an uncaught exception ends Main at once, its stack on stderr.
 * Electron's own handler opens a modal "A JavaScript error occurred in the main
 * process" alert instead, which blocks Main's thread: the test would time out
 * on its next call into Main, with no stack.
 */
export function exitOnUncaughtMainException() {
  process.on("uncaughtException", (error) => {
    uncaught = true;
    writeSync(
      2,
      `${MAIN_UNCAUGHT_EXCEPTION_LINE}\n${error instanceof Error ? (error.stack ?? String(error)) : String(error)}\n`
    );
    process.exit(MAIN_UNCAUGHT_EXCEPTION_EXIT_CODE);
  });
}
