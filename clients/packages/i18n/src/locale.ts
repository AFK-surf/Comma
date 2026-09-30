export const supportedLocales = ["en", "zh-CN"] as const;
export type CommaLocale = (typeof supportedLocales)[number];
export type CommaLocalePreference = CommaLocale | "system";

export const baseLocale: CommaLocale = "en";
export const legacyCommaLocaleStorageKey = "comma.locale";

export function resolveLocale(languages: readonly string[]): CommaLocale {
  for (const language of languages) {
    const normalized = language.trim().toLowerCase().replaceAll("_", "-");
    if (
      normalized === "zh-cn" ||
      normalized.startsWith("zh-cn-") ||
      normalized === "zh-sg" ||
      normalized.startsWith("zh-sg-") ||
      normalized === "zh-hans" ||
      normalized.startsWith("zh-hans-")
    ) {
      return "zh-CN";
    }
    if (normalized === "zh" || normalized.startsWith("zh-")) {
      continue;
    }
    if (normalized === "en" || normalized.startsWith("en-")) {
      return "en";
    }
  }
  return baseLocale;
}

export function detectLocale(): CommaLocale {
  if (typeof navigator === "undefined") {
    return baseLocale;
  }
  return resolveLocale(
    [...(navigator.languages ?? []), navigator.language].filter(Boolean)
  );
}

export function resolveLocalePreference(
  preference: CommaLocalePreference
): CommaLocale {
  return preference === "system" ? detectLocale() : preference;
}

export function readLegacyCommaLocalePreference(): CommaLocalePreference {
  try {
    const stored = globalThis.localStorage?.getItem(legacyCommaLocaleStorageKey);
    return supportedLocales.includes(stored as CommaLocale)
      ? (stored as CommaLocale)
      : "system";
  } catch {
    return "system";
  }
}

export function setDocumentLocale(locale: CommaLocale) {
  if (typeof document === "undefined") return;
  // Writing the same value still invalidates every :lang() style on the page.
  if (document.documentElement.lang !== locale) {
    document.documentElement.lang = locale;
  }
}
