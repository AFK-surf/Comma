import type { ElectronApplication } from "@playwright/test";

/**
 * Launch env for an Electron e2e that moves time itself: Main and the client core (Main's utility process) start on
 * test clocks that stand still until `advanceTestClock` moves them together. Only unpackaged test builds
 * (`NODE_ENV=test`) read it. The page's own clock (`page.clock`) moves neither: Main's timeouts, retries and
 * expiries, and the core's login delays, retries, task previews and connection recovery are on these clocks.
 * Waits whose deadline another process keeps on the real clock (child processes ending, gRPC deadlines) stay real.
 */
export const electronTestClockEnv = { COMMA_ELECTRON_E2E_TEST_CLOCK: "1" };

/**
 * Moves Main's and the core's clocks `ms` forward together. Each stop is the earliest timer due on either: both
 * clocks reach it, what woke runs, and Main's and the core's answers to what it asked settle before the next stop.
 * So the result is the same however fast the machine is, and no real time passes. A stream counts as answered once
 * it opened. Do not hold an answer the moved work waits for (a test's own pending IPC handler) across a move: the
 * move waits for it.
 */
export async function advanceTestClock(
  app: ElectronApplication,
  ms: number
): Promise<void> {
  await app.evaluate((_electron, by) => {
    const core = (
      globalThis as {
        commaE2eCore?: { advanceClock(ms: number): Promise<void> };
      }
    ).commaE2eCore;
    if (!core) throw new Error("Launch the app with electronTestClockEnv.");
    return core.advanceClock(by);
  }, ms);
}
