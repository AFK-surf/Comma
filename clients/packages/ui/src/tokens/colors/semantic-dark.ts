/**
 * Semantic color tokens (dark mode) — Comma Design System.
 * Source: Figma [data-theme="Dark mode"] variable collection.
 */
import { base } from "./base";
import { brand, error, success, warning } from "./brand";
import { grayDarkMode as gray, grayLightMode } from "./grays";

export const text = {
  primary: gray[50],
  secondary: gray[300],
  tertiary: gray[400],
  quaternary: gray[400],
  white: base.white,
  disabled: gray[500],
  placeholder: gray[500],
  /** Figma Colors/Text/text-claude — agent brand (literal). */
  claude: "#d97757",
  /** Figma Colors/Text/text-codex — agent brand (literal). */
  codex: "#9594fc",
  brandPrimary: gray[50],
  brandSecondary: gray[300],
  brandTertiary: gray[400],
  errorPrimary: error[400],
  warningPrimary: warning[400],
  successPrimary: success[400],
} as const;

export const border = {
  primary: gray[700],
  /** Colors/Border/border-menu-primary → Gray (dark mode)/600. */
  menuPrimary: gray[600],
  secondary: gray[800],
  tertiary: gray[800],
  disabled: gray[700],
  brand: brand[400],
  brandSolid: brand[500],
  error: error[400],
  errorSolid: error[500],
} as const;

export const foreground = {
  primary: base.white,
  secondary: gray[300],
  tertiary: gray[400],
  quaternary: gray[400],
  quinary: gray[500],
  /** Figma Colors/Foreground/fg-quinary_hover → Gray (dark mode)/400. */
  quinaryHover: gray[400],
  /** Figma Colors/Foreground/fg-senary (300) → Gray (dark mode)/600. */
  senary: gray[600],
  /** Figma Colors/Foreground/fg-button → Gray (dark mode)/700. */
  button: gray[700],
  /** Figma Colors/Foreground/fg-button-active → Gray (dark mode)/600. */
  buttonActive: gray[600],
  /** Figma Colors/Foreground/fg-button-secondary → Gray (dark mode)/800. */
  buttonSecondary: gray[800],
  white: base.white,
  disabled: gray[500],
  brandPrimary: brand[500],
  errorPrimary: error[500],
  warningPrimary: warning[500],
  /** Figma Colors/Foreground/fg-warning-secondary → Warning/400 */
  warningSecondary: warning[400],
  successPrimary: success[500],
} as const;

export const background = {
  primary: gray[950],
  popupPrimary: gray[900],
  popupSecondary: gray[800],
  secondary: gray[900],
  /** Figma Colors/Background/bg-secondary_hover. */
  secondaryHover: gray[800],
  tertiary: gray[800],
  /** Figma Colors/Background/bg-quaternary → Gray (dark mode)/700. */
  quaternary: gray[700],
  /** Figma Colors/Background/bg-quaternary_hover → Gray (dark mode)/700. */
  quaternaryHover: gray[700],
  active: gray[800],
  disabled: gray[800],
  overlay: gray[800],
  brandPrimary: brand[500],
  brandSecondary: brand[300],
  brandSolid: brand[300],
  brandSolidHover: brand[500],
  errorPrimary: error[500],
  errorSolid: error[600],
  warningPrimary: warning[500],
  warningSolid: warning[600],
  successPrimary: success[500],
  successSolid: success[600],
  /** Figma dark mode aliases gray (light mode) for toggle track. */
  toggle: grayLightMode[500],
  toggleHover: grayLightMode[400],
  /** Figma Colors/Background/bg-window → Gray (dark mode)/950. */
  window: gray[950],
  /** Figma Colors/Background/bg-claude — agent brand (literal). */
  claude: "#6a2e1b",
  /** Figma Colors/Background/bg-codex — agent brand (literal). */
  codex: "#4746aa",
  /** Figma Colors/Background/bg-gpt — agent brand (literal). */
  gpt: "#353a3d",
} as const;

export const semanticDark = { text, border, foreground, background } as const;
