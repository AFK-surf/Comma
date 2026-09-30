/**
 * Toast layout tokens — Comma Design System.
 * Source: Figma Toast component set (7602:2355).
 */
export const toastLayout = {
  /** One 380px max width across every variant; copy wraps, never ellipsizes. */
  widthSingle: 380,
  widthAction: 380,
  /** widthAction minus the shell's px-xl padding on both sides. */
  widthActionsRow: 348,
  /** Vertical gap between stacked toasts once the stack is expanded. */
  stackGap: 14,
  /** Inset from the window's bottom-right corner to the stack. */
  viewportInset: 24,
  /** cross-small icon frame inset within the close hit target (%) */
  closeIconInset: 32.29,
} as const;

export type ToastLayoutKey = keyof typeof toastLayout;
