import { defineConfig, devices, type ReporterDescription } from "@playwright/test";

const baseURL = process.env.COMMA_ADMIN_PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4175";
const skipWebServer = process.env.COMMA_ADMIN_PLAYWRIGHT_SKIP_WEB_SERVER === "1";
const reporter = process.env.CI
  ? ([
      ["github"],
      [
        "html",
        {
          outputFolder: "../../playwright-report/admin",
          open: "never",
        },
      ],
      [
        "json",
        {
          outputFile: "../../playwright-report/admin/results.json",
        },
      ],
    ] satisfies ReporterDescription[])
  : "list";
const localNoProxyHosts = ["127.0.0.1", "localhost", "::1"];
const existingNoProxy = process.env.NO_PROXY || process.env.no_proxy || "";
const noProxyHosts = new Set(
  existingNoProxy
    .split(",")
    .map((host) => host.trim())
    .filter(Boolean)
);

for (const host of localNoProxyHosts) {
  noProxyHosts.add(host);
}
process.env.NO_PROXY = Array.from(noProxyHosts).join(",");
process.env.no_proxy = process.env.NO_PROXY;

export default defineConfig({
  testDir: "./e2e",
  timeout: 45_000,
  expect: {
    timeout: 8_000,
  },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter,
  outputDir: "../../test-results/playwright-admin",
  use: {
    ...devices["Desktop Chrome"],
    baseURL,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
    viewport: { width: 1280, height: 800 },
  },
  ...(skipWebServer
    ? {}
    : {
        webServer: {
          command:
            "COMMA_BUILD_FLAVOR=dev pnpm exec vite preview --configLoader runner --host 127.0.0.1 --port 4175 --strictPort",
          reuseExistingServer: false,
          stderr: "pipe" as const,
          stdout: "ignore" as const,
          timeout: 120_000,
          url: baseURL,
        },
      }),
});
