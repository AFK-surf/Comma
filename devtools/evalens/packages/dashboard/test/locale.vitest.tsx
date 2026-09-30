import { fireEvent, render, screen } from "@testing-library/react";
import { memo, useState } from "react";
import { afterEach, describe, expect, it } from "vitest";
import {
  LOCALE_STORAGE_KEY,
  LocaleMenu,
  LocaleProvider,
  resolveLocale,
  useLocale,
  useMessages,
} from "../src/i18n/locale";
import { setLocale } from "../src/paraglide/runtime.js";

afterEach(() => {
  localStorage.clear();
  setLocale("en", { reload: false });
  document.documentElement.lang = "en";
});

describe("dashboard locale", () => {
  it("maps supported Simplified Chinese locales and falls back safely", () => {
    for (const locale of ["zh-CN", "zh-SG", "zh-Hans", "zh-Hans-CN"]) {
      expect(resolveLocale(null, [locale])).toBe("zh-CN");
    }
    for (const locale of ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "fr-FR"]) {
      expect(resolveLocale(null, [locale])).toBe("en");
    }
  });

  it("gives a valid stored choice priority over browser languages", () => {
    expect(resolveLocale("en", ["zh-CN"])).toBe("en");
    expect(resolveLocale("zh-CN", ["en-US"])).toBe("zh-CN");
    expect(resolveLocale("broken", ["zh-CN"])).toBe("zh-CN");
    expect(resolveLocale("broken", ["fr-FR"])).toBe("en");
  });

  it("immediately rerenders the visible page without reload or remounting", () => {
    localStorage.setItem(LOCALE_STORAGE_KEY, "en");
    localStorage.setItem(
      "evalens.compare-selection",
      JSON.stringify({ version: 1, evalIds: ["eval-a", "eval-b"] })
    );
    history.replaceState({}, "", "/compare?eval=eval-a&eval=eval-b&reference=eval-a");
    render(
      <LocaleProvider>
        <AppShellProbe />
      </LocaleProvider>
    );
    expect(screen.getByText("Runs / Compare evaluations / 2 selected")).toBeVisible();
    expect(document.documentElement.lang).toBe("en");
    fireEvent.change(screen.getByLabelText("persistent state"), {
      target: { value: "kept" },
    });
    fireEvent.click(screen.getByLabelText("Change language"));
    fireEvent.click(screen.getByRole("menuitemradio", { name: "简体中文" }));
    expect(screen.getByText("运行 / 对比评估 / 已选择 2 项")).toBeVisible();
    expect(screen.getByLabelText("persistent state")).toHaveValue("kept");
    expect(localStorage.getItem(LOCALE_STORAGE_KEY)).toBe("zh-CN");
    expect(document.documentElement.lang).toBe("zh-CN");
    expect(location.pathname + location.search).toBe(
      "/compare?eval=eval-a&eval=eval-b&reference=eval-a"
    );
    expect(localStorage.getItem("evalens.compare-selection")).toContain("eval-b");
  });
});

function AppShellProbe() {
  const { locale } = useLocale();
  return (
    <div data-locale={locale}>
      <MemoizedLocaleProbe />
    </div>
  );
}

function LocaleProbe() {
  const m = useMessages();
  const [value, setValue] = useState("");
  return (
    <div>
      <LocaleMenu />
      <p>
        {m.runs_title()} / {m.compare_title()} / {m.tray_selected({ count: 2 })}
      </p>
      <input
        aria-label="persistent state"
        onChange={(event) => setValue(event.target.value)}
        value={value}
      />
    </div>
  );
}

const MemoizedLocaleProbe = memo(LocaleProbe);
