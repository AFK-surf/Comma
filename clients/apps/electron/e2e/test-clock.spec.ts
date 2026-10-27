import type { ElectronApplication } from "@playwright/test";
import {
  advanceTestClock,
  electronTestClockEnv,
} from "../../../e2e/helpers/electron-test-clock";
import { expect, test } from "./electron-test";

// Main's timers in an e2e that moves time itself stand still until the test moves the clocks: the core's restart
// after its process exits waits exactly its pause on Main's test clock, however fast or slow the machine is.
test.use({ sharedElectronEnv: electronTestClockEnv });

type E2eCore = { commaE2eCore?: { running(): boolean; crash(): Promise<void> } };

const coreRunning = (app: ElectronApplication) =>
  app.evaluate(() => (globalThis as E2eCore).commaE2eCore!.running());

const crashCore = (app: ElectronApplication) =>
  app.evaluate(() => (globalThis as E2eCore).commaE2eCore!.crash());

test(
  "the core restarts after its pause on Main's test clock",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app } }) => {
    // The first restart takes no pause, but still waits for the clock to move.
    await crashCore(app);
    expect(await coreRunning(app)).toBe(false);
    await advanceTestClock(app, 0);
    expect(await coreRunning(app)).toBe(true);

    // The second waits 1 s of the clock's time, not of the machine's.
    await crashCore(app);
    await advanceTestClock(app, 999);
    expect(await coreRunning(app)).toBe(false);
    await advanceTestClock(app, 1);
    expect(await coreRunning(app)).toBe(true);
  }
);
