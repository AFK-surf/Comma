/**
 * Command palette layout tokens — Comma App.
 * Keep viewport-dependent preview rendering on one owned threshold so the
 * component does not drift from a duplicate CSS media query.
 */
export const commandPaletteLayout = {
  previewMinViewportWidth: 801,
} as const;

export type CommandPaletteLayoutKey = keyof typeof commandPaletteLayout;
