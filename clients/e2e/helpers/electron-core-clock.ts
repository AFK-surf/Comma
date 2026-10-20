import type { ElectronApplication } from "@playwright/test";

/**
 * Launch env for an Electron e2e that drives the client core's clock: the core (Main's utility process) starts on a
 * test clock that stands still until `advanceCoreClock` moves it. Only unpackaged test builds (`NODE_ENV=test`) read
 * it. The page's own clock (`page.clock`) does not move the core's timers: login delays, workspace-creating retries,
 * task previews and connection recovery are on the core's clock.
 */
export const electronCoreTestClockEnv = { COMMA_ELECTRON_E2E_CORE_TEST_CLOCK: "1" };

/**
 * Moves the core's clock `ms` forward. It stops at each core timer due on the way, lets what woke run, and waits for
 * Main's answers to what that work asked (requests, Main's ports) before it moves on; it resolves once all of it
 * settled. So the result is the same however fast the machine is, and no real time passes. A stream counts as
 * answered once it opened. Do not hold an answer the moved work waits for (a test's own pending IPC handler) across
 * a move: the move waits for it.
 */
export async function advanceCoreClock(
  app: ElectronApplication,
  ms: number
): Promise<void> {
  await app.evaluate((_electron, by) => {
    const core = (
      globalThis as {
        commaE2eCore?: { advanceClock(ms: number): Promise<void> };
      }
    ).commaE2eCore;
    if (!core) throw new Error("Launch the app with electronCoreTestClockEnv.");
    return core.advanceClock(by);
  }, ms);
}
