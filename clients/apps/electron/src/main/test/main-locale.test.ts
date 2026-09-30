import { initializeCommaI18n, messages } from "@comma/i18n";
import { afterEach, describe, expect, it } from "vitest";
import { initializeElectronMainI18n } from "../main-locale";

afterEach(() => {
  initializeCommaI18n(["en"]);
});

describe("initializeElectronMainI18n", () => {
  it.each(
    [
      {
        name: "prefers the Electron app locale selected by --lang over OS preferences",
        appLocale: "zh-CN",
        preferredSystemLanguages: ["en-US"],
        expected: "zh-CN",
        inbox: "收件箱",
      },
      {
        name: "keeps an English app locale ahead of a Simplified Chinese OS preference",
        appLocale: "en-US",
        preferredSystemLanguages: ["zh-CN"],
        expected: "en",
        inbox: "Inbox",
      },
      {
        name: "falls through an unsupported app locale to a supported OS preference",
        appLocale: "fr-FR",
        preferredSystemLanguages: ["zh-SG", "en-US"],
        expected: "zh-CN",
        inbox: "收件箱",
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { appLocale, preferredSystemLanguages, expected, inbox }) => {
    expect(initializeElectronMainI18n({ appLocale, preferredSystemLanguages })).toBe(
      expected
    );
    expect(messages.nav_inbox()).toBe(inbox);
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
