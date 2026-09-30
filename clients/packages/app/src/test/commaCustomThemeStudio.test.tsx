import { commaThemeChromaGainMax, oklchChromaEnvelope } from "@comma/ui";
import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import {
  appPreferencesSchema,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
} from "@comma/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CommaAppearanceProvider,
  defaultCommaAppearancePreferences,
} from "../components/commaAppearance";
import {
  CommaElectronClientSettingsProvider,
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../components/commaClientSettings";
import {
  CustomThemeStudio,
  INDICATOR_ACTIVE_SCALE,
  INDICATOR_VISUAL_SIZE,
  channelCenter,
  channelFill,
  channelFollow,
  channelGlyphColor,
  clampChannelCenter,
  indicatorGlyphs,
  mapPadPointer,
  nearestChannel,
  rubberband,
  sampleChroma,
  sampleFromPlane,
  type IndicatorChannel,
} from "../components/commaCustomThemeStudio";

const padRect = {
  left: 0,
  top: 0,
  width: 200,
  height: 100,
  right: 200,
  bottom: 100,
  x: 0,
  y: 0,
  toJSON() {
    return this;
  },
} as DOMRect;

const defaults = defaultCommaAppearancePreferences;
const padName = "Hue, chroma, and lightness pad";
const floatSlack = 1e-9;
const half = INDICATOR_VISUAL_SIZE / 2;
const activeSize = INDICATOR_VISUAL_SIZE * INDICATOR_ACTIVE_SCALE;
const separatedColor = {
  hue: 90,
  chroma: 0.08,
  lightness: 0.56,
} as const;

const parseTranslate = (node: Element) => {
  const match = /translate3d\(([-\d.]+)px, ([-\d.]+)px/.exec(
    (node as HTMLElement).style.transform
  );
  return { x: Number(match?.[1]), y: Number(match?.[2]) };
};

const followTarget = (
  channel: IndicatorChannel,
  plane: IndicatorChannel,
  visualX: number,
  visualY: number,
  sample: { hue: number; chroma: number; lightness: number }
) =>
  clampChannelCenter(
    channelFollow(channel, plane, visualX, visualY, sample, 200, 100),
    200,
    100,
    channel === plane ? activeSize : INDICATOR_VISUAL_SIZE
  );

const renderStudio = (
  color: { hue: number; chroma: number; lightness: number } = {
    hue: defaults.customHue,
    chroma: defaults.customChroma,
    lightness: defaults.customLightness,
  }
) => {
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({
      ...structuredClone(defaultCommaClientSettings),
      appearance: {
        ...defaults,
        theme: "custom",
        customHue: color.hue,
        customChroma: color.chroma,
        customLightness: color.lightness,
      },
    })
  );
  render(
    <CommaWebClientSettingsProvider>
      <CommaAppearanceProvider>
        <CommaI18nProvider>
          <CustomThemeStudio />
        </CommaI18nProvider>
      </CommaAppearanceProvider>
    </CommaWebClientSettingsProvider>
  );
  const pad = screen.getByRole("group", { name: padName });
  pad.getBoundingClientRect = () => padRect;
  return pad;
};

const indicatorsByChannel = (pad: HTMLElement) =>
  Object.fromEntries(
    [...pad.querySelectorAll("[data-slot='studio-indicator']")].map((node) => [
      node.getAttribute("data-channel"),
      node,
    ])
  ) as Record<IndicatorChannel, HTMLElement>;

describe("custom theme studio mapping", () => {
  it("maps pad x to hue and inverted y to lightness", () => {
    expect(mapPadPointer(0, 100, padRect)).toEqual({
      chroma: 0,
      hue: 0,
      lightness: 0,
      visualX: 0,
      visualY: 1,
    });
    expect(mapPadPointer(100, 0, padRect)).toEqual({
      chroma: commaThemeChromaGainMax,
      hue: 180,
      lightness: 1,
      visualX: 0.5,
      visualY: 0,
    });
  });

  it("rubber-bands past the pad edge instead of clamping the visual pointer", () => {
    const pastRight = mapPadPointer(260, 50, padRect);
    expect(pastRight.hue).toBe(360);
    expect(pastRight.visualX).toBeGreaterThan(1);
    expect(pastRight.visualX).toBeLessThan(1.4);
    expect(rubberband(60, 200)).toBeLessThan(60);
  });

  it("projects one OKLCH sample onto H×C, L×C, and H×L without sharing a point", () => {
    expect(sampleChroma(0.08, 0.8)).toBeCloseTo(0.08 * 4 * 0.8 * 0.2, 10);
    const hueAt = channelCenter("hue", 90, 0.08, 0.8, 200, 100);
    expect(hueAt.x).toBe(50);
    expect(hueAt.y).toBeCloseTo(
      (1 - sampleChroma(0.08, 0.8) / commaThemeChromaGainMax) * 100,
      10
    );
    expect(channelCenter("chroma", 90, 0.08, 0.8, 200, 100).x).toBe(200);
    const light = channelCenter("lightness", 90, 0.08, 0.8, 200, 100);
    expect(light.x).toBe(50);
    expect(light.y).toBeCloseTo(0, 10);

    expect(channelCenter("lightness", 180, 0.08, 0.8, 200, 100).x).toBe(100);
    expect(channelCenter("chroma", 180, 0.08, 0.8, 200, 100).x).toBe(200);
    expect(channelCenter("hue", 90, 0.08, 0.8, 200, 100).y).not.toBeCloseTo(
      channelCenter("lightness", 90, 0.08, 0.8, 200, 100).y,
      5
    );
  });

  it("projects the inclusive Hue maximum onto the right edge", () => {
    expect(channelCenter("hue", 360, 0.08, 0.8, 200, 100).x).toBe(200);
    expect(channelCenter("lightness", 360, 0.08, 0.8, 200, 100).x).toBe(200);
  });

  it("rewrites two axes from the grabbed plane and keeps the third frozen", () => {
    const current = { hue: 90, chroma: 0.08, lightness: 0.8 };
    const huePlane = sampleFromPlane("hue", 0.75, 0.4, current);
    expect(huePlane.hue).toBe(270);
    expect(huePlane.lightness).toBe(0.8);
    expect(huePlane.chroma).toBeCloseTo(
      (0.6 * commaThemeChromaGainMax) / oklchChromaEnvelope(0.8),
      10
    );

    const chromaPlane = sampleFromPlane("chroma", 0.5, 0.4, current);
    expect(chromaPlane.hue).toBe(90);
    expect(chromaPlane.lightness).toBe(0.5);
    expect(chromaPlane.chroma).toBeCloseTo(0.6 * commaThemeChromaGainMax, 10);

    const lightPlane = sampleFromPlane("lightness", 0.75, 0.4, current);
    expect(lightPlane.hue).toBe(270);
    expect(lightPlane.chroma).toBe(0.08);
    expect(lightPlane.lightness).toBeCloseTo(0.36 + 0.6 * 0.28, 10);
  });

  it("follows the pointer on the grabbed indicator and the sample on the other two", () => {
    const sample = sampleFromPlane("hue", 0.75, 0.4, { ...separatedColor });
    expect(channelFollow("hue", "hue", 0.75, 0.4, sample, 200, 100)).toEqual({
      x: 150,
      y: 40,
    });
    expect(channelFollow("chroma", "hue", 0.75, 0.4, sample, 200, 100)).toEqual(
      channelCenter("chroma", sample.hue, sample.chroma, sample.lightness, 200, 100)
    );
    expect(channelFollow("lightness", "hue", 0.75, 0.4, sample, 200, 100)).toEqual(
      channelCenter("lightness", sample.hue, sample.chroma, sample.lightness, 200, 100)
    );
  });

  it("picks the nearest rest indicator, preferring the topmost when they coincide", () => {
    expect(nearestChannel(50, 20, 90, 0.08, 0.8, 200, 100)).toBe("lightness");
    const chromaRest = channelCenter("chroma", 90, 0.08, 0.8, 200, 100);
    expect(nearestChannel(chromaRest.x, chromaRest.y, 90, 0.08, 0.8, 200, 100)).toBe(
      "chroma"
    );
    const hueRest = channelCenter("hue", 90, 0.08, 0.8, 200, 100);
    expect(nearestChannel(hueRest.x, hueRest.y, 90, 0.08, 0.8, 200, 100)).toBe("hue");
    expect(nearestChannel(100, 50, 180, 0.08, 0.5, 200, 100)).toBe("hue");
  });

  it("keeps each indicator inside the pad, including past the edge", () => {
    expect(clampChannelCenter({ x: -40, y: 50 }, 200, 100)).toEqual({
      x: half,
      y: 50,
    });
    expect(clampChannelCenter({ x: 260, y: -10 }, 200, 100)).toEqual({
      x: 200 - half,
      y: half,
    });
    expect(clampChannelCenter({ x: 100, y: 50 }, 200, 100)).toEqual({
      x: 100,
      y: 50,
    });
    expect(clampChannelCenter({ x: -40, y: 50 }, 200, 100, activeSize)).toEqual({
      x: activeSize / 2,
      y: 50,
    });
  });

  it("paints Lightness, Chroma, and Hue as distinct OKLCH fills from the sample", () => {
    expect(channelFill("hue", 264, 0, 0.5)).toContain("264");
    expect(channelFill("chroma", 264, 0, 0.5)).toContain("0.5 0 ");
    expect(channelFill("lightness", 264, 0.08, 0.28)).toBe("oklch(0.28 0 0)");
    expect(channelFill("lightness", 264, 0.08, 0.92)).toBe("oklch(0.92 0 0)");
    expect(channelGlyphColor(0.28)).toBe("oklch(0.98 0 0)");
    expect(channelGlyphColor(0.6)).toBe("oklch(0.2 0 0)");
    expect(channelGlyphColor(0.92)).toBe("oklch(0.2 0 0)");
  });
});

describe("CustomThemeStudio", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    installNativeBridgeMock({ platform: "electron" });
    localStorage.clear();
  });

  afterEach(() => {
    localStorage.clear();
    delete document.documentElement.dataset.theme;
    delete document.documentElement.dataset.commaTheme;
  });

  it("labels the three indicators with L, C, and H", () => {
    const pad = renderStudio();
    const byChannel = indicatorsByChannel(pad);
    expect(byChannel.lightness).toHaveTextContent(indicatorGlyphs.lightness);
    expect(byChannel.chroma).toHaveTextContent(indicatorGlyphs.chroma);
    expect(byChannel.hue).toHaveTextContent(indicatorGlyphs.hue);
  });

  it("drags hue so H and C change, L stays, and the other indicators follow", async () => {
    const pad = renderStudio(separatedColor);
    const rest = channelCenter(
      "hue",
      separatedColor.hue,
      separatedColor.chroma,
      separatedColor.lightness,
      200,
      100
    );
    fireEvent.pointerDown(pad, { clientX: rest.x, clientY: rest.y, pointerId: 1 });
    fireEvent.pointerMove(pad, { clientX: 150, clientY: 40, pointerId: 1 });

    const sample = sampleFromPlane("hue", 0.75, 0.4, { ...separatedColor });
    // The studio previews the drag; the app theme waits for the release.
    expect(screen.getByRole("slider", { name: "Hue" })).toHaveAttribute(
      "aria-valuenow",
      "270"
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "90deg"
    );

    const byChannel = indicatorsByChannel(pad);
    expect(Object.keys(byChannel)).toEqual(["lightness", "chroma", "hue"]);

    const expectedHue = followTarget("hue", "hue", 0.75, 0.4, sample);
    const expectedChroma = followTarget("chroma", "hue", 0.75, 0.4, sample);
    const expectedLight = followTarget("lightness", "hue", 0.75, 0.4, sample);

    await waitFor(() => {
      expect(byChannel.hue.dataset.dragging).toBe("true");
      expect(byChannel.chroma.dataset.dragging).toBe("false");
      expect(byChannel.lightness.dataset.dragging).toBe("false");
      const hue = parseTranslate(byChannel.hue);
      const chroma = parseTranslate(byChannel.chroma);
      const lightness = parseTranslate(byChannel.lightness);
      expect(hue.x).toBeCloseTo(expectedHue.x - half, 5);
      expect(hue.y).toBeCloseTo(expectedHue.y - half, 5);
      expect(chroma.x).toBeCloseTo(expectedChroma.x - half, 5);
      expect(chroma.y).toBeCloseTo(expectedChroma.y - half, 5);
      expect(lightness.x).toBeCloseTo(expectedLight.x - half, 5);
      expect(lightness.y).toBeCloseTo(expectedLight.y - half, 5);
    });

    const hueFill = byChannel.hue.querySelector(
      ".comma-custom-theme-studio__channel-fill"
    ) as HTMLElement;
    expect(hueFill.style.background).toBe(
      channelFill("hue", sample.hue, sample.chroma, sample.lightness)
    );
    expect(
      (
        byChannel.lightness.querySelector(
          ".comma-custom-theme-studio__channel-fill"
        ) as HTMLElement
      ).style.background
    ).toBe(channelFill("lightness", sample.hue, sample.chroma, sample.lightness));

    fireEvent.pointerUp(pad, { clientX: 150, clientY: 40, pointerId: 1 });
    await waitFor(() =>
      expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
        "270deg"
      )
    );
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-c")
      )
    ).toBeCloseTo(sample.chroma, 5);
    expect(document.documentElement.style.getPropertyValue("--comma-theme-l")).toBe(
      "0.56"
    );

    expect(document.querySelector(".comma-custom-theme-studio__blob")).toBeNull();
    expect(screen.getByRole("slider", { name: "Hue" })).toBeInTheDocument();
    expect(screen.getByRole("slider", { name: "Chroma" })).toBeInTheDocument();
    expect(screen.getByRole("slider", { name: "Lightness" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Hue 348°" }));
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "348deg"
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-l")).toBe(
      "0.56"
    );
  });

  it("drags chroma so L and C change, H stays, and the other indicators follow", async () => {
    const pad = renderStudio(separatedColor);
    const rest = channelCenter(
      "chroma",
      separatedColor.hue,
      separatedColor.chroma,
      separatedColor.lightness,
      200,
      100
    );
    fireEvent.pointerDown(pad, { clientX: rest.x, clientY: rest.y, pointerId: 1 });
    fireEvent.pointerMove(pad, { clientX: 100, clientY: 40, pointerId: 1 });

    const sample = sampleFromPlane("chroma", 0.5, 0.4, { ...separatedColor });
    const byChannel = indicatorsByChannel(pad);
    const expectedChroma = followTarget("chroma", "chroma", 0.5, 0.4, sample);
    const expectedHue = followTarget("hue", "chroma", 0.5, 0.4, sample);
    const expectedLight = followTarget("lightness", "chroma", 0.5, 0.4, sample);

    await waitFor(() => {
      expect(byChannel.chroma.dataset.dragging).toBe("true");
      expect(byChannel.hue.dataset.dragging).toBe("false");
      expect(byChannel.lightness.dataset.dragging).toBe("false");
      expect(parseTranslate(byChannel.chroma).x).toBeCloseTo(
        expectedChroma.x - half,
        5
      );
      expect(parseTranslate(byChannel.chroma).y).toBeCloseTo(
        expectedChroma.y - half,
        5
      );
      expect(parseTranslate(byChannel.hue).x).toBeCloseTo(expectedHue.x - half, 5);
      expect(parseTranslate(byChannel.lightness).x).toBeCloseTo(
        expectedLight.x - half,
        5
      );
    });

    expect(
      (
        byChannel.chroma.querySelector(
          ".comma-custom-theme-studio__channel-fill"
        ) as HTMLElement
      ).style.background
    ).toContain("0.5");

    fireEvent.pointerUp(pad, { clientX: 100, clientY: 40, pointerId: 1 });
    await waitFor(() =>
      expect(document.documentElement.style.getPropertyValue("--comma-theme-l")).toBe(
        "0.5"
      )
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "90deg"
    );
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-c")
      )
    ).toBeCloseTo(sample.chroma, 5);
  });

  it("drags lightness so H and L change, C stays, and the other indicators follow", async () => {
    const pad = renderStudio(separatedColor);
    const chromaBefore =
      document.documentElement.style.getPropertyValue("--comma-theme-c");
    const rest = channelCenter(
      "lightness",
      separatedColor.hue,
      separatedColor.chroma,
      separatedColor.lightness,
      200,
      100
    );
    fireEvent.pointerDown(pad, { clientX: rest.x, clientY: rest.y, pointerId: 1 });
    fireEvent.pointerMove(pad, { clientX: 150, clientY: 40, pointerId: 1 });

    const byChannel = indicatorsByChannel(pad);
    const sample = sampleFromPlane("lightness", 0.75, 0.4, { ...separatedColor });
    const expectedLight = followTarget("lightness", "lightness", 0.75, 0.4, sample);
    const expectedHue = followTarget("hue", "lightness", 0.75, 0.4, sample);
    const expectedChroma = followTarget("chroma", "lightness", 0.75, 0.4, sample);

    await waitFor(() => {
      expect(byChannel.lightness.dataset.dragging).toBe("true");
      expect(byChannel.hue.dataset.dragging).toBe("false");
      expect(byChannel.chroma.dataset.dragging).toBe("false");
      expect(parseTranslate(byChannel.lightness).x).toBeCloseTo(
        expectedLight.x - half,
        5
      );
      expect(parseTranslate(byChannel.lightness).y).toBeCloseTo(
        expectedLight.y - half,
        5
      );
      expect(parseTranslate(byChannel.hue).x).toBeCloseTo(expectedHue.x - half, 5);
      expect(parseTranslate(byChannel.chroma).x).toBeCloseTo(
        expectedChroma.x - half,
        5
      );
    });

    const sampleLightness = 0.36 + 0.6 * 0.28;
    expect(
      (
        byChannel.lightness.querySelector(
          ".comma-custom-theme-studio__channel-fill"
        ) as HTMLElement
      ).style.background
    ).toBe(`oklch(${sampleLightness} 0 0)`);
    expect(
      (
        byChannel.lightness.querySelector(
          ".comma-custom-theme-studio__channel-fill"
        ) as HTMLElement
      ).style.color
    ).toBe("oklch(0.98 0 0)");

    fireEvent.pointerUp(pad, { clientX: 150, clientY: 40, pointerId: 1 });
    await waitFor(() =>
      expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
        "270deg"
      )
    );
    expect(document.documentElement.style.getPropertyValue("--comma-theme-c")).toBe(
      chromaBefore
    );
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-l")
      )
    ).toBeCloseTo(sampleLightness, 5);
  });

  it("keeps every indicator inside the canvas when dragged past the edge", async () => {
    const pad = renderStudio(separatedColor);
    const rest = channelCenter(
      "hue",
      separatedColor.hue,
      separatedColor.chroma,
      separatedColor.lightness,
      200,
      100
    );
    fireEvent.pointerDown(pad, { clientX: rest.x, clientY: rest.y, pointerId: 1 });
    fireEvent.pointerMove(pad, { clientX: -80, clientY: 140, pointerId: 1 });

    const indicators = [...pad.querySelectorAll("[data-slot='studio-indicator']")];
    expect(indicators).toHaveLength(3);
    for (const indicator of indicators) {
      expect(pad.contains(indicator)).toBe(true);
    }

    await waitFor(() => {
      for (const indicator of indicators) {
        const { x, y } = parseTranslate(indicator);
        expect(x).toBeGreaterThanOrEqual(-floatSlack);
        expect(y).toBeGreaterThanOrEqual(-floatSlack);
        expect(x).toBeLessThanOrEqual(200 - INDICATOR_VISUAL_SIZE + floatSlack);
        expect(y).toBeLessThanOrEqual(100 - INDICATOR_VISUAL_SIZE + floatSlack);
      }
    });
  });

  it("announces keyboard mutations on each channel slider", () => {
    renderStudio();
    const hue = screen.getByRole("slider", { name: "Hue" });
    const chroma = screen.getByRole("slider", { name: "Chroma" });
    const lightness = screen.getByRole("slider", { name: "Lightness" });

    const hueNow = hue.getAttribute("aria-valuenow");
    fireEvent.keyDown(hue, { key: "ArrowRight" });
    expect(hue).not.toHaveAttribute("aria-valuenow", hueNow ?? "");

    fireEvent.keyDown(lightness, { key: "End" });
    expect(lightness).toHaveAttribute("aria-valuenow", "64");
    fireEvent.keyDown(lightness, { key: "Home" });
    expect(lightness).toHaveAttribute("aria-valuenow", "36");

    fireEvent.keyDown(chroma, { key: "Home" });
    expect(chroma).toHaveAttribute("aria-valuenow", "0");
  });

  it("implements the complete bounded Hue slider keyboard range", () => {
    renderStudio({
      hue: 180,
      chroma: defaults.customChroma,
      lightness: defaults.customLightness,
    });
    const hue = screen.getByRole("slider", { name: "Hue" });

    expect(hue).toHaveAttribute("aria-valuemin", "0");
    expect(hue).toHaveAttribute("aria-valuemax", "360");
    expect(hue).toHaveAttribute("aria-valuenow", "180");

    fireEvent.keyDown(hue, { key: "ArrowUp" });
    expect(hue).toHaveAttribute("aria-valuenow", "181");
    fireEvent.keyDown(hue, { key: "ArrowDown" });
    expect(hue).toHaveAttribute("aria-valuenow", "180");
    fireEvent.keyDown(hue, { key: "ArrowRight" });
    expect(hue).toHaveAttribute("aria-valuenow", "181");
    fireEvent.keyDown(hue, { key: "ArrowLeft" });
    expect(hue).toHaveAttribute("aria-valuenow", "180");

    fireEvent.keyDown(hue, { key: "Home" });
    expect(hue).toHaveAttribute("aria-valuenow", "0");
    fireEvent.keyDown(hue, { key: "ArrowLeft" });
    expect(hue).toHaveAttribute("aria-valuenow", "0");
    fireEvent.keyDown(hue, { key: "ArrowDown" });
    expect(hue).toHaveAttribute("aria-valuenow", "0");
    fireEvent.keyDown(hue, { key: "End" });
    expect(hue).toHaveAttribute("aria-valuenow", "360");
    fireEvent.keyDown(hue, { key: "ArrowRight" });
    expect(hue).toHaveAttribute("aria-valuenow", "360");
    fireEvent.keyDown(hue, { key: "ArrowUp" });
    expect(hue).toHaveAttribute("aria-valuenow", "360");
  });

  it("announces a near-seam Hue as the supported upper endpoint", () => {
    renderStudio({
      hue: 359.6,
      chroma: defaults.customChroma,
      lightness: defaults.customLightness,
    });

    const hue = screen.getByRole("slider", { name: "Hue" });
    expect(hue).toHaveAttribute("aria-valuenow", "360");
    fireEvent.keyDown(hue, { key: "ArrowDown" });
    expect(hue).toHaveAttribute("aria-valuenow", "359");
  });
});

// Exercise the Electron settings owner with controlled save acknowledgments.
describe("CustomThemeStudio with asynchronous settings", () => {
  beforeEach(() => initializeCommaI18n(["en"]));

  afterEach(() => {
    Reflect.deleteProperty(globalThis, "commaNative");
    delete document.documentElement.dataset.theme;
    delete document.documentElement.dataset.commaTheme;
  });

  function renderElectronStudio() {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
      clientSettings: {
        ...structuredClone(defaultCommaClientSettings),
        appearance: {
          ...defaults,
          theme: "custom",
          customHue: separatedColor.hue,
          customChroma: separatedColor.chroma,
          customLightness: separatedColor.lightness,
        },
      },
    });
    const saves: Array<{
      patch: AppPreferencesPatch;
      resolve: (snapshot: AppPreferences) => void;
      reject: (error: Error) => void;
    }> = [];
    const update = vi.fn(
      (patch: AppPreferencesPatch) =>
        new Promise<AppPreferences>((resolve, reject) => {
          saves.push({ patch, resolve, reject });
        })
    );
    const state = createNativeStateBridgeMock(() => preferences);
    installNativeBridgeMock({
      platform: "electron",
      appPreferences: { state, update },
    });
    render(
      <CommaElectronClientSettingsProvider initialPreferences={preferences}>
        <CommaAppearanceProvider>
          <CommaI18nProvider>
            <CustomThemeStudio />
          </CommaI18nProvider>
        </CommaAppearanceProvider>
      </CommaElectronClientSettingsProvider>
    );
    const pad = screen.getByRole("group", { name: padName });
    pad.getBoundingClientRect = () => padRect;
    const hueSlider = screen.getByRole("slider", { name: "Hue" });
    const root = document.documentElement;
    const hue = () => hueSlider.getAttribute("aria-valuenow");
    const rootHue = () => root.style.getPropertyValue("--comma-theme-h");
    const beginDrag = () => {
      const rest = channelCenter("hue", 90, 0.08, 0.56, 200, 100);
      fireEvent.pointerDown(pad, {
        clientX: rest.x,
        clientY: rest.y,
        pointerId: 1,
      });
    };
    const move = (x: number) =>
      fireEvent.pointerMove(pad, { clientX: x, clientY: 40, pointerId: 1 });
    const release = () => fireEvent.pointerUp(pad, { pointerId: 1 });
    const accept = async (index: number) => {
      const save = saves[index]!;
      preferences = appPreferencesSchema.parse({
        ...preferences,
        revision: preferences.revision + 1,
        clientSettings: {
          ...preferences.clientSettings,
          appearance: {
            ...preferences.clientSettings!.appearance,
            ...save.patch.clientSettings?.appearance,
          },
        },
      });
      await act(async () => save.resolve(preferences));
    };
    const reject = async (index: number) => {
      await act(async () => saves[index]!.reject(new Error("Save failed")));
    };
    return { pad, hue, rootHue, beginDrag, move, release, accept, reject, update };
  }

  it("keeps the draft visible until Main accepts the released color", async () => {
    const studio = renderElectronStudio();
    studio.beginDrag();
    studio.move(150);
    expect(studio.hue()).toBe("270");
    expect(studio.rootHue()).toBe("90deg");
    expect(studio.update).not.toHaveBeenCalled();

    studio.release();
    expect(studio.update).toHaveBeenCalledTimes(1);
    expect(studio.hue()).toBe("270");
    expect(studio.rootHue()).toBe("90deg");

    await studio.accept(0);
    expect(studio.hue()).toBe("270");
    expect(studio.rootHue()).toBe("270deg");
  });

  it("restores the owner color after a failed save and permits another drag", async () => {
    const studio = renderElectronStudio();
    studio.beginDrag();
    studio.move(150);
    studio.release();
    expect(studio.hue()).toBe("270");

    await studio.reject(0);
    expect(studio.hue()).toBe("90");
    expect(studio.rootHue()).toBe("90deg");

    studio.beginDrag();
    studio.move(100);
    studio.release();
    await studio.accept(1);
    expect(studio.hue()).toBe("180");
    expect(studio.rootHue()).toBe("180deg");
    expect(studio.update).toHaveBeenCalledTimes(2);
  });

  it("does not clear a newer drag when the previous save settles", async () => {
    const studio = renderElectronStudio();
    studio.beginDrag();
    studio.move(150);
    studio.release();

    const rest = channelCenter("hue", 270, 0.08, 0.56, 200, 100);
    fireEvent.pointerDown(studio.pad, {
      clientX: rest.x,
      clientY: rest.y,
      pointerId: 1,
    });
    studio.move(100);
    expect(studio.hue()).toBe("180");
    await studio.accept(0);
    expect(studio.hue()).toBe("180");
    expect(studio.rootHue()).toBe("270deg");
    expect(studio.update).toHaveBeenCalledTimes(1);

    studio.release();
    expect(studio.hue()).toBe("180");
    await studio.accept(1);
    expect(studio.hue()).toBe("180");
    expect(studio.rootHue()).toBe("180deg");
    expect(studio.update).toHaveBeenCalledTimes(2);
  });
});
