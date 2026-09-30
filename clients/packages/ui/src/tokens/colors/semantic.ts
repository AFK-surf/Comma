/**
 * Semantic color tokens (light mode) — Comma Design System.
 * Source: Figma [data-theme="Light mode"] variable collection.
 */
import { base } from "./base";
import { brand, error, success, warning } from "./brand";
import { grayLightMode as gray } from "./grays";

export const text = {
  primary: gray[900],
  secondary: gray[700],
  tertiary: gray[600],
  quaternary: gray[500],
  white: base.white,
  disabled: gray[400],
  placeholder: gray[400],
  /** Figma Colors/Text/text-claude — agent brand (literal). */
  claude: "#d97757",
  /** Figma Colors/Text/text-codex — agent brand (literal). */
  codex: "#706ffc",
  brandPrimary: brand[900],
  brandSecondary: brand[700],
  brandTertiary: brand[600],
  errorPrimary: error[600],
  warningPrimary: warning[500],
  successPrimary: success[600],
} as const;

export const border = {
  primary: gray[300],
  /** Colors/Border/border-menu-primary → Gray (light mode)/400. */
  menuPrimary: gray[400],
  secondary: gray[200],
  tertiary: gray[100],
  disabled: gray[300],
  brand: brand[300],
  brandSolid: brand[600],
  error: error[300],
  errorSolid: error[600],
} as const;

export const foreground = {
  primary: gray[900],
  secondary: gray[700],
  tertiary: gray[600],
  quaternary: gray[500],
  quinary: gray[400],
  /** Figma Colors/Foreground/fg-quinary_hover → Gray (light mode)/500. */
  quinaryHover: gray[500],
  /** Figma Colors/Foreground/fg-senary (300) → Gray (light mode)/300. */
  senary: gray[300],
  /** Figma Colors/Foreground/fg-button → Base/white. */
  button: base.white,
  /** Figma Colors/Foreground/fg-button-active → Gray (light mode)/300. */
  buttonActive: gray[300],
  /** Figma Colors/Foreground/fg-button-secondary → Base/white. */
  buttonSecondary: base.white,
  white: base.white,
  disabled: gray[400],
  brandPrimary: brand[600],
  errorPrimary: error[600],
  warningPrimary: warning[600],
  /** Figma Colors/Foreground/fg-warning-secondary → Warning/500 */
  warningSecondary: warning[500],
  successPrimary: success[600],
} as const;

export const background = {
  primary: base.white,
  popupPrimary: base.white,
  popupSecondary: base.white,
  secondary: gray[50],
  /** Figma Colors/Background/bg-secondary_hover → Gray (light mode)/100. */
  secondaryHover: gray[100],
  tertiary: gray[100],
  /** Figma Colors/Background/bg-quaternary → Gray (light mode)/200. */
  quaternary: gray[200],
  /** Figma Colors/Background/bg-quaternary_hover → Gray (light mode)/200. */
  quaternaryHover: gray[200],
  active: gray[50],
  disabled: gray[100],
  overlay: gray[950],
  brandPrimary: brand[50],
  brandSecondary: brand[100],
  brandSolid: brand[400],
  brandSolidHover: brand[500],
  errorPrimary: error[50],
  errorSolid: error[600],
  warningPrimary: warning[50],
  warningSolid: warning[600],
  successPrimary: success[50],
  successSolid: success[600],
  toggle: gray[300],
  toggleHover: gray[200],
  /** Figma Colors/Background/bg-window → Gray (light mode)/100. */
  window: gray[100],
  /** Figma Colors/Background/bg-claude — agent brand (literal). */
  claude: "#f1cdc1",
  /** Figma Colors/Background/bg-codex — agent brand (literal). */
  codex: "#cdccff",
  /** Figma Colors/Background/bg-gpt — agent brand (literal). */
  gpt: "#e2e9ed",
} as const;

export const semantic = { text, border, foreground, background } as const;
