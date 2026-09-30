export { base, alpha, alphaDark } from "./base";
export { brand, error, warning, success } from "./brand";
export {
  grayLightMode,
  grayDarkMode,
  grayBlue,
  grayCool,
  grayModern,
  grayNeutral,
  grayIron,
  grayTrue,
  grayWarm,
} from "./grays";
export {
  moss,
  greenLight,
  green,
  teal,
  cyan,
  blueLight,
  blue,
  blueDark,
} from "./spectrum-cool";
export {
  indigo,
  violet,
  purple,
  fuchsia,
  pink,
  rose,
  orangeDark,
  orange,
  yellow,
} from "./spectrum-warm";
export { semantic, text, border, foreground, background } from "./semantic";
export {
  semanticDark,
  text as textDark,
  border as borderDark,
  foreground as foregroundDark,
  background as backgroundDark,
} from "./semantic-dark";
export {
  components,
  toast as toastColors,
  buttonPrimary,
  buttonSecondary,
  buttonSecondaryColor,
  buttonTertiary,
  buttonTertiaryColor,
  buttonPrimaryError,
  dialog,
  toggle,
  slider,
  avatar,
  tooltip,
  plugin,
  scrollbar,
} from "./components";
export {
  componentsDark,
  toast as toastColorsDark,
  buttonPrimary as buttonPrimaryDark,
  buttonSecondary as buttonSecondaryDark,
  buttonSecondaryColor as buttonSecondaryColorDark,
  buttonTertiary as buttonTertiaryDark,
  buttonTertiaryColor as buttonTertiaryColorDark,
  buttonPrimaryError as buttonPrimaryErrorDark,
  dialog as dialogDark,
  toggle as toggleDark,
  slider as sliderDark,
  avatar as avatarDark,
  tooltip as tooltipDark,
  plugin as pluginDark,
  scrollbar as scrollbarDark,
} from "./components-dark";
export { utility, utilityFlat } from "./utility";
export { utilityDark, utilityFlatDark } from "./utility-dark";
export * from "./modes";

export {
  clampCommaThemeLightness,
  commaThemeChromaCssExpr,
  commaThemeChromaGainMax,
  commaThemeLightnessCssExpr,
  commaThemeLightnessMax,
  commaThemeLightnessMin,
  commaThemeLightnessNeutral,
  commaThemeLightnessToPad,
  commaThemePadToLightness,
  hexToOklch,
  oklchChromaEnvelope,
  oklchChromaGainFromSample,
  oklchNeutralCss,
  oklchShiftedLightness,
} from "./oklch";

import * as baseColors from "./base";
import * as brandColors from "./brand";
import * as grays from "./grays";
import * as cool from "./spectrum-cool";
import * as warm from "./spectrum-warm";

/** All primitive palettes, keyed by family name. */
export const palettes = {
  ...baseColors,
  ...brandColors,
  ...grays,
  ...cool,
  ...warm,
} as const;

export type PaletteName = keyof typeof palettes;
