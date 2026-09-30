import { setLocale as setParaglideLocale } from "./paraglide/runtime.js";
import {
  detectLocale,
  resolveLocale,
  setDocumentLocale,
  type CommaLocale,
} from "./locale";

export type CommaI18nOptions = {
  /**
   * Whether Comma's language is also the document's (<html lang>). A page that
   * embeds Comma's UI in its own language passes false and keeps its own.
   */
  documentLanguage?: boolean;
};

export function initializeCommaI18n(
  languages?: readonly string[] | undefined,
  { documentLanguage = true }: CommaI18nOptions = {}
): CommaLocale {
  const locale = languages ? resolveLocale(languages) : detectLocale();
  setParaglideLocale(locale, { reload: false });
  if (documentLanguage) setDocumentLocale(locale);
  return locale;
}
