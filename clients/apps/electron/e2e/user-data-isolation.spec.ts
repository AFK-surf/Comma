import { existsSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./electron-test";

// Every e2e that boots Main passes --user-data-dir=<tmp> so the seeded SQLite DB,
// SecureStore, Chromium session data, and logs never touch the developer's real
// profile. This guards that the explicit pointer remains the single runtime root
// even though normal launches derive their root from the release flavor. Mutation
// that turns it red: ignore the command-line override during runtime bootstrap —
// the DB and logs then land in the flavor's real Application Support directory.
// The shared app is launched with such a pointer (`sharedElectron.userDataDir`).
test(
  "the declared --user-data-dir owns database and log state",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const { app, userDataDir } = sharedElectron;
    expect(
      await app.evaluate(({ app: nativeApp }) => nativeApp.getPath("userData"))
    ).toBe(userDataDir);
    await expect
      .poll(() => ({
        database: existsSync(join(userDataDir, "core", "device.sqlite")),
        logs: existsSync(join(userDataDir, "logs")),
      }))
      .toEqual({ database: true, logs: true });
  }
);
