import {
  initializeCommaI18n,
  type CommaLocale,
  type CommaLocalePreference,
} from "@comma/i18n";

/**
 * Main's language. The app language is an account setting that the renderer
 * stores in client settings; a device that has not stored one yet (first run,
 * before sign-in) follows the operating system.
 */
export function initializeElectronMainI18n({
  appLocale,
  localePreference,
  preferredSystemLanguages,
}: {
  appLocale: string;
  localePreference?: CommaLocalePreference | undefined;
  preferredSystemLanguages: readonly string[];
}): CommaLocale {
  return initializeCommaI18n(
    localePreference && localePreference !== "system"
      ? [localePreference]
      : [appLocale, ...preferredSystemLanguages]
  );
}

/** A constructor's language: a fixed value, or Main's current one at each use. */
export type MainLocaleSource = CommaLocale | (() => CommaLocale);

export function readMainLocale(source: MainLocaleSource): CommaLocale {
  return typeof source === "function" ? source() : source;
}
