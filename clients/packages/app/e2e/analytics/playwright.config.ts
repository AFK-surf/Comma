import { defineConfig, devices } from "@playwright/test";
import { resolve } from "node:path";

export default defineConfig({
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
  timeout: 45_000,
  expect: { timeout: 10_000 },
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://127.0.0.1:4187",
    viewport: { width: 1280, height: 800 },
  },
  webServer: {
    cwd: resolve(import.meta.dirname, "../../../../.."),
    // A development-server reload creates another document and pageview.
    // Keep the real SDK on a stable build with its own analytics configuration.
    command:
      "pnpm --filter @comma/web exec vite build --config ../../packages/app/e2e/analytics/vite.config.ts --configLoader runner --outDir ../../test-results/analytics-web && pnpm --filter @comma/web exec vite preview --configLoader runner --outDir ../../test-results/analytics-web --host 127.0.0.1 --port 4187 --strictPort",
    env: {
      COMMA_BUILD_FLAVOR: "dev",
      COMMA_POSTHOG_KEY: "phc_comma_analytics_e2e",
      COMMA_POSTHOG_HOST: "https://posthog.comma.test",
    },
    url: "http://127.0.0.1:4187",
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
