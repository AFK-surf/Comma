import { defineConfig, devices } from "@playwright/test";
import { resolve } from "node:path";
import { browserNetworkArgs } from "../../../../../scripts/test-network-browser.mjs";
import { posthogHost, websiteOrigin } from "./posthog-capture";

export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: ".",
  testMatch: "posthog.spec.ts",
  outputDir: resolve(
    import.meta.dirname,
    "../../../../test-results/playwright-analytics"
  ),
  reporter: [
    ["list"],
    [
      "html",
      {
        outputFolder: resolve(
          import.meta.dirname,
          "../../../../playwright-report/analytics"
        ),
        open: "never",
      },
    ],
  ],
  workers: 1,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: { timeout: 0 },
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://127.0.0.1:4187",
    viewport: { width: 1280, height: 800 },
    // Hosts other than this machine do not resolve (docs/testing.md#no-real-network).
    launchOptions: { args: browserNetworkArgs() },
  },
  webServer: [
    {
      cwd: resolve(import.meta.dirname, "../../../../.."),
      // A development-server reload creates another document and pageview.
      // Keep the real SDK on a stable build with its own analytics configuration.
      command:
        "env -u COMMA_POSTHOG_KEY -u COMMA_SELFHOST_BUILD pnpm --filter @comma/web exec vite build --config ../../packages/app/e2e/analytics/vite.config.ts --configLoader runner --outDir ../../test-results/analytics-web && pnpm --filter @comma/web exec vite preview --configLoader runner --outDir ../../test-results/analytics-web --host 127.0.0.1 --port 4187 --strictPort",
      env: {
        // Exercise the hosted build with no injected project token. Only the
        // collector changes, so test events cannot reach the real project.
        COMMA_BUILD_FLAVOR: "prod",
        COMMA_POSTHOG_HOST: posthogHost,
      },
      url: "http://127.0.0.1:4187",
      reuseExistingServer: false,
      timeout: 120_000,
    },
    {
      cwd: resolve(import.meta.dirname, "../../../../.."),
      // The site as built, like the app above: a development server compiles pages on first load and may reload them.
      command: `pnpm --filter @comma/website exec vite build --outDir ../clients/test-results/analytics-website --emptyOutDir && pnpm --filter @comma/website exec vite preview --outDir ../clients/test-results/analytics-website --host 127.0.0.1 --port ${new URL(websiteOrigin).port} --strictPort`,
      env: {
        COMMA_BUILD_FLAVOR: "prod",
        COMMA_POSTHOG_KEY: "phc_nSEHiHpAFnzfmkiQyatA5KinuGxPsFzCAp94xdg8C2sv",
        COMMA_POSTHOG_HOST: posthogHost,
      },
      url: websiteOrigin,
      reuseExistingServer: false,
      timeout: 120_000,
    },
  ],
});
