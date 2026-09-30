import { Check, Globe } from "lucide-react";
import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import { m } from "../paraglide/messages.js";
import { setLocale as setParaglideLocale } from "../paraglide/runtime.js";

export type AppLocale = "en" | "zh-CN";
export const LOCALE_STORAGE_KEY = "evalens.locale";

type LocaleContextValue = {
  locale: AppLocale;
  setLocale(locale: AppLocale): void;
};

const LocaleContext = createContext<LocaleContextValue | null>(null);

export function resolveLocale(
  stored: string | null,
  browserLanguages: readonly string[]
): AppLocale {
  if (stored === "en" || stored === "zh-CN") return stored;
  for (const language of browserLanguages) {
    const normalized = language.toLowerCase();
    if (
      normalized === "zh-cn" ||
      normalized === "zh-sg" ||
      normalized === "zh-hans" ||
      normalized.startsWith("zh-hans-")
    )
      return "zh-CN";
    if (normalized.startsWith("zh")) return "en";
    if (normalized === "en" || normalized.startsWith("en-")) return "en";
  }
  return "en";
}

export function detectLocale(): AppLocale {
  let stored: string | null = null;
  try {
    stored = globalThis.localStorage?.getItem(LOCALE_STORAGE_KEY) ?? null;
  } catch {
    // Storage may be unavailable in private or embedded contexts.
  }
  const languages = globalThis.navigator
    ? [...(navigator.languages ?? []), navigator.language].filter(Boolean)
    : [];
  return resolveLocale(stored, languages);
}

export function LocaleProvider({ children }: { children: ReactNode }) {
  const [locale, updateLocale] = useState<AppLocale>(() => {
    const detected = detectLocale();
    setParaglideLocale(detected, { reload: false });
    if (globalThis.document) document.documentElement.lang = detected;
    return detected;
  });
  const value = useMemo<LocaleContextValue>(
    () => ({
      locale,
      setLocale(next) {
        setParaglideLocale(next, { reload: false });
        document.documentElement.lang = next;
        try {
          localStorage.setItem(LOCALE_STORAGE_KEY, next);
        } catch {
          // Storage may be unavailable in private or embedded contexts.
        }
        updateLocale(next);
      },
    }),
    [locale]
  );
  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

export function useLocale() {
  const value = useContext(LocaleContext);
  if (!value) throw new Error("useLocale must be used inside LocaleProvider");
  return value;
}

export function useMessages(): typeof m {
  useLocale();
  return m;
}

export function LocaleMenu() {
  const { locale, setLocale } = useLocale();
  const messages = useMessages();
  return (
    <details className="locale-menu">
      <summary
        aria-label={messages.locale_menu_label()}
        title={messages.locale_menu_tooltip()}
      >
        <Globe size={15} />
      </summary>
      <div className="locale-options" role="menu">
        {(
          [
            ["en", messages.locale_english()],
            ["zh-CN", messages.locale_chinese()],
          ] as const
        ).map(([value, label]) => (
          <button
            aria-checked={locale === value}
            key={value}
            onClick={(event) => {
              setLocale(value);
              event.currentTarget.closest("details")?.removeAttribute("open");
            }}
            role="menuitemradio"
            type="button"
          >
            <span>{label}</span>
            {locale === value && <Check size={14} />}
          </button>
        ))}
      </div>
    </details>
  );
}
