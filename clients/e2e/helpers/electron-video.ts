import type { TestInfo } from "@playwright/test";

// electron.launch() does not inherit Playwright's context video policy.
// Keep explicit launches aligned with the suite's first-retry CI recording.
export function electronVideoOptions(testInfo: TestInfo): {
  recordVideo?: { dir: string; size: { width: number; height: number } };
} {
  if (process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE === "1") return {};
  if (
    process.env.CI &&
    process.env.COMMA_PLAYWRIGHT_RECORD_ALL !== "1" &&
    testInfo.retry !== 1
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
