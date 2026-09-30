/**
 * Base colors — Comma Design System.
 * Source: Figma "Colors" page (node 1023:36350).
 */
export const base = {
  white: "#ffffff",
  black: "#000000",
  transparent: "#ffffff00",
} as const;

/**
 * Component alpha overlays in light mode.
 * Figma swaps the black/white alpha roles between color modes.
 */
export const alpha = {
  black10: "#0000001a",
  black20: "#00000033",
  black30: "#0000004d",
  black40: "#00000066",
  black50: "#00000080",
  black60: "#00000099",
  black70: "#000000b2",
  black80: "#000000cc",
  black90: "#000000e5",
  black100: "#000000",
  white10: "#ffffff1a",
  white20: "#ffffff33",
  white30: "#ffffff4d",
  white40: "#ffffff66",
  white50: "#ffffff80",
  white60: "#ffffff99",
  white70: "#ffffffb2",
  white80: "#ffffffcc",
  white90: "#ffffffe5",
  white100: "#ffffff",
} as const;

/** Component alpha overlays in dark mode. */
export const alphaDark = {
  black10: "#ffffff1a",
  black20: "#ffffff33",
  black30: "#ffffff4d",
  black40: "#ffffff66",
  black50: "#ffffff80",
  black60: "#ffffff99",
  black70: "#ffffffb2",
  black80: "#ffffffcc",
  black90: "#ffffffe5",
  black100: "#ffffff",
  white10: "#0c111d1a",
  white20: "#0c111d33",
  white30: "#0c111d4d",
  white40: "#0c111d66",
  white50: "#0c111d80",
  white60: "#0c111d99",
  white70: "#0c111db2",
  white80: "#0c111dcc",
  white90: "#0c111de5",
  white100: "#0f0f10",
} as const;
