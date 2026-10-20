import type { TestInfo } from "@playwright/test";

// electron.launch() does not inherit Playwright's context video policy.
// Follow the suite's recording rule: CI records only with
// PLAYWRIGHT_TRACE=1 or COMMA_PLAYWRIGHT_RECORD_ALL=1.
export function electronVideoOptions(testInfo: TestInfo): {
  recordVideo?: { dir: string; size: { width: number; height: number } };
} {
  if (process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE === "1") return {};
  if (
    process.env.CI &&
    process.env.COMMA_PLAYWRIGHT_RECORD_ALL !== "1" &&
    process.env.PLAYWRIGHT_TRACE !== "1"
  ) {
    return {};
  }
  return {
    recordVideo: {
      dir: testInfo.outputPath("electron-video"),
      size: { width: 1280, height: 800 },
    },
  };
}
