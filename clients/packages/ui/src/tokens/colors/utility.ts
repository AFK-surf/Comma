/**
 * Utility color tokens (light mode) — Badge, Tag, and similar components.
 * Source: Figma Component colors → Utility.
 */
import { brand, error, success, warning } from "./brand";
import { grayLightMode as gray } from "./grays";
import { blue } from "./spectrum-cool";
import { indigo, orange, pink, purple } from "./spectrum-warm";

const spectrumUtility = (palette: Record<number, string>) =>
  ({
    "50": palette[50],
    "200": palette[200],
    "300": palette[300],
    "700": palette[700],
  }) as const;

const brandUtility = (palette: Record<number, string>) =>
  ({
    "50": palette[50],
    "100": palette[100],
    "200": palette[200],
    "300": palette[300],
    "400": palette[400],
    "700": palette[700],
  }) as const;

const grayUtility = (palette: typeof gray) =>
  ({
    "50": palette[50],
    "200": palette[200],
    "300": palette[300],
    "700": palette[700],
  }) as const;

export const utility = {
  gray: grayUtility(gray),
  brand: brandUtility(brand),
  error: spectrumUtility(error),
  warning: spectrumUtility(warning),
  success: spectrumUtility(success),
  blue: spectrumUtility(blue),
  indigo: spectrumUtility(indigo),
  purple: spectrumUtility(purple),
  pink: spectrumUtility(pink),
  orange: spectrumUtility(orange),
} as const;

/** Flat map for CSS variable emission (`--color-utility-brand-50`). */
export const utilityFlat = Object.fromEntries(
  Object.entries(utility).flatMap(([family, steps]) =>
    Object.entries(steps).map(([step, hex]) => [`${family}-${step}`, hex])
  )
) as Record<string, string>;
