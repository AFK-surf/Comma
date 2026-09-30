import { defineConfig, devices } from "@playwright/test";

// The dashboard server is booted separately with config.json enabling the
// non-prod dev-login bypass (see e2e/README.md and the CI job).
// Tests authenticate via the guarded /dev/login bypass. Serial + single worker:
// the suite shares one seeded org and mutates it.
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
    baseURL: process.env.E2E_BASE_URL || "http://127.0.0.1:4101",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 7_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
