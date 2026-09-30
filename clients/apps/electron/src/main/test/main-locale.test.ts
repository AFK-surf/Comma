import { initializeCommaI18n, messages } from "@comma/i18n";
import { afterEach, describe, expect, it } from "vitest";
import { initializeElectronMainI18n } from "../main-locale";

afterEach(() => {
  initializeCommaI18n(["en"]);
});

describe("initializeElectronMainI18n", () => {
  it("prefers the Electron app locale selected by --lang over OS preferences", () => {
    expect(
      initializeElectronMainI18n({
        appLocale: "zh-CN",
        preferredSystemLanguages: ["en-US"],
      })
    ).toBe("zh-CN");
    expect(messages.nav_inbox()).toBe("收件箱");
  });

  it("keeps an English app locale ahead of a Simplified Chinese OS preference", () => {
    expect(
      initializeElectronMainI18n({
        appLocale: "en-US",
        preferredSystemLanguages: ["zh-CN"],
      })
    ).toBe("en");
    expect(messages.nav_inbox()).toBe("Inbox");
  });

  it("falls through an unsupported app locale to a supported OS preference", () => {
    expect(
      initializeElectronMainI18n({
        appLocale: "fr-FR",
        preferredSystemLanguages: ["zh-SG", "en-US"],
      })
    ).toBe("zh-CN");
  });

  it("localizes the shutdown-safety dialog in Electron Main", () => {
    expect(
      messages.electron_shutdown_blocked_title(
        { productName: "Comma" },
        { locale: "zh-CN" }
      )
    ).toBe("Comma 无法安全退出");
    expect(
      messages.electron_shutdown_blocked_detail(
        { productName: "Comma" },
        { locale: "zh-CN" }
      )
    ).toContain("应用将保持打开");
  });
});
