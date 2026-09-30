import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// Every e2e that boots Main passes --user-data-dir=<tmp> so the seeded SQLite DB,
// SecureStore, Chromium session data, and logs never touch the developer's real
// profile. This guards that the explicit pointer remains the single runtime root
// even though normal launches derive their root from the release flavor. Mutation
// that turns it red: ignore the command-line override during runtime bootstrap —
// the DB and logs then land in the flavor's real Application Support directory.
// The tmp dir lives on hooks so it is cleaned up even if launch throws before the
// test body runs.
test.describe("electron userData isolation", () => {
  let userDataDir: string;

  test.beforeEach(async () => {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-userdata-e2e-"));
  });

  test.afterEach(async () => {
    await rm(userDataDir, { force: true, recursive: true });
  });

  test("the declared --user-data-dir owns database and log state", async () => {
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...process.env, NODE_ENV: "test" },
    });
    try {
      // The first window can become visible before the local-data utility has
      // finished opening its database, so wait for both owned paths.
      await app.firstWindow();
      await expect
        .poll(() => ({
          database: existsSync(join(userDataDir, "comma.sqlite")),
          logs: existsSync(join(userDataDir, "logs")),
        }))
        .toEqual({ database: true, logs: true });
    } finally {
      await app.close();
    }
  });
});
