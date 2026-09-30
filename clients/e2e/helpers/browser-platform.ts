import type { Page } from "@playwright/test";

export type BrowserPlatform = "linux" | "macos" | "windows";

const platformHints: Record<
  BrowserPlatform,
  { platform: string; userAgent: string; userAgentDataPlatform: string }
> = {
  linux: {
    platform: "Linux x86_64",
    userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140",
    userAgentDataPlatform: "Linux",
  },
  macos: {
    platform: "MacIntel",
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/140",
    userAgentDataPlatform: "macOS",
  },
  windows: {
    platform: "Win32",
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140",
    userAgentDataPlatform: "Windows",
  },
};

export const installBrowserPlatform = async (page: Page, platform: BrowserPlatform) => {
  await page.addInitScript((hints) => {
    Object.defineProperties(navigator, {
      platform: { configurable: true, value: hints.platform },
      userAgent: { configurable: true, value: hints.userAgent },
      userAgentData: {
        configurable: true,
        value: { platform: hints.userAgentDataPlatform },
      },
    });
  }, platformHints[platform]);
};
