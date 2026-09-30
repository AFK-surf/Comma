import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import {
  formatNumber,
  initializeCommaI18n,
  legacyCommaLocaleStorageKey,
  messages,
  readLegacyCommaLocalePreference,
  resolveLocale,
  resolveLocalePreference,
  taskActivityLabel,
} from "../index";
import { CommaI18nProvider, useCommaI18n, useCommaMessages } from "../react";

function LocaleProbe() {
  const { locale, localePreference, setLocalePreference } = useCommaI18n();
  const localizedMessages = useCommaMessages();
  return (
    <>
      <span>
        {locale}:{localePreference}:{localizedMessages.nav_settings()}
      </span>
      <button onClick={() => setLocalePreference("zh-CN")} type="button">
        中文
      </button>
    </>
  );
}

afterEach(() => {
  initializeCommaI18n(["en"]);
  localStorage.clear();
});

describe("resolveLocale", () => {
  it.each([
    "zh-CN",
    "zh-CN-u-nu-hanidec",
    "zh-SG",
    "zh-SG-x-test",
    "zh-Hans",
    "zh-Hans-CN",
  ])("maps %s to Simplified Chinese", (language) => {
    expect(resolveLocale([language])).toBe("zh-CN");
  });

  it.each(["zh-TW", "zh-HK", "zh-Hant", "fr-FR", "ja-JP"])(
    "falls back to English for %s",
    (language) => {
      expect(resolveLocale([language])).toBe("en");
    }
  );

  it.each([
    ["uses the first supported browser preference", ["fr-FR", "zh-SG", "en-US"]],
    ["continues after an unsupported Chinese preference", ["zh-TW", "zh-CN", "en-US"]],
  ])("%s", (_name, languages) => {
    expect(resolveLocale(languages)).toBe("zh-CN");
  });
});

describe("initializeCommaI18n", () => {
  it.each(
    [
      {
        name: "sets the generated message locale and document language",
        language: "zh-CN",
        expected: "zh-CN",
        inbox: "收件箱",
      },
      {
        name: "uses English for an unsupported browser language",
        language: "fr-FR",
        expected: "en",
        inbox: "Inbox",
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { language, expected, inbox }) => {
    expect(initializeCommaI18n([language])).toBe(expected);
    expect(document.documentElement.lang).toBe(expected);
    expect(messages.nav_inbox()).toBe(inbox);
  });

  it("leaves an unchanged document language untouched", () => {
    initializeCommaI18n(["zh-CN"]);
    const writes: MutationRecord[] = [];
    const observer = new MutationObserver((records) => writes.push(...records));
    observer.observe(document.documentElement, { attributeFilter: ["lang"] });
    initializeCommaI18n(["zh-CN"]);
    writes.push(...observer.takeRecords());
    observer.disconnect();
    expect(writes).toHaveLength(0);
  });

  it("keeps the page's own document language when asked to", () => {
    document.documentElement.lang = "ja";
    expect(initializeCommaI18n(["en"], { documentLanguage: false })).toBe("en");
    expect(document.documentElement.lang).toBe("ja");
    expect(messages.nav_inbox()).toBe("Inbox");
    render(
      <CommaI18nProvider documentLanguage={false} locale="zh-CN">
        <LocaleProbe />
      </CommaI18nProvider>
    );
    expect(screen.getByText(/^zh-CN:/)).toBeTruthy();
    expect(document.documentElement.lang).toBe("ja");
  });

  it("formats count-sensitive messages in both locales", () => {
    initializeCommaI18n(["en"]);
    expect(messages.side_chat_task_count({ count: 1, formattedCount: "1" })).toBe(
      "1 task"
    );
    expect(messages.side_chat_task_count({ count: 2, formattedCount: "2" })).toBe(
      "2 tasks"
    );
    expect(messages.chat_new_messages({ count: 1, formattedCount: "1" })).toBe(
      "1 new message"
    );
    expect(messages.chat_new_messages({ count: 2, formattedCount: "2" })).toBe(
      "2 new messages"
    );
    expect(
      messages.side_chat_task_count({
        count: 10_000,
        formattedCount: formatNumber(10_000, "en"),
      })
    ).toBe("10,000 tasks");

    initializeCommaI18n(["zh-CN"]);
    expect(messages.side_chat_task_count({ count: 1, formattedCount: "1" })).toBe(
      "1 个任务"
    );
    expect(messages.side_chat_task_count({ count: 2, formattedCount: "2" })).toBe(
      "2 个任务"
    );
    expect(messages.chat_new_messages({ count: 1, formattedCount: "1" })).toBe(
      "1 条新消息"
    );
    expect(messages.chat_new_messages({ count: 2, formattedCount: "2" })).toBe(
      "2 条新消息"
    );
    expect(
      messages.side_chat_task_count({
        count: 10_000,
        formattedCount: formatNumber(10_000, "zh-CN"),
      })
    ).toBe("10,000 个任务");
  });

  it("localizes known task activity phases without exposing raw enums", () => {
    expect(taskActivityLabel("thinking", "zh-CN")).toBe("思考中");
    expect(taskActivityLabel("running_tests", "zh-CN")).toBe("正在运行测试");
    expect(taskActivityLabel("completed", "zh-CN")).toBe("已完成");
    expect(taskActivityLabel("future_phase", "zh-CN")).toBe("状态未知");
    expect(taskActivityLabel("idle", "zh-CN")).toBeUndefined();
  });
});

describe("locale preferences", () => {
  it("reads an explicit locale from the legacy migration key", () => {
    expect(readLegacyCommaLocalePreference()).toBe("system");

    localStorage.setItem(legacyCommaLocaleStorageKey, "zh-CN");
    expect(readLegacyCommaLocalePreference()).toBe("zh-CN");
    expect(resolveLocalePreference("zh-CN")).toBe("zh-CN");
  });

  it("ignores an unsupported stored locale", () => {
    localStorage.setItem(legacyCommaLocaleStorageKey, "fr");
    expect(readLegacyCommaLocalePreference()).toBe("system");
  });
});

describe("CommaI18nProvider", () => {
  it("owns the generated locale for standalone renderer roots", () => {
    render(
      <CommaI18nProvider locale="zh-CN">
        <LocaleProbe />
      </CommaI18nProvider>
    );

    expect(screen.getByText("zh-CN:zh-CN:设置")).toBeTruthy();
    expect(document.documentElement.lang).toBe("zh-CN");
  });

  it("updates the generated locale when the renderer locale changes", () => {
    const view = render(
      <CommaI18nProvider locale="en">
        <LocaleProbe />
      </CommaI18nProvider>
    );
    expect(screen.getByText("en:en:Settings")).toBeTruthy();

    view.rerender(
      <CommaI18nProvider locale="zh-CN">
        <LocaleProbe />
      </CommaI18nProvider>
    );

    expect(screen.getByText("zh-CN:zh-CN:设置")).toBeTruthy();
    expect(document.documentElement.lang).toBe("zh-CN");
  });

  it("updates an uncontrolled renderer locale in memory", async () => {
    render(
      <CommaI18nProvider>
        <LocaleProbe />
      </CommaI18nProvider>
    );

    expect(screen.getByText("en:system:Settings")).toBeTruthy();
    screen.getByRole("button", { name: "中文" }).click();

    expect(await screen.findByText("zh-CN:zh-CN:设置")).toBeTruthy();
    expect(localStorage.getItem(legacyCommaLocaleStorageKey)).toBeNull();
    expect(document.documentElement.lang).toBe("zh-CN");
  });
});
