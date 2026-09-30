/**
 * Dialog layout tokens — Comma Design System.
 * Source: Figma Dialog component set (7601:17312).
 */
export const dialogLayout = {
  /** 370px in Figma 7601:17310, widened 20% so confirm sheets keep their copy on two lines. */
  widthDefault: 444,
  /** For a dialog whose body is a table: room for six columns without wrapping. */
  widthWide: 960,
  /** For a dialog that previews a chat: room for a readable transcript column. */
  widthPreview: 560,
  /** cross-small icon frame inset within the close hit target (%) */
  closeIconInset: 32.29,
} as const;

export type DialogLayoutKey = keyof typeof dialogLayout;
