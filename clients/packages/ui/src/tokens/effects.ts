/**
 * Effect tokens — Comma Design System.
 * Source: Figma "Effect styles" page (node 1030:33573).
 * Values are ready-to-use CSS strings.
 *
 * Light elevation uses gray-blue pigment at low alpha. Dark mode keeps the same
 * geometry but switches to pure black at higher alpha so shadows stay visible on
 * window/popup surfaces (#0f0f10 / #18191b / #27282b).
 */
export const shadow = {
  xs: "0 1px 2px 0 rgba(16, 24, 40, 0.05)",
  sm: "0 1px 2px 0 rgba(16, 24, 40, 0.06), 0 1px 3px 0 rgba(16, 24, 40, 0.10)",
  md: "0 2px 4px -2px rgba(16, 24, 40, 0.06), 0 4px 8px -2px rgba(16, 24, 40, 0.10)",
  lg: "0 4px 6px -2px rgba(16, 24, 40, 0.03), 0 12px 16px -4px rgba(16, 24, 40, 0.08)",
  xl: "0 8px 8px -4px rgba(16, 24, 40, 0.03), 0 20px 24px -4px rgba(16, 24, 40, 0.08)",
  "2xl": "0 24px 48px -12px rgba(16, 24, 40, 0.18)",
  "3xl": "0 32px 64px -12px rgba(16, 24, 40, 0.14)",
} as const;

/** Dark-mode elevation map — same geometry as `shadow`, higher black alpha. */
export const shadowDark = {
  xs: "0 1px 2px 0 rgba(0, 0, 0, 0.32)",
  sm: "0 1px 2px 0 rgba(0, 0, 0, 0.36), 0 1px 3px 0 rgba(0, 0, 0, 0.48)",
  md: "0 2px 4px -2px rgba(0, 0, 0, 0.36), 0 4px 8px -2px rgba(0, 0, 0, 0.48)",
  lg: "0 4px 6px -2px rgba(0, 0, 0, 0.24), 0 12px 16px -4px rgba(0, 0, 0, 0.40)",
  xl: "0 8px 8px -4px rgba(0, 0, 0, 0.24), 0 20px 24px -4px rgba(0, 0, 0, 0.40)",
  "2xl": "0 24px 48px -12px rgba(0, 0, 0, 0.56)",
  "3xl": "0 32px 64px -12px rgba(0, 0, 0, 0.52)",
} as const;

export const focusRing = {
  brand: "0 0 0 4px rgba(16, 64, 242, 0.24)",
  gray: "0 0 0 4px rgba(152, 162, 179, 0.14)",
  graySecondary: "0 0 0 4px rgba(152, 162, 179, 0.20)",
  error: "0 0 0 4px rgba(240, 68, 56, 0.24)",
  brandShadowXs: `0 0 0 4px rgba(16, 64, 242, 0.24), ${shadow.xs}`,
  brandShadowSm: `0 0 0 4px rgba(16, 64, 242, 0.24), ${shadow.sm}`,
  grayShadowXs: `0 0 0 4px rgba(152, 162, 179, 0.14), ${shadow.xs}`,
  grayShadowSm: `0 0 0 4px rgba(152, 162, 179, 0.14), ${shadow.sm}`,
  errorShadowXs: `0 0 0 4px rgba(240, 68, 56, 0.24), ${shadow.xs}`,
} as const;

/** Dark focus rings — ring colors unchanged; elevation layers use `shadowDark`. */
export const focusRingDark = {
  brand: focusRing.brand,
  gray: focusRing.gray,
  graySecondary: focusRing.graySecondary,
  error: focusRing.error,
  brandShadowXs: `0 0 0 4px rgba(16, 64, 242, 0.24), ${shadowDark.xs}`,
  brandShadowSm: `0 0 0 4px rgba(16, 64, 242, 0.24), ${shadowDark.sm}`,
  grayShadowXs: `0 0 0 4px rgba(152, 162, 179, 0.14), ${shadowDark.xs}`,
  grayShadowSm: `0 0 0 4px rgba(152, 162, 179, 0.14), ${shadowDark.sm}`,
  errorShadowXs: `0 0 0 4px rgba(240, 68, 56, 0.24), ${shadowDark.xs}`,
} as const;

/** Backdrop blur radii in px (use as `backdrop-filter: blur(Npx)`). */
export const backdropBlur = {
  sm: 8,
  md: 16,
  lg: 24,
  xl: 40,
} as const;

/** Semantic opacity roles shared across interactive components. */
export const opacity = {
  disabled: 0.5,
} as const;

/** Semantic stacking layers for renderer-owned UI surfaces. */
export const zIndex = {
  /**
   * A floating video window: above the app content it shares a stacking
   * context with, under the meeting recorder (50) and the app's menus and dialogs.
   */
  pictureInPicture: 40,
  modalOverlay: 50,
} as const;

export type ShadowKey = keyof typeof shadow;
export type FocusRingKey = keyof typeof focusRing;
export type OpacityKey = keyof typeof opacity;
export type ZIndexKey = keyof typeof zIndex;
