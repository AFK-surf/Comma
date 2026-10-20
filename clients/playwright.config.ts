import { defineConfig, devices, type ReporterDescription } from "@playwright/test";
import { fileURLToPath } from "node:url";
import { browserNetworkArgs } from "../scripts/test-network-browser.mjs";
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
// Chromium resolves no host but this machine's (docs/testing.md#no-real-network).
const offlineChromium = {
  launchOptions: { args: browserNetworkArgs([new URL(webBaseURL).hostname]) },
};
const recordAll = process.env.COMMA_PLAYWRIGHT_RECORD_ALL === "1";
const realChatSmoke = process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE === "1";
// Tests do not retry. A failure keeps its screenshot and error-context.md in
// CI; recording a trace and video of every test costs Browser E2E about a
// third of its time, so CI records them only with PLAYWRIGHT_TRACE=1
// (for a replay of a failure). Local runs keep both for a failed test, and
// RECORD_ALL records every test.
const recordFailures = !process.env.CI || process.env.PLAYWRIGHT_TRACE === "1";
// A failure in CI keeps a trace of its actions, network and console without
// DOM snapshots or screencast, which cost little, so the failure can be read
// as it happened instead of rerun.
const failureTrace = {
  mode: "retain-on-failure",
  screenshots: false,
  snapshots: false,
  sources: false,
} as const;
const recordingMode = realChatSmoke
  ? "off"
  : recordAll
    ? "on"
    : recordFailures
      ? "retain-on-failure"
      : "off";
const electronScreenshot = realChatSmoke || !recordAll ? "off" : "on";
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
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: ".",
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops at the
  // test's limit. On CI that is two minutes, several times the slowest
  // passing test; a local machine can be far slower, so there it is ten.
  timeout: process.env.CI ? 120_000 : 600_000,
  expect: {
    timeout: 0,
  },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter,
  outputDir,
  use: {
    baseURL: webBaseURL,
    // Real provider content and its OTP must not be persisted in test artifacts.
    trace: recordingMode === "off" && !realChatSmoke ? failureTrace : recordingMode,
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
      use: { ...devices["Desktop Chrome"], ...offlineChromium },
    },
    {
      name: "app-shell",
      // Analytics owns its server.
      testIgnore: [
        /packages\/app\/e2e\/analytics\//,
        /packages\/app\/e2e\/compute-visual\//,
      ],
      testMatch: /packages\/app\/e2e\/.*\.spec\.ts/,
      // Specs split by test. A spec whose worker fixture builds or serves the
      // app keeps its tests on one worker, or shares one build across workers.
      fullyParallel: true,
      use: {
        ...devices["Desktop Chrome"],
        ...offlineChromium,
        viewport: { width: 1280, height: 800 },
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
      testMatch: /e2e\/app-shell\/.*\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        ...offlineChromium,
        viewport: { width: 1280, height: 800 },
      },
    },
    {
      name: "computer-use",
      testMatch: /apps\/electron\/e2e\/computer-use-permissions\.spec\.ts/,
    },
    // The tests on a worker's shared app (`sharedElectron`, tagged @shared-app) run
    // together, so the app launches once for them; the rest launch their own.
    // Playwright's failure screenshot is taken of every window each time an app
    // closes, passed or not, and waits 5 s for a window that draws no frame (a
    // hidden one); the Electron framework screenshots a failed test's windows
    // itself (`electronFailureDiagnostics`).
    {
      name: "electron-shell-shared",
      dependencies: ["electron-runtime-setup"],
      testMatch: /apps\/electron\/e2e\/.*\.spec\.ts/,
      testIgnore: /computer-use-permissions\.spec\.ts/,
      grep: /@shared-app/,
      use: { screenshot: electronScreenshot },
    },
    {
      name: "electron-shell",
      dependencies: ["electron-runtime-setup"],
      testMatch: /apps\/electron\/e2e\/.*\.spec\.ts/,
      testIgnore: /computer-use-permissions\.spec\.ts/,
      grepInvert: /@shared-app/,
      use: { screenshot: electronScreenshot },
    },
    {
      name: "web",
      testMatch: /e2e\/p0\/(web-smoke|oauth-resume)\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        ...offlineChromium,
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
