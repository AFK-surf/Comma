import { defineConfig } from "@playwright/test";
import { browserNetworkArgs } from "../../../../scripts/test-network-browser.mjs";

const baseURL = process.env.COMMA_SELFHOST_URL || "http://localhost:8080";

export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: ".",
  testMatch:
    process.env.COMMA_SELFHOST_RESTART === "true"
      ? "selfhost.restart.ts"
      : "selfhost.smoke.ts",
  outputDir: "../test-results/selfhost",
  workers: 1,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: { timeout: 0 },
  use: {
    baseURL,
    headless: true,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    // Hosts other than this machine do not resolve (docs/testing.md#no-real-network).
    launchOptions: { args: browserNetworkArgs([new URL(baseURL).hostname]) },
  },
});
