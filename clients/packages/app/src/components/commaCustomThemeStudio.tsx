/* oxlint-disable jsx-a11y/no-autofocus, jsx-a11y/prefer-tag-over-role -- The popover moves focus to its active panel; the pad is a 2D OKLCH control and the theme list is a custom picker, so native input/select would change the interaction and layout. */
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  ChevronLeftSmallIcon,
  commaThemeChromaGainMax,
  commaThemeLightnessMax,
  commaThemeLightnessMin,
  commaThemeLightnessToPad,
  commaThemePadToLightness,
  Dropdown,
  isReducedMotionEnabled,
  MenuPopover,
  MoonIcon,
  oklchChromaEnvelope,
  SunIcon,
  subscribeToReducedMotion,
} from "@comma/ui";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { Dialog as AriaDialog } from "react-aria-components";
import {
  defaultCommaAppearancePreferences,
  resolveCommaThemeSeed,
  useCommaAppearance,
  type CommaCustomSchemePreference,
  type CommaThemePreference,
} from "./commaAppearance";
import type { CommaUiThemeName } from "./commaUiTheme";

const CHROMA_STEP = commaThemeChromaGainMax / 100;
const HUE_MIN = 0;
const HUE_MAX = 360;
const HUE_SPAN = HUE_MAX - HUE_MIN;
const HUE_STEP = 1;
const LIGHTNESS_STEP = 0.01;
const PRESET_CHROMA_EPSILON = 0.004;
const HUE_FLOOR_CHROMA = 0.1;
/** Idle indicator size vs the 22px chip (1.2 × 1.2 × 1.2). */
const INDICATOR_SCALE = 1.728;

export const customThemePresets = [
  { hue: 263 },
  { hue: 300 },
  { hue: 348 },
  { hue: 22 },
  { hue: 48 },
  { hue: 145 },
  { hue: 188 },
] as const;

/** Visual diameter of each channel dot (`22px` × 1.728). */
export const INDICATOR_VISUAL_SIZE = (20 + 2) * INDICATOR_SCALE;
/** Extra scale applied to the indicator currently being dragged. */
export const INDICATOR_ACTIVE_SCALE = 1.2;
const SETTLE_RESPONSE = 0.3;

export const indicatorChannels = ["lightness", "chroma", "hue"] as const;
export type IndicatorChannel = (typeof indicatorChannels)[number];

export const indicatorGlyphs = {
  lightness: "L",
  chroma: "C",
  hue: "H",
} as const;

type SpringState = { x: number; y: number; vx: number; vy: number };
type ChannelPoint = { x: number; y: number };
type ChannelColor = { hue: number; chroma: number; lightness: number };

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

export const wrapHue = (value: number) =>
  ((((value - HUE_MIN) % HUE_SPAN) + HUE_SPAN) % HUE_SPAN) + HUE_MIN;

const hueFromUnit = (unit: number) => HUE_MIN + clamp(unit, 0, 1) * HUE_SPAN;

const hueToUnit = (hue: number) => (clamp(hue, HUE_MIN, HUE_MAX) - HUE_MIN) / HUE_SPAN;

export const chromaToPercent = (chroma: number) =>
  Math.round((chroma / commaThemeChromaGainMax) * 100);

export const lightnessToPercent = (lightness: number) => Math.round(lightness * 100);

export const rubberband = (overshoot: number, dimension: number, constant = 0.55) => {
  if (dimension <= 0) return 0;
  return (
    (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot))
  );
};

const dampedUnit = (unit: number, size: number) => {
  if (unit < 0) return -rubberband(-unit * size, size) / size;
  if (unit > 1) return 1 + rubberband((unit - 1) * size, size) / size;
  return unit;
};

export const mapPadPointer = (
  clientX: number,
  clientY: number,
  rect: DOMRect
): {
  chroma: number;
  hue: number;
  lightness: number;
  visualX: number;
  visualY: number;
} => {
  const visualX = dampedUnit((clientX - rect.left) / rect.width, rect.width);
  const visualY = dampedUnit((clientY - rect.top) / rect.height, rect.height);
  return {
    chroma: (1 - clamp(visualY, 0, 1)) * commaThemeChromaGainMax,
    hue: hueFromUnit(visualX),
    lightness: 1 - clamp(visualY, 0, 1),
    visualX,
    visualY,
  };
};

/** Each indicator owns one oklch-picker plane and writes two sample axes. */
export const sampleFromPlane = (
  plane: IndicatorChannel,
  visualX: number,
  visualY: number,
  current: ChannelColor
): ChannelColor => {
  const hue = hueFromUnit(visualX);
  const displayedC = (1 - clamp(visualY, 0, 1)) * commaThemeChromaGainMax;
  const lightnessFromY = commaThemePadToLightness(1 - clamp(visualY, 0, 1));
  const lightnessFromX = commaThemePadToLightness(clamp(visualX, 0, 1));
  const gainFromDisplayed = (lightness: number) => {
    const envelope = oklchChromaEnvelope(clamp(lightness, 0, 1));
    if (envelope <= 1e-9) return current.chroma;
    return clamp(displayedC / envelope, 0, commaThemeChromaGainMax);
  };
  if (plane === "hue") {
    return {
      hue,
      chroma: gainFromDisplayed(current.lightness),
      lightness: current.lightness,
    };
  }
  if (plane === "chroma") {
    return {
      hue: current.hue,
      chroma: gainFromDisplayed(lightnessFromX),
      lightness: lightnessFromX,
    };
  }
  return { hue, chroma: current.chroma, lightness: lightnessFromY };
};

const capturePointer = (target: HTMLElement, pointerId: number) => {
  if (typeof target.setPointerCapture !== "function") return;
  try {
    target.setPointerCapture(pointerId);
  } catch {
    // jsdom throws when the pointer is not active.
  }
};

const stepSpring = (
  state: SpringState,
  targetX: number,
  targetY: number,
  dt: number,
  omega: number
) => {
  const damping = 2 * omega;
  const ax = omega * omega * (targetX - state.x) - damping * state.vx;
  const ay = omega * omega * (targetY - state.y) - damping * state.vy;
  state.vx += ax * dt;
  state.vy += ay * dt;
  state.x += state.vx * dt;
  state.y += state.vy * dt;
};

const emptySpring = (): SpringState => ({ x: 0, y: 0, vx: 0, vy: 0 });

export const clampChannelCenter = (
  point: ChannelPoint,
  width: number,
  height: number,
  size: number = INDICATOR_VISUAL_SIZE
): ChannelPoint => {
  const half = size / 2;
  return {
    x: clamp(point.x, half, Math.max(half, width - half)),
    y: clamp(point.y, half, Math.max(half, height - half)),
  };
};

/**
 * One OKLCH sample projected onto the three oklch-picker planes:
 * hue on H×C, chroma on L×C, lightness on H×L. Sample chroma is
 * C = gain · 4L(1−L). Dragging one plane rewrites two axes; the
 * other indicators follow from the same sample.
 */
export const sampleChroma = (gain: number, lightness: number) =>
  gain * oklchChromaEnvelope(clamp(lightness, 0, 1));

const chromaAxisY = (gain: number, lightness: number, height: number) =>
  (1 - sampleChroma(gain, lightness) / commaThemeChromaGainMax) * height;

export const channelCenter = (
  channel: IndicatorChannel,
  hue: number,
  chroma: number,
  lightness: number,
  width: number,
  height: number
): ChannelPoint => {
  const light = clamp(lightness, 0, 1);
  const lightPad = commaThemeLightnessToPad(lightness);
  const hueX = hueToUnit(hue) * width;
  const chromaY = chromaAxisY(chroma, light, height);
  if (channel === "hue") return { x: hueX, y: chromaY };
  if (channel === "chroma") return { x: lightPad * width, y: chromaY };
  return { x: hueX, y: (1 - lightPad) * height };
};

export const channelTarget = (
  channel: IndicatorChannel,
  hue: number,
  chroma: number,
  lightness: number,
  width: number,
  height: number,
  size: number = INDICATOR_VISUAL_SIZE
) =>
  clampChannelCenter(
    channelCenter(channel, hue, chroma, lightness, width, height),
    width,
    height,
    size
  );

export const nearestChannel = (
  x: number,
  y: number,
  hue: number,
  chroma: number,
  lightness: number,
  width: number,
  height: number
): IndicatorChannel => {
  let best: IndicatorChannel = "hue";
  let bestDist = Number.POSITIVE_INFINITY;
  for (const channel of indicatorChannels.toReversed()) {
    const point = channelTarget(channel, hue, chroma, lightness, width, height);
    const dist = (point.x - x) ** 2 + (point.y - y) ** 2;
    if (dist < bestDist) {
      bestDist = dist;
      best = channel;
    }
  }
  return best;
};

/** Dragged indicator follows the pointer; the other two follow the sample. */
export const channelFollow = (
  channel: IndicatorChannel,
  plane: IndicatorChannel,
  visualX: number,
  visualY: number,
  sample: ChannelColor,
  width: number,
  height: number
): ChannelPoint => {
  if (channel === plane) return { x: visualX * width, y: visualY * height };
  return channelCenter(
    channel,
    sample.hue,
    sample.chroma,
    sample.lightness,
    width,
    height
  );
};

const envelopeChroma = (chroma: number, lightness: number) =>
  chroma * oklchChromaEnvelope(lightness);

export const channelFill = (
  channel: IndicatorChannel,
  hue: number,
  chroma: number,
  lightness: number
) => {
  const h = wrapHue(hue);
  const l = clamp(lightness, 0, 1);
  const sample = envelopeChroma(chroma, l);
  if (channel === "lightness") return `oklch(${l} 0 0)`;
  if (channel === "chroma") return `oklch(${l} ${sample} ${h})`;
  return `oklch(${l} ${Math.max(sample, HUE_FLOOR_CHROMA)} ${h})`;
};

export const channelGlyphColor = (lightness: number) =>
  clamp(lightness, 0, 1) >= 0.6 ? "oklch(0.2 0 0)" : "oklch(0.98 0 0)";

const paintChannelFill = (
  fill: HTMLElement,
  channel: IndicatorChannel,
  color: ChannelColor
) => {
  fill.style.background = channelFill(
    channel,
    color.hue,
    color.chroma,
    color.lightness
  );
  fill.style.color = channelGlyphColor(color.lightness);
};

const presetChroma = defaultCommaAppearancePreferences.customChroma;

const createChannelRecord = <T,>(value: () => T): Record<IndicatorChannel, T> => ({
  lightness: value(),
  chroma: value(),
  hue: value(),
});

export function CustomThemeStudio() {
  const m = useCommaMessages();
  const {
    customChroma,
    customHue,
    customLightness,
    customScheme,
    setCustomChroma,
    setCustomColor,
    setCustomHue,
    setCustomLightness,
    setCustomScheme,
  } = useCommaAppearance();

  const canvasRef = useRef<HTMLDivElement>(null);
  const indicatorNodes = useRef(
    createChannelRecord(() => null as HTMLSpanElement | null)
  );
  const fillNodes = useRef(createChannelRecord(() => null as HTMLSpanElement | null));
  const springs = useRef(createChannelRecord(emptySpring));
  const targets = useRef(createChannelRecord((): ChannelPoint => ({ x: 0, y: 0 })));
  const colorRef = useRef<ChannelColor>({
    hue: customHue,
    chroma: customChroma,
    lightness: customLightness,
  });
  const padPointer = useRef<number | null>(null);
  const draggingChannel = useRef<IndicatorChannel | null>(null);
  const snapIndicator = useRef(true);
  const seeded = useRef(false);
  const wakeAnimation = useRef<(() => void) | undefined>(undefined);
  // A drag edits this local draft only. Every settings write restyles the
  // whole app (and persists through Main to every window), so the drag
  // commits once on release and keeps the draft until that write settles.
  const [draft, setDraft] = useState<ChannelColor | null>(null);
  const hue = draft?.hue ?? customHue;
  const chroma = draft?.chroma ?? customChroma;
  const lightness = draft?.lightness ?? customLightness;
  if (padPointer.current === null) {
    colorRef.current = { hue, chroma, lightness };
  }

  const chromaPercent = chromaToPercent(chroma);
  const lightnessPercent = lightnessToPercent(lightness);
  const roundedHue = Math.round(clamp(hue, HUE_MIN, HUE_MAX));

  const applyChannelTargets = useCallback(
    (color: ChannelColor, width: number, height: number) => {
      for (const channel of indicatorChannels) {
        targets.current[channel] = channelTarget(
          channel,
          color.hue,
          color.chroma,
          color.lightness,
          width,
          height
        );
      }
      wakeAnimation.current?.();
    },
    []
  );

  const handleScheme = useCallback(
    (scheme: CommaCustomSchemePreference) => {
      setCustomScheme(scheme);
    },
    [setCustomScheme]
  );

  const handlePadPointer = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const canvas = canvasRef.current;
    const plane = draggingChannel.current;
    if (!canvas || plane === null) return;
    if (event.pointerId !== padPointer.current) return;
    const rect = canvas.getBoundingClientRect();
    const next = mapPadPointer(event.clientX, event.clientY, rect);
    const sample = sampleFromPlane(plane, next.visualX, next.visualY, colorRef.current);
    const activeSize = INDICATOR_VISUAL_SIZE * INDICATOR_ACTIVE_SCALE;
    for (const channel of indicatorChannels) {
      const size = channel === plane ? activeSize : INDICATOR_VISUAL_SIZE;
      targets.current[channel] = clampChannelCenter(
        channelFollow(
          channel,
          plane,
          next.visualX,
          next.visualY,
          sample,
          rect.width,
          rect.height
        ),
        rect.width,
        rect.height,
        size
      );
      const fill = fillNodes.current[channel];
      if (fill) {
        paintChannelFill(fill, channel, sample);
      }
    }
    snapIndicator.current = false;
    colorRef.current = sample;
    setDraft(sample);
    wakeAnimation.current?.();
  }, []);

  const handlePadPointerDown = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (padPointer.current !== null) return;
      const canvas = canvasRef.current;
      if (!canvas) return;
      event.preventDefault();
      const rect = canvas.getBoundingClientRect();
      draggingChannel.current = nearestChannel(
        event.clientX - rect.left,
        event.clientY - rect.top,
        colorRef.current.hue,
        colorRef.current.chroma,
        colorRef.current.lightness,
        rect.width,
        rect.height
      );
      padPointer.current = event.pointerId;
      capturePointer(event.currentTarget, event.pointerId);
      handlePadPointer(event);
    },
    [handlePadPointer]
  );

  const handlePadPointerUp = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (event.pointerId !== padPointer.current) return;
      const committed = colorRef.current;
      const canvas = canvasRef.current;
      if (canvas) {
        const rect = canvas.getBoundingClientRect();
        applyChannelTargets(committed, rect.width, rect.height);
      }
      padPointer.current = null;
      draggingChannel.current = null;
      void setCustomColor(committed.hue, committed.chroma, committed.lightness).finally(
        () => setDraft((current) => (current === committed ? null : current))
      );
    },
    [applyChannelTargets, setCustomColor]
  );

  const handleIndicatorKeyDown = useCallback(
    (channel: IndicatorChannel) => (event: ReactKeyboardEvent<HTMLSpanElement>) => {
      const left = event.key === "ArrowLeft";
      const right = event.key === "ArrowRight";
      const up = event.key === "ArrowUp";
      const down = event.key === "ArrowDown";
      const delta = right || up ? 1 : -1;
      if (channel === "hue" && (left || right || up || down)) {
        event.preventDefault();
        snapIndicator.current = true;
        setCustomHue(clamp(roundedHue + delta * HUE_STEP, HUE_MIN, HUE_MAX));
        return;
      }
      if (channel === "chroma" && (left || right || up || down)) {
        event.preventDefault();
        snapIndicator.current = true;
        setCustomChroma(
          clamp(chroma + delta * CHROMA_STEP, 0, commaThemeChromaGainMax)
        );
        return;
      }
      if (channel === "lightness" && (left || right || up || down)) {
        event.preventDefault();
        snapIndicator.current = true;
        setCustomLightness(
          clamp(
            lightness + delta * LIGHTNESS_STEP,
            commaThemeLightnessMin,
            commaThemeLightnessMax
          )
        );
        return;
      }
      if (event.key === "Home") {
        event.preventDefault();
        snapIndicator.current = true;
        if (channel === "hue") setCustomHue(HUE_MIN);
        else if (channel === "chroma") setCustomChroma(0);
        else setCustomLightness(commaThemeLightnessMin);
        return;
      }
      if (event.key === "End") {
        event.preventDefault();
        snapIndicator.current = true;
        if (channel === "hue") setCustomHue(HUE_MAX);
        else if (channel === "chroma") setCustomChroma(commaThemeChromaGainMax);
        else setCustomLightness(commaThemeLightnessMax);
      }
    },
    [chroma, lightness, roundedHue, setCustomChroma, setCustomHue, setCustomLightness]
  );

  const handlePreset = useCallback(
    (presetHue: number) => {
      snapIndicator.current = true;
      void setCustomColor(presetHue, presetChroma);
    },
    [setCustomColor]
  );

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    if (padPointer.current !== null) return;
    const rect = canvas.getBoundingClientRect();
    applyChannelTargets({ hue, chroma, lightness }, rect.width, rect.height);
    if (!seeded.current) {
      for (const channel of indicatorChannels) {
        springs.current[channel].x = targets.current[channel].x;
        springs.current[channel].y = targets.current[channel].y;
        springs.current[channel].vx = 0;
        springs.current[channel].vy = 0;
      }
      seeded.current = true;
    }
  }, [applyChannelTargets, chroma, hue, lightness]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || typeof ResizeObserver === "undefined") return;
    // The pad owns one observer; resizing is another target change, not an
    // idle reason to keep its three indicators on the animation clock.
    const observer = new ResizeObserver(([entry]) => {
      if (padPointer.current !== null) return;
      // Popover entrance transforms do not change the pad's local coordinates.
      if (entry)
        applyChannelTargets(
          colorRef.current,
          entry.contentRect.width,
          entry.contentRect.height
        );
    });
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [applyChannelTargets]);

  useEffect(() => {
    let frame = 0;
    let last = performance.now();
    let reduced = isReducedMotionEnabled();
    const half = INDICATOR_VISUAL_SIZE / 2;

    const tick = (now: number) => {
      frame = 0;
      const dt = Math.min(0.032, (now - last) / 1000);
      last = now;
      let moving = false;
      const dragging = padPointer.current !== null;
      const snap = snapIndicator.current;
      if (snap) snapIndicator.current = false;
      for (const channel of indicatorChannels) {
        const node = indicatorNodes.current[channel];
        const state = springs.current[channel];
        const target = targets.current[channel];
        if (!node) continue;
        if (dragging || reduced || snap) {
          state.x = target.x;
          state.y = target.y;
          state.vx = 0;
          state.vy = 0;
        } else {
          stepSpring(state, target.x, target.y, dt, (2 * Math.PI) / SETTLE_RESPONSE);
          if (
            Math.abs(state.x - target.x) < 0.01 &&
            Math.abs(state.y - target.y) < 0.01 &&
            Math.abs(state.vx) < 0.05 &&
            Math.abs(state.vy) < 0.05
          ) {
            state.x = target.x;
            state.y = target.y;
            state.vx = 0;
            state.vy = 0;
          } else {
            moving = true;
          }
        }
        node.dataset.dragging = draggingChannel.current === channel ? "true" : "false";
        node.style.transform = `translate3d(${state.x - half}px, ${state.y - half}px, 0)`;
        const fill = fillNodes.current[channel];
        if (fill) {
          paintChannelFill(fill, channel, colorRef.current);
        }
      }
      if (moving) frame = requestAnimationFrame(tick);
    };
    const wake = () => {
      if (frame) return;
      last = performance.now();
      frame = requestAnimationFrame(tick);
    };
    wakeAnimation.current = wake;
    const unsubscribe = subscribeToReducedMotion(() => {
      reduced = isReducedMotionEnabled();
      wake();
    });
    wake();
    return () => {
      wakeAnimation.current = undefined;
      cancelAnimationFrame(frame);
      unsubscribe();
    };
  }, []);

  const schemes: Array<{
    id: CommaCustomSchemePreference;
    label: string;
    icon?: typeof SunIcon;
  }> = [
    { id: "system", label: m.settings_appearance_system() },
    { id: "light", label: m.settings_appearance_light(), icon: SunIcon },
    { id: "dark", label: m.settings_appearance_dark(), icon: MoonIcon },
  ];

  return (
    <div className="comma-custom-theme-studio" data-slot="custom-theme-studio">
      <div
        className="comma-custom-theme-studio__stage comma-custom-theme-studio__chunk"
        data-chunk="0"
      >
        <div className="comma-custom-theme-studio__scheme" data-slot="studio-scheme">
          {schemes.map((scheme) => {
            const Icon = scheme.icon;
            return (
              <Button
                aria-label={scheme.label}
                aria-pressed={customScheme === scheme.id}
                className="text-secondary"
                data-slot="studio-press"
                hierarchy="tertiary-gray"
                {...(Icon ? { iconLeading: <Icon /> } : {})}
                iconOnly={Boolean(Icon)}
                key={scheme.id}
                onPress={() => handleScheme(scheme.id)}
                size="xs"
              >
                {Icon ? null : scheme.label}
              </Button>
            );
          })}
        </div>
        <div
          aria-label={m.settings_theme_custom_canvas()}
          className="comma-custom-theme-studio__canvas cursor-pointer"
          onPointerCancel={handlePadPointerUp}
          onPointerDown={handlePadPointerDown}
          onPointerMove={handlePadPointer}
          onPointerUp={handlePadPointerUp}
          ref={canvasRef}
          role="group"
        >
          <p aria-hidden="true" className="comma-custom-theme-studio__readout">
            <span>
              {m.settings_theme_custom_lightness()}
              <span className="comma-custom-theme-studio__readout-value">
                {lightnessPercent}
              </span>
            </span>
            <span>
              {m.settings_theme_custom_chroma()}
              <span className="comma-custom-theme-studio__readout-value">
                {chromaPercent}
              </span>
            </span>
            <span>
              {m.settings_theme_custom_hue()}
              <span className="comma-custom-theme-studio__readout-value">
                {roundedHue}°
              </span>
            </span>
          </p>
          {indicatorChannels.map((channel) => {
            const valueNow =
              channel === "hue"
                ? roundedHue
                : channel === "chroma"
                  ? chromaPercent
                  : lightnessPercent;
            const valueMin =
              channel === "hue"
                ? HUE_MIN
                : channel === "chroma"
                  ? 0
                  : Math.round(commaThemeLightnessMin * 100);
            const valueMax =
              channel === "hue"
                ? HUE_MAX
                : channel === "chroma"
                  ? 100
                  : Math.round(commaThemeLightnessMax * 100);
            const valueText =
              channel === "hue"
                ? `${roundedHue}°`
                : channel === "chroma"
                  ? String(chromaPercent)
                  : String(lightnessPercent);
            const name =
              channel === "hue"
                ? m.settings_theme_custom_hue()
                : channel === "chroma"
                  ? m.settings_theme_custom_chroma()
                  : m.settings_theme_custom_lightness();
            return (
              <span
                aria-label={name}
                aria-orientation="horizontal"
                aria-valuemax={valueMax}
                aria-valuemin={valueMin}
                aria-valuenow={valueNow}
                aria-valuetext={valueText}
                className="comma-custom-theme-studio__channel"
                data-channel={channel}
                data-slot="studio-indicator"
                key={channel}
                onKeyDown={handleIndicatorKeyDown(channel)}
                ref={(node) => {
                  indicatorNodes.current[channel] = node;
                }}
                role="slider"
                tabIndex={0}
              >
                <span
                  className="comma-custom-theme-studio__channel-fill"
                  ref={(node) => {
                    fillNodes.current[channel] = node;
                  }}
                  style={{
                    background: channelFill(channel, hue, chroma, lightness),
                    color: channelGlyphColor(lightness),
                  }}
                >
                  {indicatorGlyphs[channel]}
                </span>
              </span>
            );
          })}
        </div>
      </div>
      <div
        aria-label={m.settings_theme_custom_swatches()}
        className="comma-custom-theme-studio__swatches comma-custom-theme-studio__chunk"
        data-chunk="1"
        role="group"
      >
        {customThemePresets.map((preset) => {
          const selected =
            roundedHue === preset.hue &&
            Math.abs(chroma - presetChroma) < PRESET_CHROMA_EPSILON;
          return (
            <button
              aria-label={m.settings_theme_custom_swatch({ hue: String(preset.hue) })}
              aria-pressed={selected}
              className="comma-custom-theme-studio__swatch"
              key={preset.hue}
              onClick={() => handlePreset(preset.hue)}
              type="button"
            >
              <span
                className="comma-custom-theme-studio__swatch-chip"
                style={{ background: `oklch(0.74 0.12 ${preset.hue})` }}
              />
            </button>
          );
        })}
      </div>
    </div>
  );
}

type ThemePickerId = Exclude<CommaThemePreference, "twilight" | "ink">;

const themePickerItems: Array<{
  id: ThemePickerId;
  separatorBefore?: boolean;
}> = [
  { id: "default" },
  { id: "light", separatorBefore: true },
  { id: "signal-light" },
  { id: "dark", separatorBefore: true },
  { id: "signal-dark" },
  { id: "custom", separatorBefore: true },
];

function themePickerScheme(
  id: CommaThemePreference,
  systemTheme: CommaUiThemeName,
  customScheme: CommaCustomSchemePreference
): CommaUiThemeName {
  if (id === "default" || id === "light" || id === "signal-light") return "Light mode";
  if (id === "dark" || id === "signal-dark") return "Dark mode";
  if (customScheme === "dark") return "Dark mode";
  if (customScheme === "light") return "Light mode";
  return systemTheme;
}

function ThemeSwatch({
  preset,
  scheme,
}: {
  preset: CommaThemePreference;
  scheme: CommaUiThemeName;
}) {
  const { customChroma, customHue, customLightness } = useCommaAppearance();
  const seed = resolveCommaThemeSeed(
    preset,
    scheme,
    customHue,
    customChroma,
    customLightness
  );
  const style = {
    colorScheme: scheme === "Dark mode" ? "dark" : "light",
    ["--comma-theme-h" as const]: `${seed.hueDeg}deg`,
    ["--comma-theme-c" as const]: String(seed.chroma),
    ...(preset === "custom"
      ? { ["--comma-swatch-l" as const]: String(seed.lightness) }
      : {}),
  } as CSSProperties;

  return (
    <span
      aria-hidden="true"
      className="comma-theme-swatch inline-flex h-5 shrink-0 items-center gap-xs rounded-md bg-primary px-xs shadow-[0_0_0_1px_var(--color-border-primary)]"
      data-slot="theme-swatch"
      data-theme={scheme}
      style={style}
    >
      <span className="size-1.5 rounded-full bg-current" />
      <span className="text-[11px] font-medium leading-none">Aa</span>
    </span>
  );
}

export function ThemePicker() {
  const m = useCommaMessages();
  const { customScheme, setTheme, systemTheme, theme } = useCommaAppearance();
  const [listOpen, setListOpen] = useState(false);
  const [studioOpen, setStudioOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const reopenListAfterStudioCloseRef = useRef(false);
  const descriptionId = useId();

  const labels: Record<ThemePickerId, string> = {
    default: m.settings_theme_default(),
    light: m.settings_theme_soft_light(),
    "signal-light": m.settings_theme_signal_light(),
    dark: m.settings_appearance_dark(),
    "signal-dark": m.settings_theme_signal_dark(),
    custom: m.settings_theme_custom(),
  };
  const selectedId: ThemePickerId =
    theme === "twilight" || theme === "ink" ? "dark" : theme;

  const openStudio = () => {
    reopenListAfterStudioCloseRef.current = false;
    setListOpen(false);
    setStudioOpen(true);
  };

  const backToThemes = () => {
    triggerRef.current?.focus({ preventScroll: true });
    reopenListAfterStudioCloseRef.current = true;
    setStudioOpen(false);
  };

  const setStudioPopoverRef = useCallback((popover: HTMLDivElement | null) => {
    if (popover || !reopenListAfterStudioCloseRef.current) return;
    // Let the outgoing focus scope finish before the Dropdown performs autofocus.
    reopenListAfterStudioCloseRef.current = false;
    setListOpen(true);
  }, []);

  return (
    <>
      <Dropdown
        ariaLabel={`${m.settings_theme_select()}: ${labels[selectedId]}`}
        className="comma-settings-dropdown"
        isOpen={listOpen}
        items={themePickerItems.map((item) => ({
          id: item.id,
          label: labels[item.id],
          leading: (
            <ThemeSwatch
              preset={item.id}
              scheme={themePickerScheme(item.id, systemTheme, customScheme)}
            />
          ),
          ...(item.separatorBefore ? { separatorBefore: true } : {}),
        }))}
        onChange={(id) => {
          setTheme(id as CommaThemePreference);
          if (id === "custom") openStudio();
        }}
        onOpenChange={(open) => {
          if (open && selectedId === "custom") {
            openStudio();
            return;
          }
          setListOpen(open);
        }}
        placeholder={m.settings_theme_select()}
        size="sm"
        triggerRef={triggerRef}
        value={selectedId}
        width="content"
      />
      <MenuPopover
        ref={setStudioPopoverRef}
        className="comma-custom-theme-studio-popover"
        dismissControlledNonModalOnInteractOutside
        isNonModal
        isOpen={studioOpen}
        onOpenChange={setStudioOpen}
        placement="bottom end"
        triggerRef={triggerRef}
      >
        <AriaDialog
          aria-describedby={descriptionId}
          aria-label={m.settings_theme_custom()}
          className="comma-custom-theme-studio-panel"
          data-slot="theme-picker-panel"
        >
          <header className="comma-custom-theme-studio-panel__header">
            <button
              aria-label={m.settings_theme_custom_back()}
              autoFocus
              className="comma-custom-theme-studio-panel__back"
              data-slot="studio-press"
              onClick={backToThemes}
              type="button"
            >
              <ChevronLeftSmallIcon className="size-5" />
            </button>
            <p
              className="comma-custom-theme-studio-panel__description"
              id={descriptionId}
            >
              {m.settings_theme_custom_studio_description()}
            </p>
          </header>
          <CustomThemeStudio />
        </AriaDialog>
      </MenuPopover>
    </>
  );
}
