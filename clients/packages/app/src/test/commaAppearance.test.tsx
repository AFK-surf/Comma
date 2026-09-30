import userEvent from "@testing-library/user-event";
import { commaThemeLightnessMax, commaThemeLightnessMin } from "@comma/ui";
import {
  defaultCommaClientSettings,
  type CommaClientSettings,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CommaAppearanceProvider,
  CommaReducedMotionRootSync,
  commaSignalHueDeg,
  defaultCommaAppearancePreferences,
  resolveCommaThemeSeed,
  useCommaAppearance,
} from "../components/commaAppearance";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../components/commaClientSettings";
import {
  legacyCommaAppearanceStorageKey,
  readLegacyCommaClientSettings,
} from "../components/readLegacyCommaClientSettings";

let systemThemeListener: ((event: MediaQueryListEvent) => void) | undefined;
let systemReducedMotionListener: ((event: MediaQueryListEvent) => void) | undefined;
let nativeBridge: ReturnType<typeof installNativeBridgeMock>;

const AppearanceProbe = () => {
  const appearance = useCommaAppearance();
  return (
    <>
      <output aria-label="appearance">
        {appearance.theme}:{appearance.resolvedTheme}:{appearance.fontSize}:
        {String(appearance.pointerCursors)}:{String(appearance.reducedMotion)}
      </output>
      <button onClick={() => appearance.setTheme("dark")} type="button">
        Dark
      </button>
      <button onClick={() => appearance.setTheme("default")} type="button">
        Theme Default
      </button>
      <button onClick={() => appearance.setTheme("light")} type="button">
        Soft Light
      </button>
      <button onClick={() => appearance.setTheme("signal-dark")} type="button">
        Signal Dark
      </button>
      <button onClick={() => appearance.setTheme("custom")} type="button">
        Custom
      </button>
      <button onClick={() => appearance.setCustomHue(120)} type="button">
        Hue 120
      </button>
      <button onClick={() => appearance.setCustomChroma(0.08)} type="button">
        Chroma 0.08
      </button>
      <button onClick={() => appearance.setCustomLightness(0.6)} type="button">
        Lightness 0.6
      </button>
      <button onClick={() => appearance.setCustomScheme("dark")} type="button">
        Custom dark
      </button>
      <button onClick={() => appearance.setCustomScheme("light")} type="button">
        Custom light
      </button>
      <button onClick={() => appearance.setFontSize("large")} type="button">
        Large
      </button>
      <button onClick={() => appearance.setFontSize("default")} type="button">
        Default
      </button>
      <button onClick={() => appearance.setPointerCursors(true)} type="button">
        Pointer on
      </button>
      <button onClick={() => appearance.setPointerCursors(false)} type="button">
        Pointer off
      </button>
      <button onClick={() => appearance.setReducedMotion(true)} type="button">
        Motion reduced
      </button>
      <button onClick={() => appearance.setReducedMotion(false)} type="button">
        Motion restored
      </button>
    </>
  );
};

const renderWithClientSettings = (children: React.ReactNode) =>
  render(<CommaWebClientSettingsProvider>{children}</CommaWebClientSettingsProvider>);

const readStoredClientSettings = () =>
  JSON.parse(
    localStorage.getItem(commaClientSettingsStorageKey)!
  ) as CommaClientSettings;

const writeClientSettings = (settings: CommaClientSettings) => {
  localStorage.setItem(commaClientSettingsStorageKey, JSON.stringify(settings));
};

describe("CommaAppearanceProvider", () => {
  it("applies the saved theme in a read-only accessory without publishing native appearance", async () => {
    writeClientSettings({
      ...defaultCommaClientSettings,
      appearance: { ...defaultCommaClientSettings.appearance, theme: "dark" },
    });
    renderWithClientSettings(
      <CommaAppearanceProvider syncNativeAppearance={false}>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );
    await waitFor(() =>
      expect(document.documentElement).toHaveAttribute("data-theme", "Dark mode")
    );
    expect(nativeBridge.appearance.setResolvedTheme).not.toHaveBeenCalled();
  });

  beforeEach(() => {
    localStorage.clear();
    nativeBridge = installNativeBridgeMock({ platform: "electron" });
    systemThemeListener = undefined;
    systemReducedMotionListener = undefined;
    vi.stubGlobal(
      "matchMedia",
      vi.fn((query: string) => ({
        matches: false,
        media: query,
        onchange: null,
        addEventListener: vi.fn(
          (event: string, listener: (event: MediaQueryListEvent) => void) => {
            if (event !== "change") return;
            if (query === "(prefers-reduced-motion: reduce)") {
              systemReducedMotionListener = listener;
            } else {
              systemThemeListener = listener;
            }
          }
        ),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }))
    );
  });

  afterEach(() => {
    localStorage.clear();
    delete document.documentElement.dataset.theme;
    delete document.documentElement.dataset.commaFontSize;
    delete document.documentElement.dataset.commaPointerCursors;
    delete document.documentElement.dataset.commaReducedMotion;
    vi.unstubAllGlobals();
    Reflect.deleteProperty(globalThis, "commaNative");
  });

  it("reads the old appearance key only as a migration source", async () => {
    localStorage.setItem(
      legacyCommaAppearanceStorageKey,
      JSON.stringify({
        theme: "dark",
        fontSize: "large",
        pointerCursors: true,
        reducedMotion: true,
      })
    );

    expect(readLegacyCommaClientSettings().appearance).toEqual({
      theme: "dark",
      fontFamily: null,
      fontSize: "large",
      pointerCursors: true,
      reducedMotion: true,
      customHue: 263,
      customChroma: defaultCommaAppearancePreferences.customChroma,
      customLightness: defaultCommaAppearancePreferences.customLightness,
      customScheme: "system",
    });

    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );
    await waitFor(() =>
      expect(readStoredClientSettings().appearance.theme).toBe("dark")
    );
    expect(localStorage.getItem(legacyCommaAppearanceStorageKey)).not.toBeNull();
  });

  it("applies, persists, and restores every appearance preference", async () => {
    const firstRender = renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "default:Light mode:default:false:false"
    );
    expect(document.documentElement).toHaveAttribute("data-theme", "Light mode");
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("light")
    );

    await userEvent.click(screen.getByRole("button", { name: "Dark" }));
    await userEvent.click(screen.getByRole("button", { name: "Large" }));
    await userEvent.click(screen.getByRole("button", { name: "Pointer on" }));
    await userEvent.click(screen.getByRole("button", { name: "Motion reduced" }));

    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "dark:Dark mode:large:true:true"
    );
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaFontSize).toBe("large");
    expect(document.documentElement.dataset.commaPointerCursors).toBe("true");
    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("dark")
    );

    firstRender.unmount();
    for (const attribute of [
      "data-theme",
      "data-comma-theme",
      "data-comma-font-size",
      "data-comma-pointer-cursors",
      "data-comma-reduced-motion",
    ]) {
      expect(document.documentElement).not.toHaveAttribute(attribute);
    }
    for (const property of ["--comma-theme-h", "--comma-theme-c", "--comma-theme-l"]) {
      expect(document.documentElement.style.getPropertyValue(property)).toBe("");
    }
    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );
    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "dark:Dark mode:large:true:true"
    );

    await userEvent.click(screen.getByRole("button", { name: "Theme Default" }));
    await userEvent.click(screen.getByRole("button", { name: "Default" }));
    await userEvent.click(screen.getByRole("button", { name: "Pointer off" }));
    await userEvent.click(screen.getByRole("button", { name: "Motion restored" }));

    await waitFor(() =>
      expect(readStoredClientSettings().appearance).toEqual(
        defaultCommaAppearancePreferences
      )
    );
  });

  it("keeps Default on Light mode when the system color scheme changes", async () => {
    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );
    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("default");
    expect(document.documentElement.style.getPropertyValue("--comma-theme-c")).toBe(
      "0"
    );

    act(() => {
      systemThemeListener?.({ matches: true } as MediaQueryListEvent);
    });

    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "default:Light mode:default:false:false"
    );
    expect(document.documentElement.dataset.theme).toBe("Light mode");
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("light")
    );
  });

  it("lets Custom follow the system color scheme until a scheme is forced", async () => {
    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    await userEvent.click(screen.getByRole("button", { name: "Custom" }));
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    expect(document.documentElement.dataset.theme).toBe("Light mode");

    act(() => {
      systemThemeListener?.({ matches: true } as MediaQueryListEvent);
    });

    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("dark")
    );
  });

  it("publishes the effective system motion preference without persisting it", () => {
    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    expect(document.documentElement.dataset.commaReducedMotion).toBe("false");

    act(() => {
      systemReducedMotionListener?.({ matches: true } as MediaQueryListEvent);
    });

    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "default:Light mode:default:false:false"
    );
    expect(readStoredClientSettings().appearance.reducedMotion).toBe(false);

    act(() => {
      systemReducedMotionListener?.({ matches: false } as MediaQueryListEvent);
    });
    expect(document.documentElement.dataset.commaReducedMotion).toBe("false");
  });

  it("syncs only reduced motion for standalone renderers", () => {
    writeClientSettings({
      ...structuredClone(defaultCommaClientSettings),
      appearance: {
        ...defaultCommaAppearancePreferences,
        fontSize: "large",
        pointerCursors: true,
        reducedMotion: true,
        theme: "dark",
      },
    });

    renderWithClientSettings(
      <CommaReducedMotionRootSync>
        <div>Standalone renderer</div>
      </CommaReducedMotionRootSync>
    );

    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
    expect(document.documentElement.dataset.theme).toBeUndefined();
    expect(document.documentElement.dataset.commaFontSize).toBeUndefined();
    expect(document.documentElement.dataset.commaPointerCursors).toBeUndefined();
    expect(nativeBridge.appearance.setResolvedTheme).not.toHaveBeenCalled();

    writeClientSettings({
      ...structuredClone(defaultCommaClientSettings),
      appearance: {
        ...defaultCommaAppearancePreferences,
        fontSize: "large",
        pointerCursors: true,
        reducedMotion: false,
        theme: "dark",
      },
    });
    act(() => {
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: commaClientSettingsStorageKey,
          newValue: localStorage.getItem(commaClientSettingsStorageKey),
        })
      );
    });
    expect(document.documentElement.dataset.commaReducedMotion).toBe("false");

    act(() => {
      systemReducedMotionListener?.({ matches: true } as MediaQueryListEvent);
    });
    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
  });

  it("maps legacy theme ids and applies Signal Dark from Comma blue", async () => {
    for (const theme of ["magic-blue", "twilight", "ink", "classic-dark"] as const) {
      localStorage.setItem(
        legacyCommaAppearanceStorageKey,
        JSON.stringify({
          theme,
          fontSize: "default",
          pointerCursors: false,
          reducedMotion: false,
        })
      );
      expect(readLegacyCommaClientSettings().appearance.theme).toBe("dark");
    }

    for (const theme of ["system", "paper", "pure-light"] as const) {
      localStorage.setItem(
        legacyCommaAppearanceStorageKey,
        JSON.stringify({
          theme,
          fontSize: "default",
          pointerCursors: false,
          reducedMotion: false,
        })
      );
      expect(readLegacyCommaClientSettings().appearance.theme).toBe("default");
    }

    localStorage.setItem(
      legacyCommaAppearanceStorageKey,
      JSON.stringify({
        ...defaultCommaAppearancePreferences,
        theme: "custom",
        customLightness: 1,
      })
    );
    expect(readLegacyCommaClientSettings().appearance.customLightness).toBe(
      commaThemeLightnessMax
    );
    localStorage.setItem(
      legacyCommaAppearanceStorageKey,
      JSON.stringify({
        ...defaultCommaAppearancePreferences,
        theme: "custom",
        customLightness: 0,
      })
    );
    expect(readLegacyCommaClientSettings().appearance.customLightness).toBe(
      commaThemeLightnessMin
    );

    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    await userEvent.click(screen.getByRole("button", { name: "Signal Dark" }));

    expect(screen.getByLabelText("appearance")).toHaveTextContent(
      "signal-dark:Dark mode:default:false:false"
    );
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("signal-dark");
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-h")
      )
    ).toBeCloseTo(commaSignalHueDeg, 0);
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-c")
      )
    ).toBeGreaterThan(0.06);
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("dark")
    );
  });

  it("keeps Default achromatic, tints Soft Light, and persists Custom hue, chroma, and lightness", async () => {
    expect(resolveCommaThemeSeed("default", "Light mode", 120, 0.08).chroma).toBe(0);
    expect(
      resolveCommaThemeSeed("light", "Light mode", 120, 0.08).chroma
    ).toBeGreaterThan(0);
    expect(resolveCommaThemeSeed("custom", "Light mode", 120, 0.08)).toEqual({
      hueDeg: 120,
      chroma: 0.08,
      lightness: defaultCommaAppearancePreferences.customLightness,
    });

    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    await userEvent.click(screen.getByRole("button", { name: "Soft Light" }));
    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("light");
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-c")
      )
    ).toBeGreaterThan(0);

    await userEvent.click(screen.getByRole("button", { name: "Theme Default" }));
    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("default");
    expect(document.documentElement.style.getPropertyValue("--comma-theme-c")).toBe(
      "0"
    );

    await userEvent.click(screen.getByRole("button", { name: "Custom" }));
    await userEvent.click(screen.getByRole("button", { name: "Hue 120" }));
    await userEvent.click(screen.getByRole("button", { name: "Chroma 0.08" }));
    await userEvent.click(screen.getByRole("button", { name: "Lightness 0.6" }));
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "120deg"
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-c")).toBe(
      "0.08"
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-l")).toBe(
      "0.6"
    );
    expect(readStoredClientSettings().appearance).toEqual({
      theme: "custom",
      customHue: 120,
      customChroma: 0.08,
      customLightness: 0.6,
      customScheme: "system",
      fontFamily: null,
      fontSize: "default",
      pointerCursors: false,
      reducedMotion: false,
    });
  });

  it("lets Custom force light or dark without leaving the custom seed", async () => {
    renderWithClientSettings(
      <CommaAppearanceProvider>
        <AppearanceProbe />
      </CommaAppearanceProvider>
    );

    await userEvent.click(screen.getByRole("button", { name: "Custom" }));
    expect(document.documentElement.dataset.theme).toBe("Light mode");

    await userEvent.click(screen.getByRole("button", { name: "Custom dark" }));
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    await waitFor(() =>
      expect(nativeBridge.appearance.setResolvedTheme).toHaveBeenLastCalledWith("dark")
    );

    await userEvent.click(screen.getByRole("button", { name: "Custom light" }));
    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "custom",
      customScheme: "light",
    });
  });
});
