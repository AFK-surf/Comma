import {
  commaClientAppearancePreferencesSchema,
  defaultCommaClientAppearancePreferences,
  getNativeBridge,
} from "@comma/native-bridge";
import {
  commaReducedMotionAttribute,
  commaThemeChromaGainMax,
  commaThemeLightnessNeutral,
  clampCommaThemeLightness,
  fontFamily as fontFamilyTokens,
  grayDarkMode,
  grayLightMode,
  hexToOklch,
  oklchChromaGainFromSample,
} from "@comma/ui";
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
import { CommaUiThemeProvider, type CommaUiThemeName } from "./commaUiTheme";
import { useCommaClientSettings } from "./commaClientSettings";

export type CommaThemePreference =
  | "default"
  | "light"
  | "dark"
  | "twilight"
  | "ink"
  | "signal-light"
  | "signal-dark"
  | "custom";
export type CommaFontSizePreference = "small" | "default" | "large";
export type CommaCustomSchemePreference = "system" | "light" | "dark";

/** Comma brand blue that seeds the Signal theme pair. */
export const commaSignalHex = "#0C55FF";
export const commaSignalHueDeg = hexToOklch(commaSignalHex).h;

const legacyThemeAliases = {
  system: "default",
  paper: "default",
  "pure-light": "default",
  "magic-blue": "dark",
  "classic-dark": "dark",
  twilight: "dark",
  ink: "dark",
} as const;

export const commaFontSizeScale = {
  small: 0.9,
  default: 1,
  large: 1.1,
} as const satisfies Record<CommaFontSizePreference, number>;

/** A chosen family leads Comma's own stack, which still covers glyphs it lacks. */
export const commaFontFamilyStack = (family: string) =>
  `"${family.replace(/["\\]/g, "\\$&")}", ${fontFamilyTokens.sans}`;

export type CommaThemeSeed = { hueDeg: number; chroma: number; lightness: number };

const neutralLightRef = grayLightMode[500] ?? grayLightMode[900];
const neutralDarkRef = grayDarkMode[500] ?? grayDarkMode[900];
const neutralLightOklch = hexToOklch(neutralLightRef);
const neutralDarkOklch = hexToOklch(neutralDarkRef);

const safeHue = (seed: { h: number; c: number }) =>
  seed.c < 1e-7 ? commaSignalHueDeg : seed.h;

const lightSeed: CommaThemeSeed = {
  hueDeg: safeHue(neutralLightOklch),
  chroma: oklchChromaGainFromSample(neutralLightOklch.c, neutralLightOklch.l),
  lightness: commaThemeLightnessNeutral,
};
const darkSeed: CommaThemeSeed = {
  hueDeg: safeHue(neutralDarkOklch),
  chroma: oklchChromaGainFromSample(neutralDarkOklch.c, neutralDarkOklch.l),
  lightness: commaThemeLightnessNeutral,
};
const grayChromaGain = Math.max(lightSeed.chroma, darkSeed.chroma);

const twilightSeed: CommaThemeSeed = {
  hueDeg: 264,
  chroma: grayChromaGain * 4.5,
  lightness: commaThemeLightnessNeutral,
};

const signalLightSeed: CommaThemeSeed = {
  hueDeg: commaSignalHueDeg,
  chroma: grayChromaGain * 3.5,
  lightness: commaThemeLightnessNeutral,
};

const signalDarkSeed: CommaThemeSeed = {
  hueDeg: commaSignalHueDeg,
  chroma: grayChromaGain * 6,
  lightness: commaThemeLightnessNeutral,
};

export interface CommaAppearancePreferences {
  fontFamily: string | null;
  fontSize: CommaFontSizePreference;
  pointerCursors: boolean;
  reducedMotion: boolean;
  theme: CommaThemePreference;
  customHue: number;
  customChroma: number;
  customLightness: number;
  customScheme: CommaCustomSchemePreference;
}

export const defaultCommaAppearancePreferences: CommaAppearancePreferences = {
  ...defaultCommaClientAppearancePreferences,
};

const canonicalThemePreferences: readonly CommaThemePreference[] = [
  "default",
  "light",
  "dark",
  "signal-light",
  "signal-dark",
  "custom",
];

const isThemePreference = (value: unknown): value is CommaThemePreference =>
  typeof value === "string" &&
  canonicalThemePreferences.some((preference) => preference === value);

const canonicalizeThemePreference = (value: unknown): CommaThemePreference => {
  if (typeof value === "string" && value in legacyThemeAliases) {
    return legacyThemeAliases[value as keyof typeof legacyThemeAliases];
  }
  return isThemePreference(value) ? value : defaultCommaAppearancePreferences.theme;
};

const systemThemeName = (): CommaUiThemeName =>
  typeof window !== "undefined" &&
  typeof window.matchMedia === "function" &&
  window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "Dark mode"
    : "Light mode";

const systemReducedMotionEnabled = () =>
  typeof window !== "undefined" &&
  typeof window.matchMedia === "function" &&
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function useSystemReducedMotion() {
  const [systemReducedMotion, setSystemReducedMotion] = useState(
    systemReducedMotionEnabled
  );

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;

    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updateSystemReducedMotion = (event: MediaQueryListEvent) => {
      setSystemReducedMotion(event.matches);
    };
    query.addEventListener("change", updateSystemReducedMotion);
    return () => query.removeEventListener("change", updateSystemReducedMotion);
  }, []);

  return systemReducedMotion;
}

const lightThemePreferences = new Set<CommaThemePreference>([
  "default",
  "light",
  "signal-light",
]);
const darkThemePreferences = new Set<CommaThemePreference>([
  "dark",
  "twilight",
  "ink",
  "signal-dark",
]);

const resolveThemeName = (
  preference: CommaThemePreference,
  systemTheme: CommaUiThemeName,
  customScheme: CommaCustomSchemePreference = "system"
): CommaUiThemeName => {
  if (lightThemePreferences.has(preference)) return "Light mode";
  if (darkThemePreferences.has(preference)) return "Dark mode";
  if (preference === "custom") {
    if (customScheme === "light") return "Light mode";
    if (customScheme === "dark") return "Dark mode";
  }
  return systemTheme;
};

export const resolveCommaThemeSeed = (
  preference: CommaThemePreference,
  systemTheme: CommaUiThemeName,
  customHue: number,
  customChroma: number = defaultCommaAppearancePreferences.customChroma,
  customLightness: number = defaultCommaAppearancePreferences.customLightness
): CommaThemeSeed => {
  const schemeSeed = systemTheme === "Dark mode" ? darkSeed : lightSeed;

  if (preference === "default") return { ...lightSeed, chroma: 0 };
  if (preference === "ink") return { ...darkSeed, chroma: 0 };
  if (preference === "twilight") return twilightSeed;
  if (preference === "signal-light") return signalLightSeed;
  if (preference === "signal-dark") return signalDarkSeed;
  if (preference === "light") return lightSeed;
  if (preference === "dark") return darkSeed;
  if (preference === "custom") {
    return { hueDeg: customHue, chroma: customChroma, lightness: customLightness };
  }
  return schemeSeed;
};

interface CommaAppearanceContextValue extends CommaAppearancePreferences {
  resolvedTheme: CommaUiThemeName;
  systemTheme: CommaUiThemeName;
  setFontFamily: (fontFamily: string | null) => void;
  setFontSize: (fontSize: CommaFontSizePreference) => void;
  setPointerCursors: (pointerCursors: boolean) => void;
  setReducedMotion: (reducedMotion: boolean) => void;
  setTheme: (theme: CommaThemePreference) => void;
  setCustomHue: (customHue: number) => void;
  setCustomChroma: (customChroma: number) => void;
  setCustomLightness: (customLightness: number) => void;
  /** Resolves once the settings owner has accepted (or rejected) the color. */
  setCustomColor: (
    customHue: number,
    customChroma: number,
    customLightness?: number
  ) => Promise<void>;
  setCustomScheme: (customScheme: CommaCustomSchemePreference) => void;
}

const CommaAppearanceContext = createContext<CommaAppearanceContextValue | null>(null);

export function CommaAppearanceProvider({
  children,
  colorScheme,
  syncNativeAppearance = true,
}: {
  children: ReactNode;
  /** A host-owned scheme, such as Telegram's, shown without changing the stored theme. */
  colorScheme?: "light" | "dark" | undefined;
  /** Read-only accessory renderers apply appearance locally without changing native windows. */
  syncNativeAppearance?: boolean;
}) {
  const clientSettings = useCommaClientSettings();
  const preferences = clientSettings.settings.appearance;
  const [systemTheme, setSystemTheme] = useState(systemThemeName);
  const systemReducedMotion = useSystemReducedMotion();
  const themePreference: CommaThemePreference = colorScheme
    ? colorScheme === "dark"
      ? "dark"
      : "default"
    : preferences.theme;
  const resolvedTheme = resolveThemeName(
    themePreference,
    systemTheme,
    preferences.customScheme
  );
  const resolvedCommaThemeSeed = resolveCommaThemeSeed(
    themePreference,
    systemTheme,
    preferences.customHue,
    preferences.customChroma,
    preferences.customLightness
  );
  const reducedMotionEnabled = preferences.reducedMotion || systemReducedMotion;

  const updatePreferences = useCallback(
    (update: (current: CommaAppearancePreferences) => CommaAppearancePreferences) =>
      clientSettings.update({
        appearance: commaClientAppearancePreferencesSchema.parse(update(preferences)),
      }),
    [clientSettings, preferences]
  );

  const setTheme = useCallback(
    (theme: CommaThemePreference) => {
      updatePreferences((current) => ({
        ...current,
        theme: canonicalizeThemePreference(theme),
      }));
    },
    [updatePreferences]
  );
  const setCustomHue = useCallback(
    (customHue: number) => {
      const clamped = Math.min(360, Math.max(0, customHue));
      updatePreferences((current) => ({ ...current, customHue: clamped }));
    },
    [updatePreferences]
  );
  const setCustomChroma = useCallback(
    (customChroma: number) => {
      const clamped = Math.min(commaThemeChromaGainMax, Math.max(0, customChroma));
      updatePreferences((current) => ({ ...current, customChroma: clamped }));
    },
    [updatePreferences]
  );
  const setCustomLightness = useCallback(
    (customLightness: number) => {
      const clamped = clampCommaThemeLightness(customLightness);
      updatePreferences((current) => ({ ...current, customLightness: clamped }));
    },
    [updatePreferences]
  );
  const setCustomColor = useCallback(
    (customHue: number, customChroma: number, customLightness?: number) => {
      const hue = Math.min(360, Math.max(0, customHue));
      const chroma = Math.min(commaThemeChromaGainMax, Math.max(0, customChroma));
      const lightness =
        customLightness === undefined
          ? undefined
          : clampCommaThemeLightness(customLightness);
      return updatePreferences((current) => ({
        ...current,
        customHue: hue,
        customChroma: chroma,
        ...(lightness === undefined ? {} : { customLightness: lightness }),
      }));
    },
    [updatePreferences]
  );
  const setCustomScheme = useCallback(
    (customScheme: CommaCustomSchemePreference) => {
      updatePreferences((current) => ({ ...current, customScheme }));
    },
    [updatePreferences]
  );
  const setFontFamily = useCallback(
    (fontFamily: string | null) => {
      updatePreferences((current) => ({ ...current, fontFamily }));
    },
    [updatePreferences]
  );
  const setFontSize = useCallback(
    (fontSize: CommaFontSizePreference) => {
      updatePreferences((current) => ({ ...current, fontSize }));
    },
    [updatePreferences]
  );
  const setPointerCursors = useCallback(
    (pointerCursors: boolean) => {
      updatePreferences((current) => ({ ...current, pointerCursors }));
    },
    [updatePreferences]
  );
  const setReducedMotion = useCallback(
    (reducedMotion: boolean) => {
      updatePreferences((current) => ({ ...current, reducedMotion }));
    },
    [updatePreferences]
  );

  useLayoutEffect(() => {
    const root = document.documentElement;
    root.style.setProperty("--comma-theme-h", `${resolvedCommaThemeSeed.hueDeg}deg`);
    root.style.setProperty("--comma-theme-c", `${resolvedCommaThemeSeed.chroma}`);
    root.style.setProperty("--comma-theme-l", `${resolvedCommaThemeSeed.lightness}`);
  }, [
    resolvedCommaThemeSeed.chroma,
    resolvedCommaThemeSeed.hueDeg,
    resolvedCommaThemeSeed.lightness,
  ]);

  useLayoutEffect(() => {
    const root = document.documentElement;
    if (root.dataset.theme !== resolvedTheme) {
      root.dataset.theme = resolvedTheme;
    }
    if (root.dataset.commaTheme !== themePreference) {
      root.dataset.commaTheme = themePreference;
    }
  }, [themePreference, resolvedTheme]);

  useLayoutEffect(() => {
    const root = document.documentElement;
    if (root.dataset.commaFontSize !== preferences.fontSize) {
      root.dataset.commaFontSize = preferences.fontSize;
    }
  }, [preferences.fontSize]);

  useLayoutEffect(() => {
    const root = document.documentElement;
    if (preferences.fontFamily === null) {
      delete root.dataset.commaFontFamily;
      root.style.removeProperty("--font-sans");
    } else {
      root.dataset.commaFontFamily = preferences.fontFamily;
      root.style.setProperty(
        "--font-sans",
        commaFontFamilyStack(preferences.fontFamily)
      );
    }
  }, [preferences.fontFamily]);

  useLayoutEffect(() => {
    const root = document.documentElement;
    const value = String(preferences.pointerCursors);
    if (root.dataset.commaPointerCursors !== value) {
      root.dataset.commaPointerCursors = value;
    }
  }, [preferences.pointerCursors]);

  useLayoutEffect(() => {
    const root = document.documentElement;
    const value = String(reducedMotionEnabled);
    if (root.getAttribute(commaReducedMotionAttribute) !== value) {
      root.setAttribute(commaReducedMotionAttribute, value);
    }
  }, [reducedMotionEnabled]);

  // Keep root styles in place during live edits; clear them only on unmount.
  useLayoutEffect(() => {
    const root = document.documentElement;
    return () => {
      delete root.dataset.theme;
      delete root.dataset.commaTheme;
      delete root.dataset.commaFontFamily;
      delete root.dataset.commaFontSize;
      delete root.dataset.commaPointerCursors;
      root.style.removeProperty("--font-sans");
      root.style.removeProperty("--comma-theme-h");
      root.style.removeProperty("--comma-theme-c");
      root.style.removeProperty("--comma-theme-l");
      root.removeAttribute(commaReducedMotionAttribute);
    };
  }, []);

  useEffect(() => {
    if (!syncNativeAppearance) return;
    void getNativeBridge()
      .appearance.setResolvedTheme(resolvedTheme === "Dark mode" ? "dark" : "light")
      .catch(() => undefined);
  }, [resolvedTheme, syncNativeAppearance]);

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;

    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const updateSystemTheme = (event: MediaQueryListEvent) => {
      setSystemTheme(event.matches ? "Dark mode" : "Light mode");
    };
    query.addEventListener("change", updateSystemTheme);
    return () => query.removeEventListener("change", updateSystemTheme);
  }, []);

  const value = useMemo<CommaAppearanceContextValue>(
    () => ({
      ...preferences,
      resolvedTheme,
      systemTheme,
      setFontFamily,
      setFontSize,
      setPointerCursors,
      setReducedMotion,
      setTheme,
      setCustomHue,
      setCustomChroma,
      setCustomLightness,
      setCustomColor,
      setCustomScheme,
    }),
    [
      preferences,
      resolvedTheme,
      systemTheme,
      setFontFamily,
      setFontSize,
      setPointerCursors,
      setReducedMotion,
      setTheme,
      setCustomHue,
      setCustomChroma,
      setCustomLightness,
      setCustomColor,
      setCustomScheme,
    ]
  );

  return (
    <CommaAppearanceContext.Provider value={value}>
      <CommaUiThemeProvider theme={resolvedTheme}>{children}</CommaUiThemeProvider>
    </CommaAppearanceContext.Provider>
  );
}

/**
 * Publishes only the effective reduced-motion state for standalone renderers
 * that do not own app-wide theme, font, pointer, or native appearance state.
 */
export function CommaReducedMotionRootSync({ children }: { children: ReactNode }) {
  const clientSettings = useCommaClientSettings();
  const systemReducedMotion = useSystemReducedMotion();
  const reducedMotion = clientSettings.settings.appearance.reducedMotion;

  useLayoutEffect(() => {
    const root = document.documentElement;
    root.setAttribute(
      commaReducedMotionAttribute,
      String(reducedMotion || systemReducedMotion)
    );
    return () => root.removeAttribute(commaReducedMotionAttribute);
  }, [reducedMotion, systemReducedMotion]);

  return <>{children}</>;
}

export function useCommaAppearance(): CommaAppearanceContextValue {
  const value = useContext(CommaAppearanceContext);
  if (!value) {
    throw new Error("useCommaAppearance must be used within CommaAppearanceProvider.");
  }
  return value;
}
