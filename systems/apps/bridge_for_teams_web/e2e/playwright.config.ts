import { defineConfig, devices } from "@playwright/test";

// The dashboard server is booted separately with config.json enabling the
// non-prod dev-login bypass (see e2e/README.md and the CI job).
// Tests authenticate via the guarded /dev/login bypass. Serial + single worker:
// the suite shares one seeded org and mutates it.
export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after 60
  // seconds. The slowest test takes under 10 seconds; the seed and the
  // server start run before Playwright, outside this limit.
  timeout: 60_000,
  expect: { timeout: 0 },
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: process.env.E2E_BASE_URL || "http://127.0.0.1:4101",
    // The browser reaches only the local server: every other host fails to
    // resolve at once, so no page waits on the internet (the dashboard's web
    // font, for one) and a test never depends on it.
    launchOptions: {
      args: [
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
      ],
    },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 7_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
