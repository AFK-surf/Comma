/**
 * Selection action pill — Figma Comma App 1193:11862. The bar owns the chrome
 * (border, fill, shadow) and each action supplies its own label plus keycaps,
 * so a single-action bar is pixel-identical to the Figma frame.
 */
export const selectionActionBar =
  "comma-selection-action-bar fixed z-50 inline-flex items-center rounded-md border border-primary bg-ai-input-panel-bg-input shadow-xs";

export const selectionActionBarAction =
  "inline-flex shrink-0 cursor-default items-center gap-xs rounded-md bg-transparent px-md py-xs outline-none transition-colors duration-[var(--motion-duration-feedback-in)] hover:bg-quaternary data-[pressed]:bg-quaternary-hover focus-visible:shadow-focus-gray motion-reduce:transition-none";

export const selectionActionBarLabel =
  "whitespace-nowrap text-sm leading-5 tracking-[-0.14px] text-primary";

export const selectionActionBarKeys = "inline-flex shrink-0 items-center gap-xxs";

const selectionActionBarKeyBase =
  "inline-flex shrink-0 items-center justify-center rounded-xs bg-quaternary font-sans text-xs font-medium leading-[18px] text-secondary";

/**
 * The keycap footprint is the 18px line box plus the vertical padding that
 * defines it. Single glyphs sit in that square rather than shrink-wrapping, so
 * a narrow letter and a wide symbol cannot drift apart — the same treatment
 * the tooltip keycaps use.
 *
 * Written out literally, and with underscores for the spaces calc() needs:
 * Tailwind scans source text, so a class assembled from a variable is never
 * generated at all.
 */
export const selectionActionBarKey = `${selectionActionBarKeyBase} size-[calc(18px_+_2_*_var(--spacing-xxs))]`;

/** Multi-character labels grow horizontally from that same square. */
export const selectionActionBarWideKey = `${selectionActionBarKeyBase} h-[calc(18px_+_2_*_var(--spacing-xxs))] min-w-[calc(18px_+_2_*_var(--spacing-xxs))] px-xs`;

export const selectionActionBarSeparator =
  "h-4 shrink-0 self-center border-l-[length:var(--border-width-0-5)] border-primary";
