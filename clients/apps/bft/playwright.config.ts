import { defineConfig, devices } from "@playwright/test";

const baseURL = process.env.COMMA_BFT_PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4176";

// Browser tests for the BFT dashboard SPA. The API is stubbed per test with
// page.route, so the real client (fetch, zod parsing, routing) runs unchanged.
export default defineConfig({
  testDir: "./e2e",
  timeout: 45_000,
  expect: { timeout: 8_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  outputDir: "../../test-results/playwright-bft",
  use: {
    ...devices["Desktop Chrome"],
    baseURL,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    viewport: { width: 1280, height: 800 },
  },
  webServer: {
    command: "pnpm exec vite --host 127.0.0.1 --port 4176 --strictPort",
    reuseExistingServer: false,
    stderr: "pipe",
    stdout: "ignore",
    timeout: 120_000,
    url: baseURL,
  },
});
