import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";

export function initializeElectronMainI18n({
  appLocale,
  preferredSystemLanguages,
}: {
  appLocale: string;
  preferredSystemLanguages: readonly string[];
}): CommaLocale {
  return initializeCommaI18n([appLocale, ...preferredSystemLanguages]);
}
