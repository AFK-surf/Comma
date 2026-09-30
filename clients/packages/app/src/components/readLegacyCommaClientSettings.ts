import { readLegacyCommaLocalePreference } from "@comma/i18n";
import {
  commaClientAppearancePreferencesSchema,
  commaClientSettingsSchema,
  defaultCommaClientAppearancePreferences,
  defaultSideChatShortcut,
  sideChatShortcutSchema,
  type CommaClientSettings,
} from "@comma/native-bridge";
import {
  clampCommaThemeLightness,
  commaThemeChromaGainMax,
  detectAppKeybindingPlatform,
} from "@comma/ui";
import { parseLegacyAppShortcutOverrides } from "./shortcuts/appShortcutSettings";

export const legacyCommaAppearanceStorageKey = "comma.appearance";
export const legacyCommaAppShortcutsStorageKey = "comma.app.shortcuts";
export const legacyCommaSideChatAppearanceStorageKey = "comma.sideChatAppearance";
export const legacyCommaSideChatShortcutStorageKey = "comma.side-chat.shortcut";

const readStoredJson = (key: string): unknown => {
  try {
    const stored = globalThis.localStorage?.getItem(key);
    return stored ? JSON.parse(stored) : undefined;
  } catch {
    return undefined;
  }
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const legacyThemeAliases = {
  system: "default",
  paper: "default",
  "pure-light": "default",
  "magic-blue": "dark",
  "classic-dark": "dark",
  twilight: "dark",
  ink: "dark",
} as const;

const canonicalThemes = new Set([
  "default",
  "light",
  "dark",
  "signal-light",
  "signal-dark",
  "custom",
]);

const readLegacyAppearance = () => {
  const parsed = readStoredJson(legacyCommaAppearanceStorageKey);
  if (!isRecord(parsed))
    return structuredClone(defaultCommaClientAppearancePreferences);

  const aliasedTheme =
    typeof parsed.theme === "string" && parsed.theme in legacyThemeAliases
      ? legacyThemeAliases[parsed.theme as keyof typeof legacyThemeAliases]
      : parsed.theme;
  const theme = canonicalThemes.has(aliasedTheme as string)
    ? aliasedTheme
    : defaultCommaClientAppearancePreferences.theme;
  const customHue =
    typeof parsed.customHue === "number" &&
    Number.isFinite(parsed.customHue) &&
    parsed.customHue >= 0 &&
    parsed.customHue <= 360
      ? parsed.customHue
      : defaultCommaClientAppearancePreferences.customHue;
  const customChroma =
    typeof parsed.customChroma === "number" &&
    Number.isFinite(parsed.customChroma) &&
    parsed.customChroma >= 0 &&
    parsed.customChroma <= commaThemeChromaGainMax
      ? parsed.customChroma
      : defaultCommaClientAppearancePreferences.customChroma;
  const customLightness =
    typeof parsed.customLightness === "number" &&
    Number.isFinite(parsed.customLightness) &&
    parsed.customLightness >= 0 &&
    parsed.customLightness <= 1
      ? clampCommaThemeLightness(parsed.customLightness)
      : defaultCommaClientAppearancePreferences.customLightness;

  return commaClientAppearancePreferencesSchema.parse({
    customChroma,
    customHue,
    customLightness,
    customScheme:
      parsed.customScheme === "light" || parsed.customScheme === "dark"
        ? parsed.customScheme
        : "system",
    fontSize:
      parsed.fontSize === "small" || parsed.fontSize === "large"
        ? parsed.fontSize
        : "default",
    pointerCursors:
      typeof parsed.pointerCursors === "boolean" ? parsed.pointerCursors : false,
    reducedMotion:
      typeof parsed.reducedMotion === "boolean" ? parsed.reducedMotion : false,
    theme,
  });
};

/**
 * One-time expand migration from the renderer-owned stores used by older Comma
 * builds. Main's compare-if-absent command prevents this snapshot from
 * overwriting a concurrent Client API mutation. The old keys intentionally
 * remain readable so a rollback can still recover the user's preferences.
 */
export function readLegacyCommaClientSettings(): CommaClientSettings {
  let sideChatAppearance: CommaClientSettings["sideChatAppearance"] = "auto";
  try {
    const stored = globalThis.localStorage?.getItem(
      legacyCommaSideChatAppearanceStorageKey
    );
    if (stored === "light" || stored === "dark") sideChatAppearance = stored;
  } catch {
    // Keep the default migration value when the legacy store is unavailable.
  }
  const parsedSideChatShortcut = sideChatShortcutSchema.safeParse(
    readStoredJson(legacyCommaSideChatShortcutStorageKey)
  );
  return commaClientSettingsSchema.parse({
    appShortcutOverrides: parseLegacyAppShortcutOverrides(
      readStoredJson(legacyCommaAppShortcutsStorageKey),
      detectAppKeybindingPlatform()
    ),
    appearance: readLegacyAppearance(),
    localePreference: readLegacyCommaLocalePreference(),
    sideChatAppearance,
    sideChatShortcut: parsedSideChatShortcut.success
      ? parsedSideChatShortcut.data
      : defaultSideChatShortcut,
  });
}
