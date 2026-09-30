import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import * as messages from "./paraglide/messages.js";
import {
  baseLocale,
  resolveLocalePreference,
  type CommaLocale,
  type CommaLocalePreference,
} from "./locale";
import { initializeCommaI18n } from "./runtime";

type CommaI18nContextValue = {
  locale: CommaLocale;
  localePreference: CommaLocalePreference;
  setLocalePreference: (preference: CommaLocalePreference) => void;
};

const CommaI18nContext = createContext<CommaI18nContextValue>({
  locale: baseLocale,
  localePreference: "system",
  setLocalePreference: () => undefined,
});

export function CommaI18nProvider({
  children,
  documentLanguage = true,
  locale: requestedLocale,
  localePreference: controlledLocalePreference,
  onLocalePreferenceChange,
}: {
  children: ReactNode;
  /** False when the page around Comma's UI owns <html lang> (see CommaI18nOptions). */
  documentLanguage?: boolean;
  locale?: CommaLocale;
  localePreference?: CommaLocalePreference;
  onLocalePreferenceChange?: (
    preference: CommaLocalePreference
  ) => Promise<void> | void;
}) {
  const initialize = useCallback(
    (preference: CommaLocalePreference) =>
      initializeCommaI18n([resolveLocalePreference(preference)], { documentLanguage }),
    [documentLanguage]
  );
  const [localLocalePreference, setLocalLocalePreference] =
    useState<CommaLocalePreference>(
      () => requestedLocale ?? controlledLocalePreference ?? "system"
    );
  const localePreference =
    requestedLocale ?? controlledLocalePreference ?? localLocalePreference;
  const [activeLocale, setActiveLocale] = useState(() => initialize(localePreference));

  useLayoutEffect(() => {
    const nextLocale = initialize(localePreference);
    setActiveLocale((currentLocale) =>
      currentLocale === nextLocale ? currentLocale : nextLocale
    );
  }, [initialize, localePreference]);

  const setLocalePreference = useCallback(
    (preference: CommaLocalePreference) => {
      if (requestedLocale) {
        return;
      }
      if (controlledLocalePreference !== undefined) {
        void onLocalePreferenceChange?.(preference);
        return;
      }
      setLocalLocalePreference(preference);
      setActiveLocale(initialize(preference));
    },
    [controlledLocalePreference, initialize, onLocalePreferenceChange, requestedLocale]
  );

  useEffect(() => {
    if (
      requestedLocale ||
      localePreference !== "system" ||
      typeof window === "undefined"
    ) {
      return;
    }
    const handleLanguageChange = () => {
      setActiveLocale(initialize("system"));
    };
    window.addEventListener("languagechange", handleLanguageChange);
    return () => window.removeEventListener("languagechange", handleLanguageChange);
  }, [initialize, localePreference, requestedLocale]);

  const value = useMemo(
    () => ({
      locale: activeLocale,
      localePreference,
      setLocalePreference,
    }),
    [activeLocale, localePreference, setLocalePreference]
  );

  return (
    <CommaI18nContext.Provider value={value}>{children}</CommaI18nContext.Provider>
  );
}

export function useCommaI18n() {
  return useContext(CommaI18nContext);
}

export function useCommaLocale() {
  return useCommaI18n().locale;
}

export function useCommaMessages(): typeof messages {
  useCommaLocale();
  return messages;
}
