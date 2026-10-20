import type { ChildProcess } from "node:child_process";
import type { ElectronApplication } from "@playwright/test";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../src/main/e2e-shutdown-report";
import { describeElectronMain } from "./electron-main-diagnostics";

interface TrackedMain {
  child: ChildProcess;
  report: ReturnType<typeof mainShutdownReport>;
  /** Resolves once Main exited and its output ended: its last line has been read. */
  outputEnded: Promise<void>;
}

const trackedMains = new WeakMap<ElectronApplication, TrackedMain>();

/**
 * Follows an app's Main from its launch (`electron.launch` calls this). Main
 * can print its shutdown report, or exit, before a test closes the app, for
 * example when the test closed the app's last window. Playwright disposes an
 * app whose process exited, and its `app.process()` then throws.
 */
export function trackElectronTestApp(app: ElectronApplication): TrackedMain {
  let tracked = trackedMains.get(app);
  if (!tracked) {
    const child = app.process();
    tracked = {
      child,
      report: mainShutdownReport(child),
      outputEnded: new Promise((resolve) => {
        if (child.stdout === null || child.stdout.readableEnded) resolve();
        else child.stdout.once("end", () => resolve());
      }),
    };
    trackedMains.set(app, tracked);
  }
  return tracked;
}

/**
 * Bound preparation and close. The close succeeds when the app exits, or when
 * Main reports that its own shutdown finished: its quit sequence ran to its
 * end and Node's exit fired (`reportMainShutdownOnExit`). After that report,
 * Chromium only flushes the throwaway test profile to disk, which took from
 * seconds to over a minute on a loaded or virtualized disk. That flush is not
 * the app's behavior under test, so its process group is killed. A Main that
 * does not report within the bound still fails the close, and a forced exit
 * before the report is never success. An exit by a signal (a crash) or with a
 * non-zero code fails it.
 *
 * Main may have reported, or exited, before the close: the report counts from
 * the launch, and a Main that already exited is not closed again. Its exit
 * counts as a finished close only with code 0 after its report.
 *
 * Playwright's close calls `app.quit()` through the Node inspector, which runs
 * it inside whatever Main code is running (a V8 interrupt). Electron 42 crashes
 * when that quit runs while a `BrowserWindow` is still being constructed: it
 * emits `close` on a window that has no JavaScript object yet. The close first
 * makes Main's `app.quit()` take effect on Main's next turn.
 */
export async function closeElectronTestApp(
  app: ElectronApplication,
  timeoutMs = 10_000,
  beforeClose?: () => Promise<void>,
  recordHung: (pid: number | undefined) => void | Promise<void> = recordHungMainProcess
): Promise<void> {
  const { child, report: shutdownReported, outputEnded } = trackElectronTestApp(app);
  const exitedBeforeClose = !running(child);
  let phase = exitedBeforeClose
    ? "reading the output of a Main that exited before the close"
    : beforeClose
      ? "preparing windows"
      : "closing app";
  let closeStartedAt: number | undefined;
  try {
    await within(
      (async () => {
        if (exitedBeforeClose) {
          // Node can deliver the exit before the last output: read it to its end.
          if (shutdownReported.reportedAt() === undefined) await outputEnded;
          if (shutdownReported.reportedAt() === undefined && child.exitCode === 0)
            throw new Error(
              "Electron test app exited before the close without reporting its shutdown"
            );
          assertCleanExit(child);
          return;
        }
        if (shutdownReported.reportedAt() === undefined) await beforeClose?.();
        phase = "closing app";
        closeStartedAt = Date.now();
        if (running(child) && shutdownReported.reportedAt() === undefined) {
          await quitOnMainTurn(app);
          // Playwright's close rejects for an app it already disposed; the
          // process's own exit decides the close.
          if (running(child))
            await Promise.race([
              app.close().catch(() => undefined),
              shutdownReported.promise,
              exit(child),
            ]);
        }
        if (running(child) && shutdownReported.reportedAt() !== undefined) {
          phase = "killing the process group after Main's shutdown report";
          await killProcessGroup(child);
          return;
        }
        await exit(child);
        assertCleanExit(child);
      })(),
      timeoutMs,
      () =>
        `Electron test app did not exit within ${timeoutMs}ms (${phase}; ${describeShutdownReport(
          shutdownReported.reportedAt(),
          closeStartedAt
        )})`
    );
  } catch (error) {
    if (running(child)) {
      await recordHung(child.pid);
      try {
        child.kill("SIGKILL");
        await within(
          exit(child),
          5_000,
          "Electron test process did not stop after SIGKILL"
        );
      } catch (cleanupError) {
        throw new Error(`Electron test cleanup failed after: ${String(error)}`, {
          cause: cleanupError,
        });
      }
    }
    throw error;
  }
}

const running = (child: ChildProcess) =>
  child.exitCode === null && child.signalCode === null;

function exit(child: ChildProcess) {
  return running(child)
    ? new Promise<void>((resolve) => child.once("exit", () => resolve()))
    : Promise.resolve();
}

function assertCleanExit(child: ChildProcess) {
  if (child.signalCode !== null)
    throw new Error(`Electron test app exited by ${child.signalCode} while closing`);
  if (child.exitCode !== 0)
    throw new Error(
      `Electron test app exited with code ${child.exitCode} while closing`
    );
}

/**
 * Makes each later `app.quit()` in Main run on Main's next turn, outside any
 * Main code that is running when the call arrives. Replacing the method is safe
 * at any point. A Main that has already exited rejects the request; the close
 * then only waits for Playwright.
 */
async function quitOnMainTurn(app: ElectronApplication) {
  await app
    .evaluate(({ app: main }) => {
      const quit = main.quit.bind(main);
      main.quit = () => {
        setImmediate(quit);
      };
    })
    .catch(() => undefined);
}

/** Resolves when Main prints its shutdown report on stdout, and records when. */
function mainShutdownReport(child: ChildProcess) {
  const reported = Promise.withResolvers<void>();
  let reportedAt: number | undefined;
  let buffered = "";
  const onData = (chunk: Buffer | string) => {
    buffered += chunk.toString();
    const lines = buffered.split("\n");
    buffered = lines.pop()!;
    if (reportedAt === undefined && lines.includes(MAIN_SHUTDOWN_COMPLETE_LINE)) {
      reportedAt = Date.now();
      reported.resolve();
    }
  };
  child.stdout?.on("data", onData);
  return {
    promise: reported.promise,
    reportedAt: () => reportedAt,
  };
}

// A failed close names whether Main finished its own shutdown, and when: the
// error then tells a stalled quit sequence in Main from a slow kill.
function describeShutdownReport(
  reportedAt: number | undefined,
  closeStartedAt: number | undefined
) {
  if (reportedAt === undefined) return "Main did not report its shutdown";
  if (closeStartedAt === undefined)
    return "Main reported its shutdown before the close";
  return `Main reported its shutdown ${reportedAt - closeStartedAt}ms after the close began`;
}

/** Kills Main and the Chromium helpers it started, and waits for Main to exit. */
async function killProcessGroup(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  try {
    // Playwright starts Electron as the leader of its own process group.
    process.kill(process.platform === "win32" ? child.pid! : -child.pid!, "SIGKILL");
  } catch {
    child.kill("SIGKILL");
  }
  await exited;
}

async function within<T>(
  work: Promise<T>,
  timeoutMs: number,
  message: string | (() => string)
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(typeof message === "function" ? message() : message)),
          timeoutMs
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// A main process that does not exit is usually blocked on its main thread.
// Record where, before the kill erases it: the test report and the CI log then
// name the frame.
async function recordHungMainProcess(pid: number | undefined) {
  if (pid === undefined) return;
  const report = await describeElectronMain(pid);
  console.error(
    `Electron main process ${pid} did not exit:\n${report.slice(0, 20_000)}`
  );
  // Loaded here: the close is also unit-tested outside Playwright.
  const { test } = await import("@playwright/test");
  try {
    await test.info().attach(`electron-main-${pid}`, {
      body: report,
      contentType: "text/plain",
    });
  } catch {
    // Not inside a Playwright test.
  }
}
