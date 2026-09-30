/**
 * Border width tokens — Comma Design System.
 * Source: Figma component strokes (e.g. Toast shell uses border-primary at 0.5px).
 *
 * Note: CSS custom property names cannot contain `.` — use `0-5`, not `0.5`.
 */
export const borderWidth = {
  "0-5": 0.5,
  default: 1,
} as const;

export type BorderWidthKey = keyof typeof borderWidth;
