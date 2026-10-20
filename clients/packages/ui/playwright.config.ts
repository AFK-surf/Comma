import { defineConfig, devices } from "@playwright/test";
import { browserNetworkArgs } from "../../../scripts/test-network-browser.mjs";

export default defineConfig({
  // CI scopes checkout credentials to its own fetch. Metadata must not fetch again.
  captureGitInfo: { commit: false, diff: false },
  testDir: "./e2e",
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: {
    timeout: 0,
  },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://127.0.0.1:6011",
    trace: "retain-on-failure",
    // Hosts other than this machine do not resolve (docs/testing.md#no-real-network).
    launchOptions: { args: browserNetworkArgs() },
  },
  webServer: {
    // CI serves the Storybook it already built; the dev server compiles each
    // story on first visit, which costs the first spec of every file seconds.
    command: process.env.STORYBOOK_E2E_STATIC
      ? "pnpm exec vite preview --outDir storybook-static --host 127.0.0.1 --port 6011 --strictPort"
      : "pnpm storybook:e2e",
    url: "http://127.0.0.1:6011",
    reuseExistingServer: false,
    timeout: 120_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
