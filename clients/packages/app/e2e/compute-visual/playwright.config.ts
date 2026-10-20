import { defineConfig } from "@playwright/test";
import { browserNetworkArgs } from "../../../../../scripts/test-network-browser.mjs";
export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: import.meta.dirname,
  testMatch: "visual.spec.ts",
  workers: 1,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: { timeout: 0 },
  outputDir: "../../../../test-results/playwright/compute-visual",
  use: {
    baseURL: "http://127.0.0.1:4175",
    viewport: { width: 1100, height: 1000 },
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    // Hosts other than this machine do not resolve (docs/testing.md#no-real-network).
    launchOptions: { args: browserNetworkArgs() },
  },
  webServer: {
    // The page as built (`pnpm test:e2e:compute-visual` builds it first): nothing is compiled while a test loads it.
    command:
      "pnpm --filter @comma/web exec vite preview --configLoader runner --config ../../packages/app/e2e/compute-visual/vite.config.ts --outDir ../../../../test-results/compute-visual-web --host 127.0.0.1 --port 4175 --strictPort",
    url: "http://127.0.0.1:4175/preview.html",
    reuseExistingServer: false,
  },
});
