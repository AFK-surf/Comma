/**
 * Component-scoped color tokens (dark mode) — Comma Design System.
 * Source: Figma [data-theme="Dark mode"] → Component colors.
 */
import { alphaDark, base } from "./base";
import { brand, error, warning } from "./brand";
import { tooltip } from "./components";
import { grayDarkMode, grayLightMode } from "./grays";
import { utilityFlatDark } from "./utility-dark";

export { tooltip };

export const toast = {
  textPrimary: grayLightMode[50],
  textSecondary: grayDarkMode[300],
  iconPrimary: grayLightMode[300],
} as const;

export const buttonPrimary = {
  bg: brand[400],
  bgHover: brand[500],
  border: brand[500],
  borderHover: brand[600],
  fg: base.white,
  fgHover: base.white,
} as const;

export const buttonSecondary = {
  bg: grayDarkMode[900],
  border: grayDarkMode[700],
  fg: grayDarkMode[300],
} as const;

export const buttonSecondaryColor = {
  bg: grayDarkMode[900],
  bgHover: grayDarkMode[800],
  border: grayDarkMode[700],
  borderHover: grayDarkMode[700],
  fg: grayDarkMode[300],
  fgHover: grayDarkMode[100],
} as const;

export const buttonTertiary = {
  fg: grayDarkMode[400],
  fgHover: grayDarkMode[200],
  bgHover: grayDarkMode[800],
} as const;

export const buttonTertiaryColor = {
  fg: grayDarkMode[300],
  fgHover: grayDarkMode[100],
  bgHover: grayDarkMode[800],
} as const;

export const buttonPrimaryError = {
  bg: error[600],
  bgHover: error[700],
  border: error[600],
  borderHover: error[700],
  fg: base.white,
  fgHover: base.white,
} as const;

/** Figma dark mode: dialog-bg → gray (light mode) 900 */
export const dialog = {
  bg: grayLightMode[900],
  /** Same white overlays as light mode — the brand fill underneath does not swap. */
  shortcutOnPrimaryBg: "#ffffff29",
  shortcutOnPrimaryText: "#ffffffeb",
} as const;

/** Component colors / Components / Menu */
export const menu = {
  hoverError: error[950],
} as const;

export const toggle = {
  buttonFgDisabled: grayDarkMode[600],
} as const;

export const slider = {
  handleBg: brand[500],
  handleBorder: grayDarkMode[950],
} as const;

export const avatar = {
  bg: grayDarkMode[800],
  profilePhotoBorder: grayDarkMode[950],
} as const;

export const aiInput = {
  headerIconPrimary: grayLightMode[400],
  headerTextPrimary: grayLightMode[100],
  headerTextSecondary: grayDarkMode[400],
  panelIconPrimary: grayLightMode[400],
  panelIconDisabled: grayLightMode[700],
  panelIconFg: base.white,
  panelIconWarning: warning[500],
  panelTextPrimary: grayLightMode[100],
  panelTextPlaceholder: grayLightMode[500],
  panelTextWarning: warning[500],
  panelBgInput: grayDarkMode[800],
  panelBgTag: grayDarkMode[600],
  panelTextAttachmentPrimary: grayDarkMode[50],
  panelTextAttachmentSecondary: grayDarkMode[500],
  panelBgDisabled: grayDarkMode[700],
  panelBgAttachment: grayDarkMode[700],
} as const;

export const panel = {
  bgFile: grayDarkMode[700],
} as const;

export const markdown = {
  textPrimary: grayDarkMode[50],
  textSecondary: grayDarkMode[400],
  textToolPrimary: grayDarkMode[500],
  // Local semantic alias: Comma DS has no dedicated audio-control variable yet.
  audioControlPrimary: grayLightMode[400],
  textInlinePrimary: grayLightMode[300],
  textInlineCode: error[400],
  bgInlineCode: grayLightMode[800],
  textLink: brand[200],
  bgMessage: grayDarkMode[700],
  bgTable: grayDarkMode[700],
  borderTable: grayLightMode[700],
  bgTool: grayDarkMode[900],
  iconPrimary: aiInput.panelIconPrimary,
  bgIconHover: grayDarkMode[700],
  imageBgPrimary: alphaDark.white70,
  imageHover: alphaDark.black10,
  imageIconPrimary: grayLightMode[300],
  imageBarBorder: grayDarkMode[700],
  soundVideoIconPrimary: grayLightMode[300],
  soundVideoTextPrimary: grayLightMode[300],
  soundVideoBgHover: alphaDark.black20,
  soundVideoBgPlayerBar: alphaDark.white70,
  soundVideoBgProgress: grayLightMode[600],
  soundVideoBgTracker: grayLightMode[50],
  soundVideoBarBorder: grayDarkMode[600],
  // Local semantic alias for the media stage, composed from the Comma base palette.
  soundVideoBgPreview: base.black,
} as const;

export const mainPanel = {
  bg: grayDarkMode[900],
  itemBg: grayDarkMode[800],
} as const;

export const plugin = {
  bgButton: grayDarkMode[600],
  border: grayDarkMode[800],
  rowBgHover: grayDarkMode[700],
} as const;

/** Component colors / Components / Todo Kanban */
export const todoKanban = {
  bgCardPrimary: grayDarkMode[900],
  bgColumnPrimary: grayDarkMode[950],
} as const;

/**
 * Component colors / Components / Todo List
 * Tint starts from Figma Todo List; fade end matches the main panel item background.
 */
export const todoList = {
  bgNeedsReviewMain: "#3B3423",
  bgDone: "#233E31",
  bgCancel: "#4C2F2D",
  bgGroupFade: mainPanel.itemBg,
} as const;

export const sidebar = {
  textPrimary: grayLightMode[400],
  textSecondary: grayDarkMode[300],
  textTertiary: grayLightMode[500],
  bgSelection: "#494C50",
  textHighlight: base.white,
  iconPrimary: grayLightMode[400],
  iconSecondary: grayLightMode[400],
  iconDisabled: "#494C50",
  bgItem: grayLightMode[800],
} as const;

/** Component colors / Components / Scrollbar */
export const scrollbar = {
  bg: grayDarkMode[500],
} as const;

export const componentsDark = {
  toast,
  buttonPrimary,
  buttonSecondary,
  buttonSecondaryColor,
  buttonTertiary,
  buttonTertiaryColor,
  buttonPrimaryError,
  dialog,
  menu,
  toggle,
  slider,
  avatar,
  tooltip,
  aiInput,
  panel,
  markdown,
  mainPanel,
  plugin,
  todoKanban,
  todoList,
  sidebar,
  scrollbar,
  utility: utilityFlatDark,
} as const;
