/**
 * Border radius tokens (px) — Comma Design System.
 * Source: Figma "Spacing, radius & grids" page (node 5253:373828).
 */
export const radius = {
  none: 0,
  xxs: 2,
  xs: 4,
  sm: 6,
  md: 8,
  lg: 10,
  xl: 12,
  "2xl": 16,
  "3xl": 20,
  "4xl": 24,
  full: 9999,
} as const;

export type RadiusKey = keyof typeof radius;
