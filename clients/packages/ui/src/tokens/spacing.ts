/**
 * Spacing, width and container tokens (px) — Comma Design System.
 * Source: Figma "Spacing, radius & grids" page (node 5245:372829).
 */
export const spacing = {
  none: 0,
  xxs: 2,
  xs: 4,
  sm: 6,
  md: 8,
  lg: 12,
  xl: 16,
  "2xl": 20,
  "3xl": 24,
  "4xl": 32,
  "5xl": 40,
  "6xl": 48,
  "7xl": 64,
  "8xl": 80,
  "9xl": 96,
  "10xl": 128,
  "11xl": 160,
} as const;

export const width = {
  xxs: 320,
  xs: 384,
  sm: 480,
  md: 560,
  lg: 640,
  xl: 768,
  "2xl": 1024,
  "3xl": 1280,
  "4xl": 1440,
  "5xl": 1600,
  "6xl": 1920,
} as const;

export const container = {
  paddingMobile: 16,
  paddingDesktop: 32,
  maxWidthDesktop: 1280,
  paragraphMaxWidth: 720,
} as const;

export type SpacingKey = keyof typeof spacing;
export type WidthKey = keyof typeof width;
