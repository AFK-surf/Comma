import darkModeTokens from "./dark-mode.tokens.json";
import lightModeTokens from "./light-mode.tokens.json";
import { parseColorModeTokens, type ParsedColorMode } from "./parse";

export {
  parseColorModeTokens,
  type ColorModeGroup,
  type ColorModeToken,
  type ParsedColorMode,
} from "./parse";

export const lightColorMode: ParsedColorMode = parseColorModeTokens(lightModeTokens);
export const darkColorMode: ParsedColorMode = parseColorModeTokens(darkModeTokens);

export const colorModes = {
  light: lightColorMode,
  dark: darkColorMode,
} as const;
