import { defineConfig, devices } from "@playwright/test";

// The Salix dashboard shares the API's Bandit listener on :4000 (the /dash
// prefix is dispatched to a server:false Phoenix endpoint). Boot it separately
// (see e2e/README.md and the CI job), with config.json containing a known
// web.api_token.
// Tests authenticate by pasting that token into the real login form. Serial +
// single worker: the suite builds up shared state (tenant/group/agent).
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
    baseURL: process.env.E2E_BASE_URL || "http://127.0.0.1:4000",
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
