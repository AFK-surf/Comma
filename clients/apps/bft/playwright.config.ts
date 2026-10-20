import { defineConfig, devices } from "@playwright/test";
import { browserNetworkArgs } from "../../../scripts/test-network-browser.mjs";

const baseURL = process.env.COMMA_BFT_PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4176";

// Browser tests for the BFT dashboard SPA. The API is stubbed per test with
// page.route, so the real client (fetch, zod parsing, routing) runs unchanged.
export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: "./e2e",
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: { timeout: 0 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: process.env.CI ? "github" : "list",
  outputDir: "../../test-results/playwright-bft",
  use: {
    ...devices["Desktop Chrome"],
    baseURL,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    viewport: { width: 1280, height: 800 },
    // Hosts other than this machine do not resolve (docs/testing.md#no-real-network).
    launchOptions: { args: browserNetworkArgs([new URL(baseURL).hostname]) },
  },
  webServer: {
    // A build, served as built: nothing is compiled while a test loads a page. At the origin root (`--base /`), as
    // the development server served it: the SPA routes are there, as Phoenix serves them.
    command:
      "pnpm exec vite build --configLoader runner --base / --outDir ../../test-results/bft-web --emptyOutDir && pnpm exec vite preview --configLoader runner --base / --outDir ../../test-results/bft-web --host 127.0.0.1 --port 4176 --strictPort",
    reuseExistingServer: false,
    stderr: "pipe",
    stdout: "ignore",
    timeout: 120_000,
    url: baseURL,
  },
});
