/**
 * Utility color tokens (dark mode) — inverted scales for Badge, Tag, etc.
 * Source: Figma [data-theme="Dark mode"] → Component colors → Utility.
 */
import { brand, error, success, warning } from "./brand";
import { grayDarkMode as gray } from "./grays";
import { blue } from "./spectrum-cool";
import { indigo, orange, pink, purple } from "./spectrum-warm";

const spectrumUtilityDark = (palette: Record<number, string>) =>
  ({
    "50": palette[950],
    "200": palette[800],
    "300": palette[300],
    "700": palette[300],
  }) as const;

const brandUtilityDark = (palette: Record<number, string>) =>
  ({
    "50": palette[950],
    "100": palette[900],
    "200": palette[800],
    "300": palette[700],
    "400": palette[600],
    "700": palette[300],
  }) as const;

const grayUtilityDark = (palette: typeof gray) =>
  ({
    "50": palette[900],
    "200": palette[700],
    "300": palette[600],
    "700": palette[300],
  }) as const;

export const utilityDark = {
  gray: grayUtilityDark(gray),
  brand: brandUtilityDark(brand),
  error: spectrumUtilityDark(error),
  warning: spectrumUtilityDark(warning),
  success: spectrumUtilityDark(success),
  blue: spectrumUtilityDark(blue),
  indigo: spectrumUtilityDark(indigo),
  purple: spectrumUtilityDark(purple),
  pink: spectrumUtilityDark(pink),
  orange: spectrumUtilityDark(orange),
} as const;

export const utilityFlatDark = Object.fromEntries(
  Object.entries(utilityDark).flatMap(([family, steps]) =>
    Object.entries(steps).map(([step, hex]) => [`${family}-${step}`, hex])
  )
) as Record<string, string>;
