import { defineConfig, devices } from "@playwright/test";

// The Salix dashboard shares the API's Bandit listener on :4000 (the /dash
// prefix is dispatched to a server:false Phoenix endpoint). Boot it separately
// (see e2e/README.md and the CI job), with config.json containing a known
// web.api_token.
// Tests authenticate by pasting that token into the real login form. Serial +
// single worker: the suite builds up shared state (tenant/template/group/agent).
export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 30_000,
  expect: { timeout: 7_000 },
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: process.env.E2E_BASE_URL || "http://127.0.0.1:4000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 7_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
