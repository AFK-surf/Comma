/**
 * Component-scoped color tokens — Comma Design System.
 * Source: Figma "1. Color modes" → Component colors.
 */
import { alpha, base } from "./base";
import { brand, error, warning } from "./brand";
import { grayDarkMode, grayLightMode as gray } from "./grays";
import { utilityFlat } from "./utility";

/** Component colors / Components / Toast */
export const toast = {
  textPrimary: gray[800],
  textSecondary: gray[500],
  iconPrimary: gray[600],
} as const;

/** Component colors / Components / Buttons / Primary */
export const buttonPrimary = {
  bg: brand[400],
  bgHover: brand[500],
  border: brand[500],
  borderHover: brand[600],
  fg: base.white,
  fgHover: base.white,
} as const;

/** Component colors / Components / Buttons / Secondary */
export const buttonSecondary = {
  bg: base.white,
  border: gray[300],
  fg: gray[800],
} as const;

/** Component colors / Components / Buttons / Secondary color */
export const buttonSecondaryColor = {
  bg: base.white,
  bgHover: brand[50],
  border: brand[300],
  borderHover: brand[300],
  fg: brand[500],
  fgHover: brand[700],
} as const;

/** Component colors / Components / Buttons / Tertiary */
export const buttonTertiary = {
  fg: gray[600],
  fgHover: gray[700],
  bgHover: gray[50],
} as const;

/** Component colors / Components / Buttons / Tertiary color */
export const buttonTertiaryColor = {
  fg: brand[700],
  fgHover: brand[800],
  bgHover: brand[50],
} as const;

/** Component colors / Components / Buttons / Primary error */
export const buttonPrimaryError = {
  bg: error[600],
  bgHover: error[700],
  border: error[600],
  borderHover: error[700],
  fg: base.white,
  fgHover: base.white,
} as const;

/** Component colors / Components / Dialog */
export const dialog = {
  bg: base.white,
  /**
   * Footer shortcut keycap sitting on a primary/destructive button.
   * Figma binds these to colors/gray-dark-mode-alpha 700 + 200; the chip reads
   * against the brand fill, so both modes share the same white overlays.
   */
  shortcutOnPrimaryBg: "#ffffff29",
  shortcutOnPrimaryText: "#ffffffeb",
} as const;

/** Component colors / Components / Menu */
export const menu = {
  hoverError: error[50],
} as const;

/** Component colors / Components / Toggles */
export const toggle = {
  buttonFgDisabled: gray[50],
} as const;

/** Component colors / Components / Sliders */
export const slider = {
  handleBg: base.white,
  handleBorder: brand[600],
} as const;

/** Component colors / Components / Avatars */
export const avatar = {
  bg: gray[100],
  profilePhotoBorder: base.white,
} as const;

/** Component colors / Components / Tooltips */
export const tooltip = {
  bg: grayDarkMode[800],
  border: grayDarkMode[700],
  text: grayDarkMode[50],
  supportingText: grayDarkMode[300],
  shortcutBg: grayDarkMode[600],
  shortcutText: grayDarkMode[300],
} as const;

/** Component colors / Components / AI Input */
export const aiInput = {
  headerIconPrimary: gray[600],
  headerTextPrimary: base.black,
  headerTextSecondary: gray[500],
  panelIconPrimary: gray[500],
  panelIconDisabled: gray[300],
  panelIconFg: base.white,
  panelIconWarning: warning[500],
  panelTextPrimary: base.black,
  panelTextPlaceholder: gray[400],
  panelTextWarning: warning[500],
  panelBgInput: base.white,
  panelBgTag: base.black,
  panelTextAttachmentPrimary: gray[900],
  panelTextAttachmentSecondary: gray[500],
  panelBgDisabled: gray[100],
  panelBgAttachment: base.white,
} as const;

/** Component colors / Components / Panel */
export const panel = {
  bgFile: gray[200],
} as const;

/** Component colors / Components / Markdown */
export const markdown = {
  textPrimary: gray[900],
  textSecondary: gray[500],
  textToolPrimary: gray[500],
  // Local semantic alias: Comma DS has no dedicated audio-control variable yet.
  audioControlPrimary: gray[600],
  textInlinePrimary: gray[900],
  textInlineCode: error[800],
  bgInlineCode: gray[200],
  textLink: brand[300],
  bgMessage: gray[200],
  bgTable: gray[100],
  borderTable: gray[300],
  bgTool: base.white,
  iconPrimary: aiInput.panelIconPrimary,
  bgIconHover: gray[200],
  imageBgPrimary: alpha.white70,
  imageHover: alpha.black10,
  imageIconPrimary: gray[700],
  imageBarBorder: gray[300],
  soundVideoIconPrimary: gray[300],
  soundVideoTextPrimary: gray[300],
  soundVideoBgHover: alpha.white20,
  soundVideoBgPlayerBar: alpha.black70,
  soundVideoBgProgress: gray[400],
  soundVideoBgTracker: gray[25],
  soundVideoBarBorder: gray[600],
  // Local semantic alias for the media stage, composed from the Comma base palette.
  soundVideoBgPreview: base.black,
} as const;

/** Component colors / Components / Main panel */
export const mainPanel = {
  bg: gray[25],
  itemBg: base.white,
} as const;

/** Component colors / Components / Plugin */
export const plugin = {
  bgButton: base.white,
  border: base.white,
  rowBgHover: gray[200],
} as const;

/** Component colors / Components / Todo Kanban */
export const todoKanban = {
  bgCardPrimary: base.white,
  bgColumnPrimary: gray[50],
} as const;

/**
 * Component colors / Components / Todo List
 * Tint starts for group headers; fade end matches Colors/Background/bg-secondary.
 */
export const todoList = {
  bgNeedsReviewMain: "#F0EDE6",
  bgDone: "#E2EDE8",
  bgCancel: "#F2ECEB",
  bgGroupFade: gray[50],
} as const;

/** Component colors / Components / Sidebar */
export const sidebar = {
  textPrimary: gray[800],
  textSecondary: gray[700],
  textTertiary: gray[500],
  bgSelection: gray[100],
  textHighlight: gray[950],
  iconPrimary: gray[500],
  iconSecondary: gray[500],
  iconDisabled: gray[400],
  bgItem: gray[300],
} as const;

/** Component colors / Components / Scrollbar */
export const scrollbar = {
  bg: gray[300],
} as const;

export const components = {
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
  utility: utilityFlat,
} as const;
