import { defineConfig, devices, type ReporterDescription } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { webBaseURL } from "./e2e/p0/smoke-env";

// Electron has no Playwright headless launch option. The app consumes this
// explicit test flag to use BrowserWindow.showInactive() and the macOS
// accessory activation policy while retaining a real, painted native window.
process.env.COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS ??= "1";

// Most Electron E2E scenarios do not need a real salix-connect child. Keep
// that fixture choice explicit and independently overridable by tests that
// exercise production Connector supervision.
process.env.COMMA_ELECTRON_E2E_CONNECTOR_MODE ??= "static";

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

const skipWebServer = process.env.COMMA_PLAYWRIGHT_SKIP_WEB_SERVER === "1";
const recordAll = process.env.COMMA_PLAYWRIGHT_RECORD_ALL === "1";
const realChatSmoke = process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE === "1";
// Avoid recording every successful CI attempt. Failure screenshots remain on;
// the existing first retry captures the trace/video, and RECORD_ALL is unchanged.
const recordingMode = realChatSmoke
  ? "off"
  : recordAll
    ? "on"
    : process.env.CI
      ? "on-first-retry"
      : "retain-on-failure";
const reportDir = process.env.COMMA_PLAYWRIGHT_REPORT_DIR;
const jsonReportFile = process.env.COMMA_PLAYWRIGHT_JSON_REPORT_FILE;
const outputDir = process.env.COMMA_PLAYWRIGHT_OUTPUT_DIR ?? "test-results/playwright";
const reporter = reportDir
  ? ([
      ["list"],
      ["html", { outputFolder: reportDir, open: "never" }],
      ...(jsonReportFile
        ? ([["json", { outputFile: jsonReportFile }]] satisfies ReporterDescription[])
        : []),
    ] satisfies ReporterDescription[])
  : process.env.CI
    ? ([
        ["github"],
        ["list"],
        [
          fileURLToPath(
            new URL("./e2e/helpers/runner-metrics-reporter.ts", import.meta.url)
          ),
        ],
      ] satisfies ReporterDescription[])
    : "list";
const webServer = skipWebServer
  ? {}
  : {
      webServer: {
        command:
          "pnpm --filter @comma/web exec vite preview --configLoader runner --host 127.0.0.1 --port 4173",
        url: webBaseURL,
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
        stdout: "ignore" as const,
        stderr: "pipe" as const,
      },
    };

export default defineConfig({
  testDir: ".",
  timeout: 45_000,
  expect: {
    timeout: 8_000,
  },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter,
  outputDir,
  use: {
    baseURL: webBaseURL,
    // Real provider content and its OTP must not be persisted in test artifacts.
    trace: recordingMode,
    screenshot: realChatSmoke ? "off" : recordAll ? "on" : "only-on-failure",
    video: recordingMode,
  },
  ...webServer,
  projects: [
    {
      name: "electron-runtime-setup",
      testMatch: /e2e\/setup\/electron-runtime\.setup\.ts/,
    },
    {
      name: "web-chromium",
      testMatch: /apps\/[^/]+\/test\/.*\.spec\.ts/,
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "app-shell",
      // Analytics owns its server; wall-clock benchmarks run separately in CI.
      testIgnore: [
        /packages\/app\/e2e\/analytics\//,
        /packages\/app\/e2e\/(inbox|chat-task-panel|drive|plugins|session-history|task-workspace|theme-studio)-performance\.spec\.ts/,
      ],
      testMatch: /packages\/app\/e2e\/.*\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: "app-shell-performance",
      testMatch: [
        /packages\/app\/e2e\/(inbox|chat-task-panel|drive|plugins|session-history|task-workspace|theme-studio)-performance\.spec\.ts/,
        /e2e\/app-shell\/markdown-stream\.spec\.ts/,
      ],
      grep: /(inbox|chat-task-panel|drive|plugins|session-history|task-workspace|theme-studio)-performance\.spec\.ts|@frame-budget/,
      workers: 1,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 800 },
        // Recording changes the wall-clock timings this project measures.
        trace: "off",
        video: "off",
      },
    },
    {
      name: "app-shell-firefox-icon-geometry",
      testMatch: /packages\/app\/e2e\/shell-layout\.spec\.ts/,
      grep: /font size preference scales core conversation typography without changing icon geometry/,
      use: {
        ...devices["Desktop Firefox"],
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: "app-shell-regression",
      grepInvert: /@frame-budget/,
      testMatch: /e2e\/app-shell\/.*\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: "computer-use",
      testMatch: /apps\/electron\/e2e\/computer-use-permissions\.spec\.ts/,
    },
    {
      name: "electron-shell",
      dependencies: ["electron-runtime-setup"],
      testMatch: /apps\/electron\/e2e\/.*\.spec\.ts/,
      testIgnore: /computer-use-permissions\.spec\.ts/,
    },
    {
      name: "web",
      testMatch: /e2e\/p0\/(web-smoke|oauth-resume)\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: "electron",
      dependencies: ["electron-runtime-setup"],
      testMatch: /e2e\/p0\/electron-smoke\.spec\.ts/,
    },
    {
      name: "electron-packaged",
      dependencies: ["electron-runtime-setup"],
      testMatch: /e2e\/p0\/electron-packaged-smoke\.spec\.ts/,
    },
  ],
});
